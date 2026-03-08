//FPU_Top.sv
`default_nettype none

module FPU_Top (
    input  wire logic        clk,
    input  wire logic        rst_n,

    // 制御信号 (EXステージ)
    input  wire logic [31:0] instruction_ex, // 実行する命令
    input  wire logic [31:0] cpu_rdata1_ex,  // ★追加: itof用 (GPR rs -> FPU)
    input  wire logic [31:0] cpu_rdata2_ex,  // mtc1用 (GPR -> FPU)
    
    // メモリからのデータ (LWC1用: WBステージのタイミングで来る想定だが、
    // ここでは簡易的に外部から書き込み制御を受けるポートを用意)
    input  wire logic        ext_we,         // 外部からの書き込み有効 (LWC1, MTC1など)
    input  wire logic [4:0]  ext_waddr,      // 書き込み先レジスタ番号
    input  wire logic [31:0] ext_wdata,      // 書き込みデータ

    // 出力
    output logic [31:0]      fpu_rdata_ex,   // mfc1用 (FPU -> GPR)
    output logic [31:0]      fpu_wdata_ex,   // swc1用 (FPU -> Mem)
    output logic [31:0]      fpu_arith_result, // ★追加: ftoi用 (FPU結果 -> GPR)
    output logic             fpu_stall_req,  // 演算中のストール要求
    output logic             fpu_flag_out    // 条件フラグ出力 (for bc1t/bc1f)
);

    // =========================================================
    // 1. 命令デコード
    // =========================================================
    wire [5:0] opcode = instruction_ex[31:26];
    wire [5:0] funct  = instruction_ex[5:0];
    wire [4:0] fmt    = instruction_ex[25:21]; // S=16(10000), W=20(10100)
    wire [4:0] ft     = instruction_ex[20:16];
    wire [4:0] fs     = instruction_ex[15:11];
    wire [4:0] fd     = instruction_ex[10:6];
    
    // COP1命令判定
    wire is_cop1   = (opcode == 6'h11);
    
    // 演算命令 (fmt=16: S形式)
    wire is_fmt_s  = is_cop1 && (fmt == 5'd16);
    wire is_fadd   = is_fmt_s && (funct == 6'h00);
    wire is_fsub   = is_fmt_s && (funct == 6'h01);
    wire is_fmul   = is_fmt_s && (funct == 6'h02);
    wire is_fdiv   = is_fmt_s && (funct == 6'h03);
    wire is_fsqrt  = is_fmt_s && (funct == 6'h04);
    wire is_fabs   = is_fmt_s && (funct == 6'h05); // ★追加: fabs
    wire is_fneg   = is_fmt_s && (funct == 6'h07); // ★追加: fneg
    wire is_floor  = is_fmt_s && (funct == 6'h0F); // ★追加: floor
    wire is_ftoi   = is_fmt_s && (funct == 6'h24);
    
    // 比較命令 (fmt=16: S形式)
    wire is_c_eq   = is_fmt_s && (funct == 6'h32); // ★追加: c.eq.s
    //wire is_c_lt   = is_fmt_s && (funct == 6'h3C);
    wire is_c_le   = is_fmt_s && (funct == 6'h3E); // ★追加: c.le.s
    
    // 変換命令 (fmt=20: W形式)
    wire is_itof   = is_cop1 && (fmt == 5'd20) && (funct == 6'h20);
    
    // 転送命令
    wire is_swc1   = (opcode == 6'h39);
    wire is_mfc1   = is_cop1 && (fmt == 5'd00); // mfc1 rt, fs

    // =========================================================
    // 2. FPUレジスタファイル (32bit x 32本)
    // =========================================================
    logic [31:0] fpu_regs [31:0];
    logic        fpu_cond_flag; // 条件フラグ

    logic [31:0] reg_rdata_s, reg_rdata_t;
    
    // 内部演算結果書き込み用
    logic        internal_we;
    logic [4:0]  internal_waddr;
    logic [31:0] internal_wdata;

  /*  // 読み出し (ft, fs)
    always_comb begin
        reg_rdata_s = fpu_regs[fs];
        reg_rdata_t = fpu_regs[ft];
    end */

    // =========================================================
    // ★修正: FPU内部のデータフォワーディング（追い越し事故防止）
    // =========================================================
    logic [31:0] fpu_val_s, fpu_val_t;
    
    always_comb begin
        // fsの読み出し: もし1クロック前に計算が終わった値(internal_we)があれば、それを優先！
        if (internal_we && (internal_waddr == fs)) fpu_val_s = internal_wdata;
        else fpu_val_s = fpu_regs[fs];

        // ftの読み出し
        if (internal_we && (internal_waddr == ft)) fpu_val_t = internal_wdata;
        else fpu_val_t = fpu_regs[ft];
    end

    always_comb begin
        reg_rdata_s = fpu_val_s;
        reg_rdata_t = fpu_val_t;
    end

    // SWC1 / MFC1 用のデータ出力もフォワーディング済みの値を使う！
    assign fpu_wdata_ex = fpu_val_t; 
    assign fpu_rdata_ex = fpu_val_s;

    // 書き込み (外部からの要求 or 内部演算完了)
    always_ff @(posedge clk) begin
        if (ext_we) begin
            fpu_regs[ext_waddr] <= ext_wdata;
        end else if (internal_we) begin
            fpu_regs[internal_waddr] <= internal_wdata;
        end
    end
    
    // SWC1 / MFC1 用のデータ出力
   // assign fpu_wdata_ex = fpu_regs[ft]; // swc1はftの内容をメモリへ
    //assign fpu_rdata_ex = fpu_regs[fs]; // mfc1はfsの内容をGPRへ
    assign fpu_flag_out = fpu_cond_flag; // 出力接続

    // =========================================================
    // 3. 演算ユニット制御
    // =========================================================
    // ステートマシンによる実行管理
    enum logic [1:0] {IDLE, BUSY} state;
    
    // 演算開始トリガー: まだBUSYでなく、対象の命令が来たら
    wire start_arith = (state == IDLE) && (is_fadd | is_fsub | is_fmul | is_fdiv | is_fsqrt | is_ftoi | is_itof | is_fneg | is_fabs | is_floor | is_c_eq | is_c_le);
    
    // ★修正: itofの場合はGPRからの入力(cpu_rdata1_ex)を使う！
    //wire [31:0] op_a = reg_rdata_s;
    wire [31:0] op_a = is_itof ? cpu_rdata1_ex : reg_rdata_s;
    wire [31:0] op_b = is_fsub ? {~reg_rdata_t[31], reg_rdata_t[30:0]} : reg_rdata_t;

    // --- 各ユニットのインスタンス化 ---
    logic [31:0] res_add, res_mul, res_div, res_sqrt, res_ftoi, res_itof;
    logic        val_add, val_mul, val_div, val_sqrt, val_ftoi, val_itof;

    fadd u_fadd (
        .clk(clk), .rst_n(rst_n),
        .input_a(op_a), .input_b(op_b), .input_valid(start_arith && (is_fadd || is_fsub)),
        .result(res_add), .out_valid(val_add)
    );

    fmul u_fmul (
        .clk(clk), .rst_n(rst_n),
        .input_a(op_a), .input_b(op_b), .input_valid(start_arith && is_fmul),
        .result(res_mul), .out_valid(val_mul)
    );

    fdiv u_fdiv (
        .clk(clk), .rst_n(rst_n),
        .input_a(op_a), .input_b(op_b), .input_valid(start_arith && is_fdiv),
        .result(res_div), .out_valid(val_div)
    );

    fsqrt u_fsqrt (
        .clk(clk), .rst_n(rst_n),
        .input_a(op_a), .input_valid(start_arith && is_fsqrt),
        .result(res_sqrt), .out_valid(val_sqrt)
    );

    ftoi u_ftoi (
        .clk(clk), .rst_n(rst_n),
        .in_f(op_a), .input_valid(start_arith && is_ftoi),
        .out_i(res_ftoi), .out_valid(val_ftoi)
    );

    itof u_itof (
        .clk(clk), .rst_n(rst_n),
        .in_i(op_a), .input_valid(start_arith && is_itof),
        .out_f(res_itof), .out_valid(val_itof)
    );

    // --- ★追加: FNEG (1サイクル遅延で実装) ---
    logic [31:0] res_neg;
    logic        val_neg;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            res_neg <= 0;
            val_neg <= 0;
        end else begin
            val_neg <= start_arith && is_fneg;
            // 符号ビット反転
            res_neg <= {~op_a[31], op_a[30:0]};
        end
    end

    // --- ★追加: FABS (1サイクル遅延で実装) ---
    logic [31:0] res_abs;
    logic        val_abs;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            res_abs <= 0;
            val_abs <= 0;
        end else begin
            val_abs <= start_arith && is_fabs;
            res_abs <= {1'b0, op_a[30:0]}; // 符号ビットを強制的に0(正)にする
        end
    end

    // --- ★追加: FLOOR ---
    logic [31:0] res_floor;
    logic        val_floor;
    ffloor u_ffloor (
        .clk(clk), .rst_n(rst_n),
        .in_f(op_a), .input_valid(start_arith && is_floor),
        .out_f(res_floor), .out_valid(val_floor)
    );

    // --- ★追加: FCMP (1サイクル遅延で実装) ---
    logic val_cmp;
    logic cmp_result;
    
    // 比較ロジック (簡易実装: NaNチェック等は省略し、基本的な大小比較を行う)
    // +0 == -0 対応: (op_a[30:0] == 0) && (op_b[30:0] == 0) なら Equal
    wire a_zero = (op_a[30:0] == 0);
    wire b_zero = (op_b[30:0] == 0);
    wire ieee_eq = (a_zero && b_zero) || (op_a == op_b);
    
    // Less Than Equal
    // 符号付き比較が必要。
    // floatのビット表現は、正の数ならそのまま大小比較可能。
    // 負の数同士なら大小関係が逆転する。符号が違うなら正の方が大きい。
    logic ieee_le;
    always_comb begin
        if (a_zero && b_zero) ieee_le = 1;
        else if (op_a[31] != op_b[31]) ieee_le = op_a[31]; // Aが負(1)ならTrue
        else if (op_a[31]) ieee_le = (op_a >= op_b);       // 両方負: 絶対値が大きい(値が小さい)方がビット列は大きい
        else ieee_le = (op_a <= op_b);                     // 両方正
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            val_cmp <= 0;
            cmp_result <= 0;
        end else begin
            val_cmp <= start_arith && (is_c_eq || is_c_le);
            if (is_c_eq) cmp_result <= ieee_eq;
            if (is_c_le) cmp_result <= ieee_le;
        end
    end


    // =========================================================
    // 4. 結果の集約と書き戻し
    // =========================================================
    wire any_valid = val_add | val_mul | val_div | val_sqrt | val_ftoi | val_itof | val_neg | val_abs | val_floor | val_cmp;

    logic [31:0] result_mux;
    always_comb begin
        if (val_add)      result_mux = res_add;
        else if (val_mul) result_mux = res_mul;
        else if (val_div) result_mux = res_div;
        else if (val_sqrt) result_mux = res_sqrt;
        else if (val_ftoi) result_mux = res_ftoi;
        else if (val_itof) result_mux = res_itof;
        else if (val_neg) result_mux = res_neg; // fneg
        else if (val_abs) result_mux = res_abs; // fabs
        else if (val_floor) result_mux = res_floor; // floor
        else              result_mux = 32'b0;
    end

    // ★追加: GPR書き戻し用の直接出力
    assign fpu_arith_result = result_mux;

    // 制御ロジック
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            internal_we <= 0;
            internal_waddr <= 0;
            internal_wdata <= 0;
            fpu_cond_flag <= 0;
        end else begin
            internal_we <= 0; // デフォルトでLow

            case (state)
                IDLE: begin
                    if (start_arith) begin
                        state <= BUSY;
                        internal_waddr <= fd; // 書き込み先(fd)を保存
                    end
                end

                BUSY: begin
                    if (any_valid) begin
                        state <= IDLE;
                        
                        if (val_cmp) begin
                            // 比較命令はレジスタ書き込みせず、フラグのみ更新
                            fpu_cond_flag <= cmp_result;
                        end else if (val_ftoi) begin
                            // ★重要: ftoiはGPRに書くため、FPUレジスタには書き込まない！
                            internal_we <= 0;
                        end else begin
                            // 演算命令はレジスタ書き込み
                            internal_we <= 1;
                            internal_wdata <= result_mux;
                        end
                    end
                end
            endcase
        end
    end

    // ストール要求: BUSYの間はずっとCPUを止める
    //assign fpu_stall_req = (state == BUSY) || start_arith;

    // ストール要求: 計算が完了した瞬間(!any_valid)だけストールを解除し、パイプラインを進ませる
    assign fpu_stall_req = (state == BUSY && !any_valid) || start_arith;

endmodule
`default_nettype wire