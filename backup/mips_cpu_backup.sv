// MIPS_CPU.sv (Refactored & Verified)
`default_nettype wire

module MIPS_CPU (
    input  logic        clk,
    input  logic        rst, // アクティブロー
    output logic [15:0] led,

    // --- Cache/Memory Interface ---
    input  logic        mem_ready,    // Cache req_rdy
    input  logic [31:0] mem_rdata,    // Cache output_data
    output logic [31:0] mem_addr,     // Cache input_addr
    output logic [31:0] mem_wdata,    // Cache input_data
    output logic        mem_we,       // Cache writetrigger
    output logic        mem_re        // Cache readtrigger
);

// =================================================================
//  1. Wire Declarations (Forward Definitions)
// =================================================================
    // PC & Instruction
    (* mark_debug = "true" *) wire [31:0] pc_current;
    (* mark_debug = "true" *) wire [31:0] instruction_id;
    wire [31:0] pc_plus_4_if;
    wire [31:0] pc_plus_4_id;
    wire [31:0] instruction_fetched;

    // Hazard & Stall Control Signals
    wire stall_pc, stall_if_id, stall_id_ex, stall_ex_mem, stall_mem_wb;
    wire flush_if_id, flush_id_ex;
    wire load_use_stall, load_use_flush;
    wire branch_taken_ex;

    // FPU Control
    wire stall_fpu;
    wire fpu_flag_ex;
    wire [31:0] fpu_rdata_ex, fpu_wdata_ex;

// =================================================================
//  2. Hazard & Stall Control Logic
// =================================================================
    wire is_mem_access = MemRead_mem || MemWrite_mem;
    wire fetching_from_dram = (pc_current >= 32'h00400000);
    wire structural_hazard  = is_mem_access && fetching_from_dram;

    // ★修正: パルス待ちを消去し、シンプルに Ready が来るまで待つだけにする
    wire mem_busy = (mem_re || mem_we) && !mem_ready;

    assign stall_pc     = load_use_stall || mem_busy || stall_fpu || structural_hazard;
    assign stall_if_id  = load_use_stall || mem_busy || stall_fpu;
    assign stall_id_ex  = mem_busy || stall_fpu;
    assign stall_ex_mem = mem_busy || stall_fpu;
    assign stall_mem_wb = mem_busy || stall_fpu;

    assign flush_if_id  = branch_taken_ex || (structural_hazard && !stall_if_id);
    // ★ここが前回のバグ修正の要（そのままキープ！）
    assign flush_id_ex  = (load_use_flush || branch_taken_ex) && !stall_ex_mem && !stall_fpu;


// =================================================================
//  3. Stage 1: IF (Instruction Fetch)
// =================================================================
    // --- Next PC MUX ---
    // Priority: jr > jump > branch > PC+4
    wire [31:0] pc_in = (is_jr_ex)       ? alu_input_a_ex :        // JR, JALR
                        (Jump_ex)        ? jump_target_addr_ex :   // J, JAL
                        (branch_cond_ex) ? branch_target_addr_ex : // BEQ, BNE, BC1T
                                           pc_plus_4_if;           // Default

    ProgramCounter pc_unit (
        .clk(clk), .rst(rst),
        .i_stall(stall_pc),
        .PC_in(pc_in), .PC_out(pc_current)
    );
    
    assign pc_plus_4_if = pc_current + 32'd4;

    // --- Internal ROM (Bootloader) ---
    logic [31:0] internal_rom_out;
    InstructionMemory_readmemh instr_mem (
        .clk(clk),
        .ReadAddress(pc_current), 
        .Instruction(internal_rom_out)
    );
    /*
    InstructionMemory_readmemh instr_mem (
        .clk(clk),
        .ReadAddress(pc_current), 
        .Instruction(internal_rom_out),
        .write_addr(data_addr),
        .write_data(data_wdata),
        .write_enable((data_addrがテキスト領域にある && mem_we))
    );
    */

    // --- Instruction Data MUX ---
    assign instruction_fetched = (pc_current < 32'h00400000) ? internal_rom_out : mem_rdata;

// =================================================================
//  4. Pipeline Register: IF -> ID
// =================================================================
    PipelineRegister_IF_ID if_id_reg (
        .clk(clk), .rst(rst),
        .i_stall(stall_if_id),
        .i_flush(flush_if_id),
        .i_instruction(instruction_fetched), 
        .i_pc_plus_4(pc_plus_4_if),
        .o_instruction(instruction_id),
        .o_pc_plus_4(pc_plus_4_id)
    );


// =================================================================
//  5. Stage 2: ID (Decode & Register Read)
// =================================================================
    wire [1:0] RegDst_id, MemToReg_id;
    wire [2:0] ALUOp_id;
    wire ALUSrc_id, RegWrite_id, MemRead_id, MemWrite_id;
    wire BEQ_id, BNE_id, Jump_id, ExtOp_id, BranchFP_id;
    wire [31:0] read_data_1_id, read_data_2_id, sign_extended_imm_id;

    MainController main_controller_unit (
        .Opcode(instruction_id[31:26]), .Funct(instruction_id[5:0]), .Rs(instruction_id[25:21]),
        .RegDst(RegDst_id), .ALUSrc(ALUSrc_id), .MemToReg(MemToReg_id),
        .RegWrite(RegWrite_id), .MemRead(MemRead_id), .MemWrite(MemWrite_id),
        .Beq(BEQ_id), .Bne(BNE_id), .Jump(Jump_id), .ExtOp(ExtOp_id), 
        .ALUOp(ALUOp_id), .BranchFP(BranchFP_id)
    );
    
    // ExtOp_id=1: 符号拡張, ExtOp_id=0: ゼロ拡張
    assign sign_extended_imm_id = (ExtOp_id) ? {{16{instruction_id[15]}}, instruction_id[15:0]} 
                                             : {16'b0, instruction_id[15:0]};
    
    RegisterFile rf_unit (
        .clk(clk), .rst(rst),
        .ReadAddr1(instruction_id[25:21]),
        .ReadAddr2(instruction_id[20:16]),
        .ReadData1(read_data_1_id),
        .ReadData2(read_data_2_id),
        .RegWrite(RegWrite_wb),      // Fed from WB stage
        .WriteAddr(Write_Addr_wb),   // Fed from WB stage
        .WriteData(write_data_wb)    // Fed from WB stage
    );


// =================================================================
//  6. Pipeline Register: ID -> EX
// =================================================================
    wire [1:0] RegDst_ex, MemToReg_ex;
    wire [2:0] ALUOp_ex;
    wire ALUSrc_ex, RegWrite_ex, MemRead_ex, MemWrite_ex;
    wire BEQ_ex, BNE_ex, Jump_ex, BranchFP_ex;
    wire [31:0] ReadData1_ex, ReadData2_ex, SignExtendedImm_ex, PC_Plus_4_ex;
    wire [25:0] JumpIndex_ex;
    wire [5:0] Funct_ex;
    wire [4:0] ShiftAmount_ex;
    wire [31:0] instruction_ex;
    
    (* mark_debug = "true" *) wire [4:0] rs_addr_ex, rt_addr_ex;
    wire [4:0] rd_addr_ex, write_addr_ex;

    PipelineRegister_ID_EX id_ex_reg (
        .clk(clk), .rst(rst),
        .i_stall(stall_id_ex), .i_flush(flush_id_ex),
        // Control
        .i_RegDst(RegDst_id), .i_ALUSrc(ALUSrc_id), .i_MemToReg(MemToReg_id),
        .i_RegWrite(RegWrite_id), .i_MemRead(MemRead_id), .i_MemWrite(MemWrite_id),
        .i_BEQ(BEQ_id), .i_BNE(BNE_id), .i_Jump(Jump_id), .i_ALUOp(ALUOp_id), .i_BranchFP(BranchFP_id),
        // Data
        .i_ReadData1(read_data_1_id), .i_ReadData2(read_data_2_id),
        .i_SignExtendedImm(sign_extended_imm_id), .i_PC_Plus_4(pc_plus_4_id),
        .i_JumpIndex(instruction_id[25:0]), .i_Funct(instruction_id[5:0]), .i_ShiftAmount(instruction_id[10:6]),
        .i_rs_addr(instruction_id[25:21]), .i_rt_addr(instruction_id[20:16]), .i_rd_addr(instruction_id[15:11]),
        .i_instruction(instruction_id),

        // Outputs
        .o_RegDst(RegDst_ex), .o_ALUSrc(ALUSrc_ex), .o_MemToReg(MemToReg_ex),
        .o_RegWrite(RegWrite_ex), .o_MemRead(MemRead_ex), .o_MemWrite(MemWrite_ex),
        .o_BEQ(BEQ_ex), .o_BNE(BNE_ex), .o_Jump(Jump_ex), .o_ALUOp(ALUOp_ex), .o_BranchFP(BranchFP_ex),
        .o_ReadData1(ReadData1_ex), .o_ReadData2(ReadData2_ex),
        .o_SignExtendedImm(SignExtendedImm_ex), .o_PC_Plus_4(PC_Plus_4_ex),
        .o_JumpIndex(JumpIndex_ex), .o_Funct(Funct_ex), .o_ShiftAmount(ShiftAmount_ex),
        .o_rs_addr(rs_addr_ex), .o_rt_addr(rt_addr_ex), .o_rd_addr(rd_addr_ex),
        .o_instruction(instruction_ex)
    );


// =================================================================
//  7. Stage 3: EX (Execute)
// =================================================================
    HazardDetectionUnit hazard_detection_unit (
        .i_MemRead_ex(MemRead_ex),
        .i_rt_addr_ex(rt_addr_ex),
        .i_rs_addr_id(instruction_id[25:21]),
        .i_rt_addr_id(instruction_id[20:16]),
        .o_stall_pc_ifid(load_use_stall),
        .o_flush_idex(load_use_flush)
    );

    wire [1:0] forward_a, forward_b;
    ForwardingUnit forwarding_unit (
        .i_rs_addr_ex(rs_addr_ex), .i_rt_addr_ex(rt_addr_ex),
        .i_RegWrite_mem(RegWrite_mem), .i_Write_Addr_mem(Write_Addr_mem),
        .i_RegWrite_wb(RegWrite_wb), .i_Write_Addr_wb(Write_Addr_wb),
        .o_ForwardA(forward_a), .o_ForwardB(forward_b)
    );

    // --- ALU Inputs MUX (Forwarding) ---
    wire [31:0] alu_input_a_ex = (forward_a == 2'b00) ? ReadData1_ex :
                                 (forward_a == 2'b01) ? ALU_Result_mem : write_data_wb;

    wire [31:0] alu_input_b_mux_out = (forward_b == 2'b00) ? ReadData2_ex :
                                      (forward_b == 2'b01) ? ALU_Result_mem : write_data_wb;

    wire [31:0] alu_input_b_ex = (ALUSrc_ex) ? SignExtendedImm_ex : alu_input_b_mux_out;

    // --- ALU ---
    wire [3:0]  alu_control_ex;
    wire [31:0] alu_result_ex;
    wire        zero_flag_ex;

    ALUControl alu_control_unit (
        .ALUOp(ALUOp_ex), .Funct(Funct_ex), .ALUOut(alu_control_ex)
    );

    ALU alu_unit (
        .A(alu_input_a_ex), .B(alu_input_b_ex),
        .ShiftAmount(ShiftAmount_ex), .ALUControl(alu_control_ex), 
        .Result(alu_result_ex), .Zero(zero_flag_ex)
    );

    // --- FPU ---
    FPU_Top fpu_unit (
        .clk(clk), .rst_n(rst),
        .instruction_ex(instruction_ex),
        .cpu_rdata2_ex(ReadData2_ex),
        .ext_we( (instruction_ex[31:26] == 6'h11 && instruction_ex[25:21] == 5'd04) ), // MTC1
        .ext_waddr(instruction_ex[15:11]),
        .ext_wdata(ReadData2_ex),
        .fpu_rdata_ex(fpu_rdata_ex),
        .fpu_wdata_ex(fpu_wdata_ex),
        .fpu_stall_req(stall_fpu),
        .fpu_flag_out(fpu_flag_ex)
    );
    
    wire is_mfc1_ex = (instruction_ex[31:26] == 6'h11) && (instruction_ex[25:21] == 5'd00);
    wire [31:0] final_ex_result = is_mfc1_ex ? fpu_rdata_ex : alu_result_ex;
    
    // --- Branch & Jump Logic ---
    assign branch_target_addr_ex = PC_Plus_4_ex + (SignExtendedImm_ex << 2);
    assign jump_target_addr_ex   = {PC_Plus_4_ex[31:28], JumpIndex_ex, 2'b00};

    wire is_bc1t = (instruction_ex[16] == 1'b1);
    wire is_bc1f = (instruction_ex[16] == 1'b0);
    wire fpu_branch_taken = BranchFP_ex && ( (is_bc1t && fpu_flag_ex) || (is_bc1f && !fpu_flag_ex) );

    wire branch_cond_ex = (BEQ_ex && zero_flag_ex) || (BNE_ex && !zero_flag_ex) || fpu_branch_taken;
    wire is_r_type_ex   = (ALUOp_ex == 2'b10);
    wire is_jr_ex       = is_r_type_ex && ( (Funct_ex == 6'b001000) || (Funct_ex == 6'b001001) );
    
    assign branch_taken_ex = branch_cond_ex || Jump_ex || is_jr_ex;

    // --- Write Address Selection ---
    assign write_addr_ex = (RegDst_ex == 2'b10) ? 5'd31 :       // jal
                           (RegDst_ex == 2'b01) ? rd_addr_ex :  // R-type
                                                  rt_addr_ex;   // lw/addi


// =================================================================
//  8. Pipeline Register: EX -> MEM
// =================================================================
    wire [1:0]  MemToReg_mem;
    wire        MemRead_mem, MemWrite_mem;
    wire [31:0] ALU_Result_mem, ReadData2_mem, PC_Plus_4_mem;
    
    (* mark_debug = "true" *) wire        RegWrite_mem;
    (* mark_debug = "true" *) wire [4:0]  Write_Addr_mem;

    wire is_swc1_ex = (instruction_ex[31:26] == 6'h39);
    wire [31:0] store_data_ex = is_swc1_ex ? fpu_wdata_ex : alu_input_b_mux_out;
    
    PipelineRegister_EX_MEM ex_mem_reg (
        .clk(clk), .rst(rst),
        .i_stall(stall_ex_mem),
        .i_MemToReg(MemToReg_ex), .i_RegWrite(RegWrite_ex),
        .i_MemRead(MemRead_ex), .i_MemWrite(MemWrite_ex),
        .i_ALU_Result(final_ex_result), .i_ReadData2(store_data_ex),
        .i_Write_Addr(write_addr_ex), .i_PC_Plus_4(PC_Plus_4_ex),

        .o_MemToReg(MemToReg_mem), .o_RegWrite(RegWrite_mem),
        .o_MemRead(MemRead_mem), .o_MemWrite(MemWrite_mem),
        .o_ALU_Result(ALU_Result_mem), .o_ReadData2(ReadData2_mem),
        .o_Write_Addr(Write_Addr_mem), .o_PC_Plus_4(PC_Plus_4_mem)
    );


// =================================================================
//  9. Stage 4: MEM (Memory Access & Arbiter)
// =================================================================
    logic [31:0] data_addr, data_wdata;
    logic        data_we, data_re;

    assign data_addr  = ALU_Result_mem;
    assign data_wdata = ReadData2_mem;
    assign data_we    = MemWrite_mem;
    assign data_re    = MemRead_mem;

    logic [31:0] inst_addr;
    logic        inst_re;
    
    assign inst_addr = pc_current;
    assign inst_re   = (pc_current >= 32'h00400000) && rst;

    // --- Arbiter ---
    assign mem_addr  = is_mem_access ? data_addr  : inst_addr;//assign mem_addr = data_addr
    assign mem_wdata = data_wdata;
    
    // ★修正: パルス回路を完全に撤去し、そのまま出力する！
    assign mem_we    = data_we; // mem_we = data_we && (data_addrがテキスト領域外)
    assign mem_re    = is_mem_access ? data_re : inst_re; // ★assign mem_re = data_reとみなす

    wire [31:0] mem_read_data_mem = mem_rdata;

// =================================================================
// 10. Pipeline Register: MEM -> WB
// =================================================================
    wire [1:0]  MemToReg_wb;
    wire [31:0] ALU_Result_wb, Mem_ReadData_wb, PC_Plus_4_wb;
    
    (* mark_debug = "true" *) wire        RegWrite_wb;
    (* mark_debug = "true" *) wire [4:0]  Write_Addr_wb;

    PipelineRegister_MEM_WB mem_wb_reg (
        .clk(clk), .rst(rst),
        .i_stall(stall_mem_wb),
        .i_MemToReg(MemToReg_mem), .i_RegWrite(RegWrite_mem),
        .i_ALU_Result(ALU_Result_mem), .i_Mem_ReadData(mem_read_data_mem),
        .i_Write_Addr(Write_Addr_mem), .i_PC_Plus_4(PC_Plus_4_mem),

        .o_MemToReg(MemToReg_wb), .o_RegWrite(RegWrite_wb),
        .o_ALU_Result(ALU_Result_wb), .o_Mem_ReadData(Mem_ReadData_wb),
        .o_Write_Addr(Write_Addr_wb), .o_PC_Plus_4(PC_Plus_4_wb)
    );


// =================================================================
// 11. Stage 5: WB (Write Back)
// =================================================================
    wire [31:0] write_data_wb;
    assign write_data_wb = (MemToReg_wb == 2'b10) ? PC_Plus_4_wb :    // jal
                           (MemToReg_wb == 2'b01) ? Mem_ReadData_wb : // lw, flw
                                                    ALU_Result_wb;    // R-type, addi


// =================================================================
// 12. Test LED Output (Debug)
// =================================================================
    assign led[15]   = stall_pc;         // PCがストールしているか？
    assign led[14]   = mem_we;           // CPUが書き込みをしているか？
    assign led[13:0] = pc_current[15:2]; // ワードアドレス

endmodule