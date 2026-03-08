`timescale 1ns / 1ps

module tb_top_uart;

    // ============================================================
    // 1. 信号定義
    // ============================================================
    logic clk;
    logic rst; // Active Low (top.svに合わせて確認してください。ここではtopのrstに合わせて制御します)
    
    // UART信号 (テストベンチ視点)
    logic uart_tx_to_core;   // TB(送信) -> Core(受信)
    logic uart_rx_from_core; // Core(送信) -> TB(受信)
    
    // その他のtopモジュール用信号 (今回は無視)
    wire [12:0] ddr2_addr;
    wire [2:0]  ddr2_ba;
    wire        ddr2_cas_n;
    wire [0:0]  ddr2_ck_n;
    wire [0:0]  ddr2_ck_p;
    wire [0:0]  ddr2_cke;
    wire        ddr2_ras_n;
    wire        ddr2_we_n;
    wire [15:0] ddr2_dq;
    wire [1:0]  ddr2_dqs_n;
    wire [1:0]  ddr2_dqs_p;
    wire [0:0]  ddr2_cs_n;
    wire [1:0]  ddr2_dm;
    wire [0:0]  ddr2_odt;
    wire [15:0] led;

    // 定数定義 (top.svの設定と合わせる必要があります)
    // シミュレーションでも実機と同じ設定で動かします。
    localparam CLK_FREQ = 100_000_000;
    localparam CLOCKS_PER_BIT = 8;
    localparam BIT_PERIOD_NS = (1000000000 / CLK_FREQ) * CLOCKS_PER_BIT; // 1ビットの送信にかかる時間(概算)

    // ============================================================
    // 2. インスタンス化
    // ============================================================

    // --- コア本体 (DUT) ---
    top u_top (
        .clk(clk),
        .rst(rst),
        .uart_rx_i(uart_tx_to_core),   // TBからの入力をコアのRXへ
        .uart_tx_o(uart_rx_from_core), // コアからの出力をTBのRXへ
        .led(led),
        // DDR2 (未接続でOK)
        .ddr2_addr(ddr2_addr), .ddr2_ba(ddr2_ba), .ddr2_cas_n(ddr2_cas_n),
        .ddr2_ck_n(ddr2_ck_n), .ddr2_ck_p(ddr2_ck_p), .ddr2_cke(ddr2_cke),
        .ddr2_ras_n(ddr2_ras_n), .ddr2_we_n(ddr2_we_n), .ddr2_dq(ddr2_dq),
        .ddr2_dqs_n(ddr2_dqs_n), .ddr2_dqs_p(ddr2_dqs_p), .ddr2_cs_n(ddr2_cs_n),
        .ddr2_dm(ddr2_dm), .ddr2_odt(ddr2_odt)
    );

    // --- テスト用送信機 (TB -> Core) ---
    logic [7:0] tb_tx_data;
    logic       tb_tx_start;
    logic       tb_tx_busy;
    logic       tb_tx_ready;

    uart_tx #(
        .CLK_FREQ(CLK_FREQ),
        .CLOCKS_PER_BIT(CLOCKS_PER_BIT)
    ) u_tb_tx (
        .clk(clk), // 注: 本来はtop内部のcpu_clkと同期すべきですが、簡易的にメインclkで駆動します
                   // (top内部でクロック生成されている場合、速度比に注意が必要ですが、今回は単純化します)
        .rst_n(rst), // uart_txはActive Lowリセット
        .data_in(tb_tx_data),
        .tx_enable(tb_tx_start),
        .tx_out(uart_tx_to_core),
        .tx_busy(tb_tx_busy),
        .tx_ready(tb_tx_ready)
    );

    // --- テスト用受信機 (Core -> TB) ---
    logic [7:0] tb_rx_data;
    logic       tb_rx_valid;

    uart_rx #(
        .CLK_FREQ(CLK_FREQ),
        .CLOCKS_PER_BIT(CLOCKS_PER_BIT)
    ) u_tb_rx (
        .clk(clk),
        .rst_n(rst), // uart_rxはActive Lowリセット
        .rx_in(uart_rx_from_core),
        .data_out(tb_rx_data),
        .data_valid(tb_rx_valid)
    );

    // ============================================================
    // 3. クロック生成
    // ============================================================
    // top.svが内部でクロック生成(MIG)をしている場合、シミュレーション用モデルが必要です。
    // もしMIGのシミュレーションが難しい場合、topのclk入力をそのまま内部cpu_clkとして使うように
    // 一時的にtop.svを修正する必要があるかもしれません。
    // ここでは、top.svの期待する入力クロック(例えば100MHz)を生成します。
    initial begin
        clk = 0;
        forever #5 clk = ~clk; // 100MHz (10ns周期)
    end

    // ============================================================
    // 4. テストシナリオ
    // ============================================================
    logic [7:0] test_pattern [0:3] = '{8'hAB, 8'h12, 8'h34, 8'h56}; // 送信したいデータ列

    initial begin
        // --- 初期化 ---
        rst = 0; // リセット assert
        tb_tx_start = 0;
        tb_tx_data = 0;
        
        // シミュレーション開始
        $display("=== UART Loopback Simulation Start ===");

        // リセット解除
        #100;
        rst = 1; // リセット deassert (Active Low想定)
        #100;

        // --- データ送信ループ ---
        for (int i = 0; i < 4; i++) begin
            // 1. データをセットして送信開始
            wait(tb_tx_ready); // 送信機が準備できるまで待つ
            @(posedge clk);
            tb_tx_data  <= test_pattern[i];
            tb_tx_start <= 1;
            @(posedge clk);
            tb_tx_start <= 0;
            
            $display("[TB] Sent: 0x%h at time %t", test_pattern[i], $time);

            // 2. 受信を待つ
            // CPUが受信 -> 処理 -> 送信完了するまでには時間がかかります。
            // タイムアウト付きで待ちます。
            fork
                begin
                    wait(tb_rx_valid);
                    $display("[TB] Received: 0x%h at time %t", tb_rx_data, $time);
                    
                    // チェック
                    if (tb_rx_data == test_pattern[i]) begin
                        $display("[TB] Check OK!");
                    end else begin
                        $display("[TB] Check NG! Expected 0x%h", test_pattern[i]);
                    end
                end
                begin
                    // タイムアウト設定 (通信速度に合わせて十分長く取る)
                    // 1バイト送信に (2083 * 10) クロック程度かかるため、往復でそれ以上待つ
                    #2000000; // 2ms待っても来なければタイムアウト
                    $display("[TB] Timeout waiting for echo back.");
                end
            join_any
            disable fork; // どちらかが終われば他方はキャンセル

            // 次の送信まで少し間隔を空ける
            #10000;
        end

        $display("=== Simulation Finished ===");
        $finish;
    end

endmodule