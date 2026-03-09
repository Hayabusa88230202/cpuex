// fdiv_10.sv

`default_nettype none

module fdiv (

    input  wire logic        clk,

    input  wire logic        rst_n,

    input  wire logic [31:0] input_a,

    input  wire logic [31:0] input_b,

    input  wire logic        input_valid,

    output logic [31:0]      result,

    output logic             out_valid  

);

    // ★追加: シミュレータ規定の厳密なビットパターン

    localparam [31:0] FP_INF      = 32'b0_11111111_00000000000000000000000;

    localparam [31:0] FP_NAN      = 32'b0_11111111_10000000000000000000000;

    localparam [31:0] FP_ZERO     = 32'b0_00000000_00000000000000000000000;

    localparam [31:0] FP_NON_NORM = 32'b0_00000000_11111111111110000000000;



    wire s_a = input_a[31];

    wire [7:0] e_a = input_a[30:23];

    wire s_b = input_b[31];

    wire [7:0] e_b = input_b[30:23];



    wire [23:0] m_a = (|e_a) ? {1'b1, input_a[22:0]} : {1'b0, input_a[22:0]};

    wire [23:0] m_b = (|e_b) ? {1'b1, input_b[22:0]} : {1'b0, input_b[22:0]};



    wire [7:0] calc_e_a = (|e_a) ? e_a : 8'd1;

    wire [7:0] calc_e_b = (|e_b) ? e_b : 8'd1;



    // ★修正: 入力の非正規化数(e==0かつm!=0)も「0」として扱う (FTZ: Flush To Zero)

    wire a_is_zero = (e_a == 8'b0);

    wire b_is_zero = (e_b == 8'b0);

    wire a_is_nan = (&e_a) && (input_a[22:0] != 0);

    wire b_is_nan = (&e_b) && (input_b[22:0] != 0);

    wire a_is_inf = (&e_a) && (input_a[22:0] == 0);

    wire b_is_inf = (&e_b) && (input_b[22:0] == 0);



    reg [9:0] pipe_sign;

    reg signed [9:0] pipe_exponent[0:9];

    reg [9:0] pipe_nan;

    reg [9:0] pipe_zero;

    reg [9:0] pipe_inf;



    wire [25:0] sub_mantissa;

    wire sub_mantissa_valid;



    fdiv_mantissa u_fdiv_mantissa (

        .clk(clk),

        .rst_n(rst_n),

        .input_valid(input_valid),

        .diviend(m_a),

        .divisor(m_b),

        .quotient(sub_mantissa),

        .out_valid(sub_mantissa_valid)

    );



    always @(posedge clk or negedge rst_n) begin

        integer i;

        reg signed [9:0] calc_exp;

        if (!rst_n) begin

            pipe_sign <= 10'b0;

            pipe_zero <= 10'b0;

            pipe_inf  <= 10'b0;

            pipe_nan  <= 10'b0;

            for (i = 0; i <= 9; i = i + 1) pipe_exponent[i] <= 10'b0;

        end else begin

            pipe_sign[0] <= s_a ^ s_b;



            calc_exp = {2'b0, calc_e_a} - {2'b0, calc_e_b} + 10'd127;

            pipe_exponent[0] <= calc_exp;



            // ★例外判定ロジック (0割り, Inf/Inf, 0/0 等)

            if (a_is_nan || b_is_nan || (a_is_zero && b_is_zero) || (a_is_inf && b_is_inf)) begin

                pipe_nan[0] <= 1'b1; pipe_inf[0] <= 1'b0; pipe_zero[0] <= 1'b0;

            end else if (a_is_inf || b_is_zero) begin

                pipe_nan[0] <= 1'b0; pipe_inf[0] <= 1'b1; pipe_zero[0] <= 1'b0;

            end else if (a_is_zero || b_is_inf) begin

                pipe_nan[0] <= 1'b0; pipe_inf[0] <= 1'b0; pipe_zero[0] <= 1'b1;

            end else begin

                pipe_nan[0] <= 1'b0; pipe_inf[0] <= 1'b0; pipe_zero[0] <= 1'b0;

            end



            // Stage 1 to 9

            for (i = 1; i <= 9; i = i + 1) begin

                pipe_sign[i]     <= pipe_sign[i-1];

                pipe_exponent[i] <= pipe_exponent[i-1];

                pipe_nan[i]      <= pipe_nan[i-1];

                pipe_inf[i]      <= pipe_inf[i-1];

                pipe_zero[i]     <= pipe_zero[i-1];

            end

        end

    end



    reg signed [9:0] temp_exp;

    reg [25:0] temp_mantissa;

    reg [24:0] mantissa_rounded;



    always @(posedge clk or negedge rst_n) begin

        if (!rst_n) begin

            result <= 32'b0;

            out_valid <= 1'b0;

        end else begin

            out_valid <= sub_mantissa_valid;

            temp_exp = pipe_exponent[9];

            temp_mantissa = sub_mantissa;

           

            // ★出力例外の適用 (符号は維持しつつ、指定のビットパターンを返す)

            if (pipe_nan[9]) begin

                result <= FP_NAN;

            end else if (pipe_inf[9]) begin

                result <= {pipe_sign[9], FP_INF[30:0]};

            end else if (pipe_zero[9]) begin

                result <= {pipe_sign[9], FP_ZERO[30:0]};

            end else if (sub_mantissa_valid) begin

               

                if (temp_mantissa[25] == 1'b1) begin

                    mantissa_rounded = {1'b0, temp_mantissa[25:2]} + {24'b0, temp_mantissa[1]};

                   

                    if (mantissa_rounded[24]) begin

                        if ((temp_exp + 1) >= 8'hFF) result <= {pipe_sign[9], FP_INF[30:0]}; // Overflow

                        else result <= {pipe_sign[9], (temp_exp[7:0] + 8'd1), mantissa_rounded[23:1]};

                    end else begin

                        if (temp_exp <= 0) result <= {pipe_sign[9], FP_NON_NORM[30:0]}; // Underflow

                        else if (temp_exp >= 8'hFF) result <= {pipe_sign[9], FP_INF[30:0]}; // Overflow

                        else result <= {pipe_sign[9], temp_exp[7:0], mantissa_rounded[22:0]};

                    end



                end else begin

                    mantissa_rounded = {1'b0, temp_mantissa[24:1]} + {24'b0, temp_mantissa[0]};



                    if (mantissa_rounded[24]) begin

                         if (temp_exp <= 0) result <= {pipe_sign[9], FP_NON_NORM[30:0]};

                         else if (temp_exp >= 8'hFF) result <= {pipe_sign[9], FP_INF[30:0]};

                         else result <= {pipe_sign[9], temp_exp[7:0], mantissa_rounded[23:1]};

                    end else begin

                        if ((temp_exp - 1) <= 0) result <= {pipe_sign[9], FP_NON_NORM[30:0]};

                        else if ((temp_exp - 1) >= 8'hFF) result <= {pipe_sign[9], FP_INF[30:0]};

                        else result <= {pipe_sign[9], (temp_exp[7:0] - 8'd1), mantissa_rounded[22:0]};

                    end

                end

            end

        end

    end

endmodule

// fdiv_mantissa の部分は変更不要ですが、一応そのまま貼り付けます

module fdiv_mantissa (

    input wire clk,

    input wire rst_n,

    input wire input_valid,

    input wire [23:0] diviend,

    input wire [23:0] divisor,

    output wire [25:0] quotient,

    output wire out_valid

);

    reg [25:0] pipe_rem [0:9];

    reg [25:0] pipe_quo [0:9];

    reg [23:0] pipe_div [0:9];

    reg [9:0]  pipe_val;



    integer k, i;

    always @(posedge clk or negedge rst_n) begin

        if (!rst_n) begin

            pipe_val <= 10'b0;

            for (k = 0; k <= 9; k = k + 1) begin

                pipe_rem[k] <= 26'b0;

                pipe_quo[k] <= 26'b0;

                pipe_div[k] <= 24'b0;

            end

        end else begin

            pipe_val[0] <= input_valid;

            pipe_rem[0] <= {2'b0, diviend};

            pipe_quo[0] <= 26'b0;

            pipe_div[0] <= divisor;



            pipe_val[9:1] <= pipe_val[8:0];

            for (k = 0; k < 9; k = k + 1) begin

                reg [25:0] t_rem;

                reg [25:0] t_quo;

                reg [23:0] t_div;

                reg [25:0] t_diff;

               

                t_rem = pipe_rem[k];

                t_quo = pipe_quo[k];

                t_div = pipe_div[k];

               

                for (i = 0; i < (k == 0 ? 2 : 3); i = i + 1) begin

                    t_diff = t_rem - {2'b0, t_div};

                    if (t_diff[25] == 0) begin

                        t_rem = t_diff;

                        t_quo = (t_quo << 1) | 1'b1;

                    end else begin

                        t_quo = t_quo << 1;

                    end

                    t_rem = t_rem << 1;

                end



                pipe_rem[k+1] <= t_rem;

                pipe_quo[k+1] <= t_quo;

                pipe_div[k+1] <= t_div;

            end

        end

    end



    assign quotient  = pipe_quo[9];

    assign out_valid = pipe_val[9];



endmodule










