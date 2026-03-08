//tb_top.sv

`timescale 1ns / 1ps
`default_nettype wire

module tb_top;

    // =================================================================
    // 1. テストベンチのパラメータ設定
    // =================================================================
    // ★ 送信するプログラムのワード数（命令数）を指定します
    parameter PROG_WORDS = 15; 
    localparam PROG_BYTES = PROG_WORDS * 4; // server.py はバイト数で送るため ×4
    localparam BAUDRATE = 115200;
    localparam BIT_PERIOD_NS = 1000000000 / BAUDRATE; // 1ビットあたりの時間(ns)

    // 送信するプログラムの格納メモリ
    logic [31:0] prog_mem [0:PROG_WORDS-1];

    // =================================================================
    // 2. 信号の宣言
    // =================================================================
    logic clk;
    logic rst;
    // ★信号の宣言時に = 1'b1 をつけて、初期状態をハイ(待機)にする
    logic uart_rx_i = 1'b1;
    wire  uart_tx_o;
    wire [15:0] led;
    // --- UART RX モジュール ---
    logic [7:0] rx_data_tb;
    logic rx_data_valid_tb;
    logic [7:0] tx_data_tb = 8'h00; // 初期値
    logic uart_tx_enable_tb = 1'b0; // 初期値
    logic uart_tx_busy_tb;
    logic uart_tx_ready_tb;

    // DDR2ダミーワイヤ
    wire [12:0] ddr2_addr; wire [2:0] ddr2_ba; wire ddr2_cas_n;
    wire [0:0] ddr2_ck_n; wire [0:0] ddr2_ck_p; wire [0:0] ddr2_cke;
    wire ddr2_ras_n; wire ddr2_we_n; wire [15:0] ddr2_dq;
    wire [1:0] ddr2_dqs_n; wire [1:0] ddr2_dqs_p;
    wire [0:0] ddr2_cs_n; wire [1:0] ddr2_dm; wire [0:0] ddr2_odt;

    // =================================================================
    // 3. DUT (Device Under Test) のインスタンス化
    // =================================================================
    top dut (
        .ddr2_addr(ddr2_addr), .ddr2_ba(ddr2_ba), .ddr2_cas_n(ddr2_cas_n),
        .ddr2_ck_n(ddr2_ck_n), .ddr2_ck_p(ddr2_ck_p), .ddr2_cke(ddr2_cke),
        .ddr2_ras_n(ddr2_ras_n), .ddr2_we_n(ddr2_we_n), .ddr2_dq(ddr2_dq),
        .ddr2_dqs_n(ddr2_dqs_n), .ddr2_dqs_p(ddr2_dqs_p), .ddr2_cs_n(ddr2_cs_n),
        .ddr2_dm(ddr2_dm), .ddr2_odt(ddr2_odt),
        .clk(clk),
        .rst(rst),
        .led(led),
        .uart_rx_i(uart_rx_i),
        .uart_tx_o(uart_tx_o)
    );

    // =================================================================
    // 4. クロック生成 (30MHz = 約33.333ns周期)
    // =================================================================
    initial begin
        clk = 1'b0;
        // 16.667nsごとに反転 = 33.334ns周期 (ほぼピッタリ30MHz)
        forever #5 clk = ~clk; 
    end

    // =================================================================
    // 5. 実行シナリオ (server.py の完全再現)
    // =================================================================
    logic [7:0] rx_byte;
    int i;

    initial begin
        // --- 準備フェーズ ---
        // テスト用のプログラムを配列にセット ($readmemh "program.hex" の代わり)
        $readmemh("C:/Users/hayab/CPU_EXPERIMENT/CPU_CORE_SINGLE_PIPELINE_cashe/fadd_test.hex", prog_mem);
        
        
        @(posedge dut.uart_tx_inst.clk);
        rst = 1'b0;        // リセットON (Active Low)
        uart_rx_i = 1'b1;  // UARTアイドル状態

        #100;
        rst = 1'b1;        // リセット解除、FPGA稼働開始！
        $display("[%0t] FPGA Booted.", $time);

        // --- STEP 1: 0x99 を待つ ---
        $display("[%0t] Waiting for 0x99 from FPGA...", $time);
        do begin
            recv_uart_byte(rx_byte);
            // ★追加: テストベンチが何かを受信するたびにコンソールに表示する！
            $display("[%0t] Testbench Received byte: %h", $time, rx_byte);
        end while (rx_byte !== 8'h99);
        $display("[%0t] 0x99 Received!", $time);

        // =================================================================
        // ★究極の修正: 50usの時間待機ではなく、MIGの準備完了信号を直接見て待つ！
        // =================================================================
        $display("[%0t] Waiting for DDR2 Calibration to complete...", $time);
        wait(dut.calib_done == 1'b1); 
        #1000; // 念のため追加で1us待機
        $display("[%0t] DDR2 Ready! Start sending program.", $time);

        // --- STEP 2: サイズ情報(バイト数)を4バイトで送信 ---
        $display("[%0t] Sending program size: %0d bytes", $time, PROG_BYTES);
        // リトルエンディアンで下位バイトから順に送信
        send_uart_byte(PROG_BYTES[7:0]);
        send_uart_byte(PROG_BYTES[15:8]);
        send_uart_byte(PROG_BYTES[23:16]);
        send_uart_byte(PROG_BYTES[31:24]);

        // --- STEP 3: プログラム本体を送信 ---
        $display("[%0t] Sending program data...", $time);
        for (i = 0; i < PROG_WORDS; i++) begin
            logic [31:0] word = prog_mem[i];
            // MIPS/server.py の仕様に合わせてリトルエンディアンで送信
            send_uart_byte(word[7:0]);
            send_uart_byte(word[15:8]);
            send_uart_byte(word[23:16]);
            send_uart_byte(word[31:24]);
            $display("[%0t] Sent word[%0d]: %h", $time, i, word);
        end
        $display("[%0t] Program data sent!", $time);

    /*    // --- STEP 4: 0xaa を待つ ---
        $display("[%0t] Waiting for 0xaa from FPGA...", $time);
        do begin
            recv_uart_byte(rx_byte);
        end while (rx_byte !== 8'haa);
        $display("[%0t] 0xaa Received! Bootloader finished. CPU is running Fib...", $time);

        // --- STEP 5: Fibからの計算結果を待つ！ ---
        $display("[%0t] Waiting for Fibonacci result...", $time);
        recv_uart_byte(rx_byte); // Fibプログラムが送ってくる答えを受信
        $display("[%0t] ★★★ FPGA Result: %h ★★★", $time, rx_byte);
    */

        // --- STEP 4: 0xaa を待つ ---
        $display("[%0t] Waiting for 0xaa from FPGA...", $time);
        do begin
            recv_uart_byte(rx_byte);
        end while (rx_byte !== 8'haa);
        $display("[%0t] 0xaa Received! Bootloader finished. CPU is running FPU Test...", $time);

        // --- STEP 5: FPUからの計算結果を待つ！ ---
        $display("[%0t] Waiting for FPU result (Expected: 0x42)...", $time);
        recv_uart_byte(rx_byte); // FPUプログラムが送ってくる答えを受信
        
        $display("==================================================");
        $display("[%0t] ★★★ FPGA Result: %h ★★★", $time, rx_byte);
        if (rx_byte === 8'h42) begin
            $display("[%0t] >>> SUCCESS! FPU fadd is working perfectly! <<<", $time);
        end else begin
            $display("[%0t] >>> FAILED! Expected 0x42, but got %h <<<", $time, rx_byte);
        end
        $display("==================================================");
       
        $finish; // テスト終了
        
/*
        #100000;
        $display("[%0t] Simulation finished.", $time);
        $finish;*/
    end

    // =================================================================
    // 6. UART タスク群
    // ================================================================

    uart_rx #(
        .CLK_FREQ(100_000_000),
        .CLOCKS_PER_BIT(8)
    ) uart_rx_inst (
        .clk(clk),
        .rst(rst),
        .rx_in(uart_tx_o),
        // ★修正: CPUの読み取り要求を、UART_RXの新設したrd_enポートに繋ぐ！
        .rd_en(1'b1),
        .data_out(rx_data_tb),
        .data_valid(rx_data_valid_tb)
    );

    task automatic recv_uart_byte(output logic [7:0] data);
        begin
            @(posedge rx_data_valid_tb);
            data = rx_data_tb;
        end
    endtask
        
        // --- UART TX モジュール ---
    uart_tx #(
        .CLK_FREQ(100_000_000),
        .CLOCKS_PER_BIT(8)
    ) uart_tx_inst (
        .clk(clk),
        .rst(rst),
        .data_in(tx_data_tb[7:0]),
        .tx_enable(uart_tx_enable_tb),
        .tx_out(uart_rx_i),
        .tx_busy(uart_tx_busy_tb),
        .tx_ready(uart_tx_ready_tb)
    );

   /* // =================================================================
    // 【送信タスク】 1バイトをFPGAへ送る (クロック完全同期・堅牢版)
    // =================================================================
    task automatic send_uart_byte(input logic [7:0] data);
        begin
            // 1. 前の送信が完全に終わる(readyになる)のを待つ
            while (uart_tx_ready_tb == 1'b0) @(posedge clk);
            
            // 2. データをセットし、送信要求を出す
            tx_data_tb <= data;
            uart_tx_enable_tb <= 1'b1;
            
            // 3. 1クロック待って要求を下ろす (綺麗な1クロックパルス)
            @(posedge clk);
            uart_tx_enable_tb <= 1'b0;
            
            // 4. 送信が開始される(busyが1になる)のを待つ
            while (uart_tx_busy_tb == 1'b0) @(posedge clk);
            
            // 5. 送信が完了する(readyが1になる)のを待つ
            while (uart_tx_ready_tb == 1'b0) @(posedge clk);
        end
    endtask */
    // =================================================================
    // 【送信タスク】 (一番下にあるタスクを丸ごと差し替え)
    // =================================================================
    task automatic send_uart_byte(input logic [7:0] data);
        begin
            while (uart_tx_ready_tb == 1'b0) @(posedge clk);
            
            tx_data_tb <= data;
            uart_tx_enable_tb <= 1'b1;
            
            // ★究極の修正: tx_busy が 1 になるまで enable を絶対に下げない！(見落とし防止)
            while (uart_tx_busy_tb == 1'b0) @(posedge clk);
            
            uart_tx_enable_tb <= 1'b0;
            
            while (uart_tx_ready_tb == 1'b0) @(posedge clk);
        end
    endtask

   /*2 logic [7:0] data_to_uart_tb;
    logic tb_uart_en;
    // 【送信タスク】 1バイトをFPGAへ送る
    task send_uart_byte(input logic [7:0] data);
        begin
            wait(uart_tx_ready_tb);
            @(posedge clk);
            data_to_uart_tb = data;
            tb_uart_en = 1'b1;
            @(posedge clk);
            tb_uart_en = 1'b0;

        end
    endtask

    always_ff @(posedge clk) begin
        if (uart_tx_ready_tb && tb_uart_en) begin
            uart_tx_enable_tb <= 1;
            tx_data_tb <= data_to_uart_tb;
        end else begin
            uart_tx_enable_tb <= 0;
        end
    end */


/*
    // 【受信タスク】 FPGAからの1バイトを待って読み取る
    task recv_uart_byte(output logic [7:0] data);
        integer j;
        begin
            // スタートビット(High -> Low)の立ち下がりを待つ
            wait (uart_tx_o == 1'b0);
            
            // ビットの中央へ移動 (半ビット幅待つ)
            #(BIT_PERIOD_NS / 2);
            
            if (uart_tx_o == 1'b0) begin // スタートビット確認
                // 1ビット幅ずつ進みながら8回サンプリング
                for (j = 0; j < 8; j = j + 1) begin
                    #(BIT_PERIOD_NS);
                    data[j] = uart_tx_o;
                end
                
                // ストップビット(High)の中央まで待つ
                #(BIT_PERIOD_NS);
                // 次のスタートビット検出に備え、Stopビットの途中でタスクを抜ける
            end
        end
    endtask
    1
*/
    // =================================================================
    // ★追加: DDR2メモリのシミュレーションモデルをインスタンス化
    // =================================================================
    ddr2_model u_comp_ddr2 (
        .ck      (ddr2_ck_p[0]),
        .ck_n    (ddr2_ck_n[0]),
        .cke     (ddr2_cke[0]),
        .cs_n    (ddr2_cs_n[0]),
        .ras_n   (ddr2_ras_n),
        .cas_n   (ddr2_cas_n),
        .we_n    (ddr2_we_n),
        .dm_rdqs (ddr2_dm),
        .ba      (ddr2_ba),
        .addr    (ddr2_addr),
        .dq      (ddr2_dq),
        .dqs     (ddr2_dqs_p),
        .dqs_n   (ddr2_dqs_n),
        .rdqs_n  (), // 未接続でOK
        .odt     (ddr2_odt[0])
    );

endmodule