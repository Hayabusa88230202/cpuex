`timescale 1ns / 1ps

module fifo_to_axi_writer #(
  parameter AXI_ADDR_WIDTH = 32,
  parameter AXI_DATA_WIDTH = 128,
  parameter BURST_SIZE_BYTES = 16 // 128bit / 8
) (
  // System Signals
  input  wire                       aclk,
  input  wire                       aresetn,

  // FIFO Read Interface
  input  wire [BURST_SIZE_BYTES*8-1:0] fifo_rd_data_count, // FIFOのデータ数
  input  wire [7:0]                 fifo_dout,
  input  wire                       fifo_empty,
  output reg                        fifo_rd_en,

  // AXI4 Master Write Interface
  output reg  [AXI_ADDR_WIDTH-1:0] m_axi_awaddr,
  output reg  [7:0]                 m_axi_awlen,
  output reg  [2:0]                 m_axi_awsize,
  output reg  [1:0]                 m_axi_awburst,
  output reg                        m_axi_awvalid,
  input  wire                       m_axi_awready,

  output reg  [AXI_DATA_WIDTH-1:0] m_axi_wdata,
  output reg  [AXI_DATA_WIDTH/8-1:0] m_axi_wstrb,
  output reg                        m_axi_wlast,
  output reg                        m_axi_wvalid,
  input  wire                       m_axi_wready,

  input  wire [1:0]                 m_axi_bresp,
  input  wire                       m_axi_bvalid,
  output reg                        m_axi_bready
);

  // State machine definition
  localparam S_IDLE        = 3'b000;
  localparam S_GATHER_DATA = 3'b001; // FIFOからデータ収集
  localparam S_SEND_ADDR   = 3'b010; // AXIアドレス送信
  localparam S_SEND_DATA   = 3'b011; // AXIデータ送信
  localparam S_WAIT_RESP   = 3'b100; // AXI書き込み応答待ち

  reg [2:0] state;
  
  reg [AXI_ADDR_WIDTH-1:0] addr_reg;
  reg [AXI_DATA_WIDTH-1:0] data_buf;
  reg [3:0]                gather_count;

  // 初期化と状態遷移
  always @(posedge aclk) begin
    if (!aresetn) begin
      state <= S_IDLE;
      addr_reg <= 32'h10000000; // DDR2メモリの書き込み開始アドレス (任意)
      gather_count <= 0;
      fifo_rd_en <= 1'b0;
    end else begin
      case (state)
        S_IDLE: begin
          fifo_rd_en <= 1'b0;
          // FIFOに1burst分(16byte)以上のデータが溜まったら収集開始
          if (fifo_rd_data_count >= BURST_SIZE_BYTES) begin
            state <= S_GATHER_DATA;
            gather_count <= 0;
          end
        end

        S_GATHER_DATA: begin
          fifo_rd_en <= 1'b1; // FIFOから読み出し
          // little-endianでデータを格納
          data_buf[ (gather_count * 8) +: 8 ] <= fifo_dout;
          
          if (gather_count == BURST_SIZE_BYTES - 1) begin
            state <= S_SEND_ADDR;
            fifo_rd_en <= 1'b0;
          end
          gather_count <= gather_count + 1;
        end

        S_SEND_ADDR: begin
          if (m_axi_awvalid && m_axi_awready) begin
            state <= S_SEND_DATA;
          end
        end

        S_SEND_DATA: begin
          if (m_axi_wvalid && m_axi_wready) begin
            state <= S_WAIT_RESP;
          end
        end

        S_WAIT_RESP: begin
          if (m_axi_bvalid && m_axi_bready) begin
            state <= S_IDLE;
            addr_reg <= addr_reg + BURST_SIZE_BYTES; // 次の書き込みアドレスへ
          end
        end
      endcase
    end
  end

  // AXI信号の組み合わせロジック
  always @(*) begin
    // Default values
    m_axi_awvalid = 1'b0;
    m_axi_wvalid  = 1'b0;
    m_axi_bready  = 1'b0;

    case (state)
      S_SEND_ADDR: begin
        m_axi_awvalid = 1'b1;
      end
      S_SEND_DATA: begin
        m_axi_wvalid = 1'b1;
      end
      S_WAIT_RESP: begin
        m_axi_bready = 1'b1;
      end
    endcase
  end

  // AXI Write Address Channel Signals
  assign m_axi_awaddr = addr_reg;
  assign m_axi_awlen  = 8'd0;       // Burst length: 1 transfer (0 means 1)
  assign m_axi_awsize = 4;           // Burst size: 16 bytes (2^4)
  assign m_axi_awburst= 2'b01;     // Burst type: INCR

  // AXI Write Data Channel Signals
  assign m_axi_wdata  = data_buf;
  assign m_axi_wstrb  = {BURST_SIZE_BYTES{1'b1}}; // 全バイト有効
  assign m_axi_wlast  = 1'b1;                     // 1転送で終わるので常に1

endmodule
