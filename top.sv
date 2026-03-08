`default_nettype wire

module top (
    // DDR2
    output wire [12:0] ddr2_addr,
    output wire [2:0] ddr2_ba,
    output wire ddr2_cas_n,
    output wire [0:0] ddr2_ck_n,
    output wire [0:0] ddr2_ck_p,
    output wire [0:0] ddr2_cke,
    output wire ddr2_ras_n,
    output wire ddr2_we_n,
    inout  wire [15:0] ddr2_dq,
    inout  wire [1:0] ddr2_dqs_n,
    inout  wire [1:0] ddr2_dqs_p,
    output wire [0:0] ddr2_cs_n,
    output wire [1:0] ddr2_dm,
    output wire [0:0] ddr2_odt,
    // others
    input logic clk,
    input logic rst,
    output logic [15:0] led,
    
    // UART信号
    input  wire uart_rx_i,
    output wire uart_tx_o 
);

    logic [31:0] input_data;   // CPU -> Cache/UART (Write Data)
    logic [31:0] input_addr;   // CPU -> Cache/UART (Address)

    logic [31:0] cache_rdata;     // Cacheから読み出されたデータ
    logic [31:0] cpu_read_data;   // 最終的にCPUに渡すデータ (MUX後)

    logic readtrigger;
    logic writetrigger;
    logic req_rdy;
    
    logic cpu_clk; 
    logic calib_done;
    logic [15:0] cpu_leds;

    logic [27:0] heartbeat;
    always_ff @(posedge cpu_clk) begin
        heartbeat <= heartbeat + 1;
    end

    // --- 究極のLEDデバッグ ---
    //assign led[15] = calib_done;
    //assign led[14] = heartbeat[27];
    //assign led[13] = rst;
    //assign led[12] = uart_tx_o;
    //assign led[11] = cpu_leds[15];
    //assign led[10] = cpu_leds[14];
    //assign led[9]  = is_uart_addr;
    //assign led[8:0] = cpu_leds[8:0];

    assign led[15] = cpu_leds[15]; // ストール判定 (1のはず)
    //assign led[14] = uart_tx_o;    // TX状態 (1のはず)
    // ★送信カウンターをやめて、PCの下位ビットを表示！
    assign led[14:0] = cpu_leds[14:0]; // PCのインデックス (14bit)

  /*  // ================================================================
    // ★究極のデバッグカウンター：UARTから何ワード読み取ったか数える
    // ================================================================
    logic [31:0] uart_read_count;
    always_ff @(posedge cpu_clk) begin
        if (!rst) begin
            uart_read_count <= 32'd0;
        end else if (uart_re && req_rdy) begin // CPUがUARTのデータを正確に1つ受け取った瞬間
            uart_read_count <= uart_read_count + 1;
        end
    end

    assign led[15] = cpu_leds[15]; // stall_pc を最優先で確認
    assign led[14] = uart_tx_o;    // 画像データが送られているか確認
    //assign led[13:0] = cpu_leds[13:0]; // PCのインデックス (14bit)
    assign led[13:0] = uart_read_count[13:0]; // ★PCの代わりに、読み取った総ワード数を表示！
*/

/*    // ================================================================
    // ★最終兵器：UARTへ何文字送信したか数えるカウンター
    // ================================================================
    logic [31:0] uart_write_count;
    always_ff @(posedge cpu_clk) begin
        if (!rst) begin
            uart_write_count <= 32'd0;
        end else if (uart_we && uart_tx_ready) begin // CPUがUARTに1文字書き込んだ瞬間
            uart_write_count <= uart_write_count + 1;
        end
    end

    assign led[15] = cpu_leds[15]; // ストール判定
    assign led[14] = uart_tx_o;    // TXピンの状態
    assign led[13:0] = uart_write_count[13:0]; // ★受信カウンターから「送信カウンター」に変更！
*/
    // ----------------------------------------------------------------
    // アドレスデコード（MMIO）ロジック
    // ----------------------------------------------------------------
    logic  is_uart_addr;
    assign is_uart_addr = (input_addr == 32'hFFFF0000);

    logic uart_tx_busy;
    logic uart_tx_ready;
    // ★念のためのガード: メモリ準備前は書き込み信号も強制遮断
    logic uart_we;
    assign uart_we = writetrigger && is_uart_addr;
    //assign uart_we = writetrigger && is_uart_addr && calib_done;

    logic cache_writetrigger;
    logic cache_readtrigger;
    //assign cache_writetrigger = writetrigger && !is_uart_addr;
    //assign cache_readtrigger  = readtrigger  && !is_uart_addr;
    assign cache_writetrigger = writetrigger && !is_uart_addr && calib_done;
    assign cache_readtrigger  = readtrigger  && !is_uart_addr && calib_done;

    logic cache_req_rdy;


    // ----------------------------------------------------------------
    // ★修正: UART受信 (Read) ロジックの完全直結化
    // ----------------------------------------------------------------
    logic [7:0] rx_data_out;
    logic       rx_data_valid;
    wire        uart_rx_rd_en; // FIFOからUART_RXへの読み取り信号

    wire [31:0] fifo_cpu_data;
    wire        fifo_cpu_valid;

    // CPUがUARTアドレスを読もうとしている時だけ、UART_RXに「読み取り要求(rd_en)」を送る
    logic uart_re;
    /// ★究極の修正: CPUがFPUの計算でフリーズしている時だけ、空Pop(掃除機現象)を防ぐ！
    assign uart_re = readtrigger && is_uart_addr && !cpu_fpu_stall;
    //assign uart_re = readtrigger && is_uart_addr;
    //assign uart_re = readtrigger && is_uart_addr && calib_done;
    // CPUがストール中(cpu_leds[15]==1)は、FIFOの空Pop（蒸発）を防ぐために要求を止める！
    //assign uart_re = readtrigger && is_uart_addr && !cpu_leds[15];

    // ★修正: DDR準備前(calib_done=0)にメモリアクセスしようとしたら、
    // キャッシュの返事を待たずに強制的にReady=0にしてCPUを安全に待機させる
    logic actual_cache_rdy;
    assign actual_cache_rdy = calib_done ? cache_req_rdy : 1'b0;

    // ★重要: Ready信号の生成
    // UARTアクセス時: Readなら rx_data_valid (データ到着済)、Writeなら tx_ready (送信可能) を見る
    //assign req_rdy = is_uart_addr ? (writetrigger ? uart_tx_ready : rx_data_valid) : cache_req_rdy;
    //assign req_rdy = is_uart_addr ? (writetrigger ? uart_tx_ready : rx_data_valid) 
      //                            : actual_cache_rdy;

    // ★修正: Read時はFIFOの fifo_cpu_valid を見てストール解除を判断する
    assign req_rdy = is_uart_addr ? (writetrigger ? uart_tx_ready : fifo_cpu_valid) 
                                  : actual_cache_rdy;

    // 読み出しデータのMUX
    //assign cpu_read_data = is_uart_addr ? {24'd0, rx_data_out} : cache_rdata;

    // ★修正: CPUにはFIFOから出てきた完璧な32ビットデータを渡す！
    assign cpu_read_data = is_uart_addr ? fifo_cpu_data : cache_rdata;

    logic cpu_fpu_stall; // ★これを追加

    // ----------------------------------------------------------------
    // モジュール接続
    // ----------------------------------------------------------------
    MIPS_CPU mips_core (
        .clk(cpu_clk),
        .rst(rst),
        .led(cpu_leds),
        .mem_ready(req_rdy),
        .mem_rdata(cpu_read_data),
        .mem_addr(input_addr),
        .mem_wdata(input_data),
        .mem_we(writetrigger),
        .mem_re(readtrigger),
        .stall_fpu_out(cpu_fpu_stall) // ★これを追加！
    );

    // --- UART TX モジュール ---
    uart_tx #(
        .CLK_FREQ(30_000_000),
        .CLOCKS_PER_BIT(260)
    ) uart_tx_inst (
        .clk(cpu_clk),
        .rst(rst),
        .data_in(input_data[7:0]),
        .tx_enable(uart_we),
        .tx_out(uart_tx_o),
        .tx_busy(uart_tx_busy),
        .tx_ready(uart_tx_ready)
    );

    // --- UART RX モジュール ---
    uart_rx #(
        .CLK_FREQ(30_000_000),
        .CLOCKS_PER_BIT(260)
    ) uart_rx_inst (
        .clk(cpu_clk),
        .rst(rst),
        .rx_in(uart_rx_i),
        // ★修正: CPUの読み取り要求を、UART_RXの新設したrd_enポートに繋ぐ！
        .rd_en(uart_rx_rd_en), // ★FIFOが要求を出すように変更
        .data_out(rx_data_out),
        .data_valid(rx_data_valid)
    );

    // ★追加: 32bit結合＆FIFOモジュール
    uart_word_fifo uart_fifo_inst (
        .clk(cpu_clk),
        .rst(rst),
        .uart_rx_data(rx_data_out),
        .uart_rx_valid(rx_data_valid),
        .uart_rx_rd_en(uart_rx_rd_en),
        
        .cpu_rd_en(uart_re),
        .cpu_read_data(fifo_cpu_data),
        .cpu_data_valid(fifo_cpu_valid)
    );

    cachecontroller cachecontroller_inst (
        .ddr2_addr(ddr2_addr),
        .ddr2_ba(ddr2_ba),
        .ddr2_cas_n(ddr2_cas_n),
        .ddr2_ck_n(ddr2_ck_n),
        .ddr2_ck_p(ddr2_ck_p),
        .ddr2_cke(ddr2_cke),
        .ddr2_ras_n(ddr2_ras_n),
        .ddr2_we_n(ddr2_we_n),
        .ddr2_dq(ddr2_dq),
        .ddr2_dqs_n(ddr2_dqs_n),
        .ddr2_dqs_p(ddr2_dqs_p),
        .ddr2_cs_n(ddr2_cs_n),
        .ddr2_dm(ddr2_dm),
        .ddr2_odt(ddr2_odt),
        
        .clk(clk),
        .reset_n(rst),// ※ここは変更しない！(キャッシュとMIGは大元のリセットで動き始める必要があるため)
        
        .writetrigger(cache_writetrigger),
        .readtrigger(cache_readtrigger),
        .input_addr(input_addr),
        .input_data(input_data),
        .req_rdy(cache_req_rdy),
        .output_data(cache_rdata),
        
        .cpu_clk_out(cpu_clk), 
        .init_calib_complete_out(calib_done)
    );

endmodule

