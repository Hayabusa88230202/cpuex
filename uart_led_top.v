// uart_led_top.v
`timescale 1ns / 1ps

module uart_led_top (
  input  wire        clk,
  input  wire        uart_rx_i,
  output wire [15:0] led
);
  reg uart_rx_sync1;
  reg uart_rx_sync2;

  always @(posedge clk) begin
    uart_rx_sync1 <= uart_rx_i;
    uart_rx_sync2 <= uart_rx_sync1;
  end

  wire [7:0] rx_byte;
  wire       rx_byte_valid;
  wire       fifo_full;

  wire [7:0] fifo_dout;
  wire       fifo_empty;
  reg        fifo_rd_en;


  reg [7:0] led_reg;

  // uart_rxモジュールをインスタンス化
  uart_rx #(
    .CLK_FREQ(30_000_000),
    .BAUD_RATE(115200)
  ) urx_inst (
    .clk(clk),
    .rst(1'b0),
    .rx_in(uart_rx_sync2),
    .data_out(rx_byte),
    .data_valid(rx_byte_valid)
  );

  fifo_generator_0 fifo_inst (
    .clk(clk),
    .srst(1'b0),
    .din(rx_byte),
    .wr_en(rx_byte_valid),
    .rd_en(fifo_rd_en),
    .dout(fifo_dout),
    .full(fifo_full),
    .empty(fifo_empty)
  );

  always @(posedge clk) begin
    if (!fifo_empty && fifo_rd_en) begin
      led_reg <= fifo_dout;
    end
  end

  always @(*) begin
    if (!fifo_empty) begin
      fifo_rd_en = 1'b1;
    end else begin
      fifo_rd_en = 1'b0;
    end
  end


  assign led[7:0] = led_reg;
  assign led[15:8] = 8'b0;

endmodule