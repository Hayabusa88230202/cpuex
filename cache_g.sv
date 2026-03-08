// cache_g.sv
module cache (
    master_fifo.master fifo,
    input logic clk,
    input logic [31:0] input_data, 
    input logic [31:0] input_addr, 
    input logic readtrigger,
    input logic writetrigger,
    input logic reset_n,
    output logic req_rdy,
    output logic [31:0] output_data
);

    assign fifo.clk = clk;
    
    // ★修正1: データ受信待ちステートでデータが来た時のみ rd_en(rsp_rdy) を立ててアンダーフローを防ぐ
    assign fifo.rsp_rdy = ((state == WAIT_READ_RSP_FOR_WRITE) || (state == WAIT_READ_RSP_FOR_READ)) && fifo.rsp_en;

    localparam DATA_WIDTH = 32;
    localparam CACHE_DEPTH = 256;
    localparam TAG_WIDTH = 20; 
    localparam INDEX_WIDTH = 8;
    localparam OFFSET_WIDTH = 2;

    reg [32*(1 << OFFSET_WIDTH)-1:0] cache_memory [CACHE_DEPTH-1:0]; 
    reg [TAG_WIDTH-1:0] cache_tag [CACHE_DEPTH-1:0];
    
    logic valid_bits [CACHE_DEPTH-1:0];
    logic dirty_bits [CACHE_DEPTH-1:0];

    reg [TAG_WIDTH-1:0] tag;
    reg [INDEX_WIDTH-1:0] index;
    reg [OFFSET_WIDTH-1:0] offset;

    always_comb begin
        tag = input_addr[31:12];    
        index = input_addr[11:4];   
        offset = input_addr[3:2];   
    end

    logic [31:0] output_data_reg;
    assign output_data = output_data_reg;

    initial begin
        for (int i = 0; i < CACHE_DEPTH; i++) begin
             valid_bits[i] = 1'b0;
             dirty_bits[i] = 1'b0;
        end
    end

    // ====================================================================
    // ★削除: 以前のエッジ検出ロジック(left_prev, read_riseなど)は全て削除
    // ====================================================================

    localparam IDLE = 5'b00000;
    localparam COMP = 5'b00010;
    localparam WAIT_READ_LINE_FOR_READ = 5'b00100;
    localparam WAIT_READ_LINE_FOR_WRITE = 5'b00101;
    localparam WAIT_WRITE_BACK_FOR_READ = 5'b01000;
    localparam WAIT_WRITE_BACK_FOR_WRITE = 5'b01001;
    localparam WAIT_READ_RSP_FOR_WRITE = 5'b10001;
    localparam WAIT_READ_RSP_FOR_READ = 5'b10000;
    localparam WAIT_BETWEEN_REQS_FOR_READ = 5'b11000;  // ★追加
    localparam WAIT_BETWEEN_REQS_FOR_WRITE = 5'b11001; // ★追加
    localparam DONE = 5'b11111;

    logic [4:0] state = IDLE;

    logic [31:0] input_addr_reg;
    logic [31:0] input_data_reg;
    logic [TAG_WIDTH-1:0] cache_tag_reg;
    logic [127:0] cache_data_reg; 
    logic dirty_bit_reg;
    logic valid_bit_reg;
    // 上の方にレジスタを追加
    logic [3:0] wait_counter;

    // ★修正: 分かりやすい名前に変更し、リクエストを保持するレジスタ
    logic read_req_reg;
    logic write_req_reg;
    
    // ★修正: req_rdy_reg は遅延の元になるため使わず、以下のゼロ遅延ロジックを使う
    // 完全にIDLEで何もしていない時か、DONEの時だけReadyを返す
    assign req_rdy = (state == DONE) || (state == IDLE && !readtrigger && !writetrigger);
    
    always_ff @(posedge clk) begin
        if (!reset_n) begin
            state <= IDLE;
            fifo.req_en <= 1'b0;
            output_data_reg <= 32'b0;
            read_req_reg <= 1'b0;
            write_req_reg <= 1'b0;
        end else begin
            case (state)
                IDLE: begin
                    // ★究極の修正: trigger(レベル)が1なら即座に反応し、連続アクセスを可能にする！
                    if (readtrigger || writetrigger) begin
                        read_req_reg  <= readtrigger;
                        write_req_reg <= writetrigger;
                        
                        fifo.req_en <= 1'b0;
                        
                        input_addr_reg <= input_addr;
                        input_data_reg <= input_data;
                        cache_tag_reg <= cache_tag[index];
                        cache_data_reg <= cache_memory[index];
                        
                        dirty_bit_reg <= dirty_bits[index];
                        valid_bit_reg <= valid_bits[index];
                        state <= COMP;
                    end
                end

                COMP: begin
                    if (read_req_reg) begin
                        if (valid_bit_reg && (cache_tag_reg == input_addr_reg[31:12])) begin // HIT
                            case (input_addr_reg[3:2])
                                2'b00: output_data_reg <= cache_data_reg[31:0];
                                2'b01: output_data_reg <= cache_data_reg[63:32];
                                2'b10: output_data_reg <= cache_data_reg[95:64];
                                2'b11: output_data_reg <= cache_data_reg[127:96];
                            endcase
                            state <= DONE;
                        end else begin // MISS
                            if (valid_bit_reg && dirty_bit_reg) begin
                                // Write Back
                                fifo.req.cmd <= 1'b0; 
                                // ★修正2: 32ビットに揃えてアドレスズレを防ぐ
                                fifo.req.addr <= {cache_tag_reg, input_addr_reg[11:4], 4'b0000};
                                fifo.req.data <= cache_data_reg;
                                fifo.req_en <= 1'b1;
                                state <= WAIT_WRITE_BACK_FOR_READ;
                            end else begin
                                // Allocate (Read)
                                fifo.req.cmd <= 1'b1; 
                                // ★修正2
                                fifo.req.addr <= {input_addr_reg[31:4], 4'b0000};
                                fifo.req.data <= 128'b0;
                                fifo.req_en <= 1'b1;
                                state <= WAIT_READ_LINE_FOR_READ;
                            end
                        end
                    end else if (write_req_reg) begin
                         if (valid_bit_reg && (cache_tag_reg == input_addr_reg[31:12])) begin // HIT
                            case (input_addr_reg[3:2])
                                2'b00: cache_memory[input_addr_reg[11:4]] <= {cache_data_reg[127:32], input_data_reg};
                                2'b01: cache_memory[input_addr_reg[11:4]] <= {cache_data_reg[127:64], input_data_reg, cache_data_reg[31:0]};
                                2'b10: cache_memory[input_addr_reg[11:4]] <= {cache_data_reg[127:96], input_data_reg, cache_data_reg[63:0]};
                                2'b11: cache_memory[input_addr_reg[11:4]] <= {input_data_reg, cache_data_reg[95:0]};
                            endcase
                            
                            dirty_bits[input_addr_reg[11:4]] <= 1'b1;
                            output_data_reg <= 32'b0;
                            state <= DONE;
                        end else begin // MISS
                            if (valid_bit_reg && dirty_bit_reg) begin
                                // Write Back
                                fifo.req.cmd <= 1'b0;
                                // ★修正2
                                fifo.req.addr <= {cache_tag_reg, input_addr_reg[11:4], 4'b0000};
                                fifo.req.data <= cache_data_reg;
                                fifo.req_en <= 1'b1;
                                state <= WAIT_WRITE_BACK_FOR_WRITE;
                            end else begin
                                // Allocate (Read)
                                fifo.req.cmd <= 1'b1;
                                // ★修正2
                                fifo.req.addr <= {input_addr_reg[31:4], 4'b0000};
                                fifo.req.data <= 128'b0;
                                fifo.req_en <= 1'b1;
                                state <= WAIT_READ_LINE_FOR_WRITE;
                            end
                        end
                    end
                end

               /* WAIT_WRITE_BACK_FOR_READ: begin
                    if (fifo.req_rdy) begin
                        fifo.req.cmd <= 1'b1; // read
                        // ★修正2
                        fifo.req.addr <= {input_addr_reg[31:4], 4'b0000};
                        fifo.req.data <= 128'b0;
                        fifo.req_en <= 1'b1;
                        state <= WAIT_READ_LINE_FOR_READ;
                    end
                end

                WAIT_WRITE_BACK_FOR_WRITE: begin
                    if (fifo.req_rdy) begin
                        fifo.req.cmd <= 1'b1; // read
                        // ★修正2
                        fifo.req.addr <= {input_addr_reg[31:4], 4'b0000};
                        fifo.req.data <= 128'b0;
                        fifo.req_en <= 1'b1;
                        state <= WAIT_READ_LINE_FOR_WRITE;
                    end
                end*/

                WAIT_WRITE_BACK_FOR_READ: begin
                    if (fifo.req_rdy) begin
                        fifo.req_en <= 1'b0; // ★一旦 req_en を下げてFIFOにエッジを認識させる
                        wait_counter <= 4'd10; // ★10クロック待機させる
                        state <= WAIT_BETWEEN_REQS_FOR_READ;
                    end
                end
                WAIT_BETWEEN_REQS_FOR_READ: begin // ★1クロック休んだらReadを発行
                    if (wait_counter > 0) begin
                        wait_counter <= wait_counter - 1; // ★待機中
                    end else begin
                        fifo.req.cmd <= 1'b1; // read
                        fifo.req.addr <= {input_addr_reg[31:4], 4'b0000};
                        fifo.req.data <= 128'b0;
                        fifo.req_en <= 1'b1;
                        state <= WAIT_READ_LINE_FOR_READ;
                    end
                end

                WAIT_WRITE_BACK_FOR_WRITE: begin
                    if (fifo.req_rdy) begin
                        fifo.req_en <= 1'b0; // ★一旦 req_en を下げる
                        wait_counter <= 4'd10; // ★10クロック待機させる
                        state <= WAIT_BETWEEN_REQS_FOR_WRITE;
                    end
                end
                WAIT_BETWEEN_REQS_FOR_WRITE: begin // ★1クロック休んだらReadを発行
                    if (wait_counter > 0) begin
                        wait_counter <= wait_counter - 1; // ★待機中
                    end else begin
                        fifo.req.cmd <= 1'b1; // read
                        fifo.req.addr <= {input_addr_reg[31:4], 4'b0000};
                        fifo.req.data <= 128'b0;
                        fifo.req_en <= 1'b1;
                        state <= WAIT_READ_LINE_FOR_WRITE;
                    end
                end

                WAIT_READ_LINE_FOR_WRITE: begin
                    if (fifo.req_rdy) begin
                        fifo.req_en <= 1'b0;
                        state <= WAIT_READ_RSP_FOR_WRITE;
                    end
                end

                WAIT_READ_LINE_FOR_READ: begin
                    if (fifo.req_rdy) begin
                        fifo.req_en <= 1'b0;
                        state <= WAIT_READ_RSP_FOR_READ;
                    end
                end

                WAIT_READ_RSP_FOR_WRITE: begin
                    if (fifo.rsp_en) begin
                        cache_tag[input_addr_reg[11:4]] <= input_addr_reg[31:12];
                        valid_bits[input_addr_reg[11:4]] <= 1'b1;
                        case (input_addr_reg[3:2])
                            2'b00: cache_memory[input_addr_reg[11:4]] <= {fifo.rsp.data[127:32], input_data_reg};
                            2'b01: cache_memory[input_addr_reg[11:4]] <= {fifo.rsp.data[127:64], input_data_reg, fifo.rsp.data[31:0]};
                            2'b10: cache_memory[input_addr_reg[11:4]] <= {fifo.rsp.data[127:96], input_data_reg, fifo.rsp.data[63:0]};
                            2'b11: cache_memory[input_addr_reg[11:4]] <= {input_data_reg, fifo.rsp.data[95:0]};
                        endcase
                        dirty_bits[input_addr_reg[11:4]] <= 1'b1;
                        output_data_reg <= 32'b0;
                        state <= DONE;
                    end
                end

                WAIT_READ_RSP_FOR_READ: begin
                    if (fifo.rsp_en) begin
                        cache_memory[input_addr_reg[11:4]] <= fifo.rsp.data;
                        cache_tag[input_addr_reg[11:4]] <= input_addr_reg[31:12];
                        valid_bits[input_addr_reg[11:4]] <= 1'b1;
                        dirty_bits[input_addr_reg[11:4]] <= 1'b0;
                        case (input_addr_reg[3:2])
                            2'b00: output_data_reg <= fifo.rsp.data[31:0];
                            2'b01: output_data_reg <= fifo.rsp.data[63:32];
                            2'b10: output_data_reg <= fifo.rsp.data[95:64];
                            2'b11: output_data_reg <= fifo.rsp.data[127:96];
                        endcase
                        state <= DONE;
                    end
                end

                DONE: begin
                    fifo.req_en <= 1'b0;
                    state <= IDLE;
                end
            endcase
        end
    end
endmodule