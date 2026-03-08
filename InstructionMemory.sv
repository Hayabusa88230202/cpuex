// InstructionMemory.sv (fib(10) ハードコード版)
module InstructionMemory (
    input  logic        clk,         // クロック (入力は残すが、使わない)
    input  logic [31:0] ReadAddress,
    output logic [31:0] Instruction
);
    // アドレス（PC）をワードアドレス（0, 1, 2...）に変換
    wire [7:0] addr = ReadAddress[9:2];

    // BRAMを使わず、case文による組み合わせ回路(LUT)としてROMを実装
    // これならVivadoは絶対に無視できず、必ず回路化されます。
    always_comb begin
        case (addr)
            // fib(10) プログラム
            8'd0:  Instruction = 32'h2008000A; // addi $t0, $zero, 10
            8'd1:  Instruction = 32'h20090000; // addi $t1, $zero, 0
            8'd2:  Instruction = 32'h200A0001; // addi $t2, $zero, 1
            8'd3:  Instruction = 32'h200B0002; // addi $t3, $zero, 2
            8'd4:  Instruction = 32'h010B082A; // loop: slt $at, $t0, $t3
            8'd5:  Instruction = 32'h14200005; //       bne $at, $zero, end
            8'd6:  Instruction = 32'h012A6020; //       add $t4, $t1, $t2
            8'd7:  Instruction = 32'h01404820; //       add $t1, $t2, $zero
            8'd8:  Instruction = 32'h01805020; //       add $t2, $t4, $zero
            8'd9:  Instruction = 32'h216B0001; //       addi $t3, $t3, 1
            8'd10: Instruction = 32'h08000004; //       j loop (j 0x10)
            8'd11: Instruction = 32'h01402020; // end:  add $a0, $t2, $zero
            8'd12: Instruction = 32'hAC040064; //       sw  $a0, 100($zero)
            8'd13: Instruction = 32'h0800000D; // L_END: j L_END (j 0x34)
            
            default: Instruction = 32'h00000000; // nop
        endcase
    end

endmodule