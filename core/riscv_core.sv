//////////////////////////////////////////////////////////////////////////////////
// Company: IIITB
// Engineer: ihs_system11
// 
// Create Date: 16/05/2026 09:56:42 AM
// Design Name: 
// Module Name: 
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////
// ============================================================
// Top level comments.

// Need to upgrade to include Linux stuff - AM
// Added modules from PULP, need to verify - NS
// Seperate Posit unit tested. Can replace the M extension here. Checking GNU toolchain modifications for later - VS

`timescale 1ns/1ps

//`include "riscv_pkg.svh"

module riscv_core #(
    parameter RESET_ADDR = 64'h8000_0000,
    parameter HARTID     = 0
)(
    input  logic        clk,
    input  logic        rst_n,

    // Imem part - connected to BRAM1 -VS
    output logic [63:0] imem_addr,
    output logic        imem_req,
    input  logic [31:0] imem_rdata,
    input  logic        imem_ack,
    input  logic        imem_err,

    // D-mem connected to BRAM2 - VS
    output logic [63:0] dmem_addr,
    output logic [63:0] dmem_wdata,
    output logic [7:0]  dmem_strb,
    output logic        dmem_req,
    output logic        dmem_we,
    input  logic [63:0] dmem_rdata,
    input  logic        dmem_ack,
    input  logic        dmem_err,

    // External interrupt lines - added from reference - AM
    input  logic        irq_m_external,   // MEIP
    input  logic        irq_m_timer,      // MTIP
    input  logic        irq_m_software,   // MSIP
    input  logic        irq_s_external,   // SEIP

    // Debug interface - printing logiiiiiiiic 
    output logic [63:0] debug_pc
);





// IF/ID
logic [63:0] if_id_pc,  if_id_pc4;
logic [31:0] if_id_instr;
logic        if_id_valid;

// ID/EX
logic [63:0] id_ex_pc, id_ex_pc4;
logic [63:0] id_ex_rs1_data, id_ex_rs2_data;
logic [63:0] id_ex_imm;
logic [4:0]  id_ex_rs1, id_ex_rs2, id_ex_rd;
logic [6:0]  id_ex_opcode;
logic [2:0]  id_ex_funct3;
logic [6:0]  id_ex_funct7;
logic        id_ex_valid;
ctrl_signals_t id_ex_ctrl;

// EX/MEM
logic [63:0] ex_mem_pc, ex_mem_alu_result, ex_mem_rs2_data;
logic [4:0]  ex_mem_rd;
logic        ex_mem_valid;
logic        ex_mem_branch_taken;
logic [63:0] ex_mem_branch_target;
ctrl_signals_t ex_mem_ctrl;

// MEM/WB
logic [63:0] mem_wb_alu_result, mem_wb_mem_rdata, mem_wb_pc4;
logic [4:0]  mem_wb_rd;
logic        mem_wb_valid;
ctrl_signals_t mem_wb_ctrl;


// CSR wires
logic [11:0]  csr_addr;
logic [63:0]  csr_wdata, csr_rdata;
logic [1:0]   csr_op;
logic         csr_illegal;
logic [1:0]   priv_mode;
logic         mstatus_sum, mstatus_mxr;
logic [63:0]  satp;

// Trap wires
logic         trap_valid;
logic [63:0]  trap_cause, trap_pc, trap_tval, trap_vector;
logic         is_mret, is_sret;
logic [63:0]  eret_target;


ctrl_signals_t id_ctrl;
logic [4:0]   id_rd;
logic [63:0]  id_imm;
logic [2:0]   id_funct3;
logic [6:0]   id_funct7, id_opcode;
logic         id_illegal;


//xo to x31 - do we need 64 bit here? - AM
logic [63:0] regfile [31:0];
logic [63:0] rf_rs1_data, rf_rs2_data;
logic [4:0]  rf_rs1_addr, rf_rs2_addr;
logic [4:0]  wb_rd;
logic [63:0] wb_data;
logic        wb_en;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        for (int i = 0; i < 32; i++) regfile[i] <= 64'h0;
    end else if (wb_en && wb_rd != 5'h0) begin
        regfile[wb_rd] <= wb_data;
    end
end

assign rf_rs1_data = (rf_rs1_addr == 5'h0) ? 64'h0 :
                     (wb_en && wb_rd == rf_rs1_addr) ? wb_data : regfile[rf_rs1_addr];
assign rf_rs2_data = (rf_rs2_addr == 5'h0) ? 64'h0 :
                     (wb_en && wb_rd == rf_rs2_addr) ? wb_data : regfile[rf_rs2_addr];


csr_file u_csr (
    .clk          (clk),
    .rst_n        (rst_n),
    .hartid       (HARTID[63:0]),
    .csr_addr     (csr_addr),
    .csr_wdata    (csr_wdata),
    .csr_op       (csr_op),
    .csr_rdata    (csr_rdata),
    .csr_illegal  (csr_illegal),
    .irq_m_ext    (irq_m_external),
    .irq_m_timer  (irq_m_timer),
    .irq_m_sw     (irq_m_software),
    .irq_s_ext    (irq_s_external),
    .trap_valid   (trap_valid),
    .trap_cause   (trap_cause),
    .trap_pc      (trap_pc),
    .trap_tval    (trap_tval),
    .trap_vector  (trap_vector),
    .mret         (is_mret),
    .sret         (is_sret),
    .eret_target  (eret_target),
    // status - need to be checked
    .priv_mode    (priv_mode),
    .mstatus_sum  (mstatus_sum),
    .mstatus_mxr  (mstatus_mxr),
    .satp         (satp)
);



logic        stall_if, stall_id, flush_ex, flush_id;
logic [1:0]  fwd_a_sel, fwd_b_sel;
logic        load_use_hazard;

hazard_unit u_hazard (
    .id_ex_rd        (id_ex_rd),
    .id_ex_mem_read  (id_ex_ctrl.mem_read),
    .ex_mem_rd       (ex_mem_rd),
    .ex_mem_reg_write(ex_mem_ctrl.reg_write),
    .mem_wb_rd       (mem_wb_rd),
    .mem_wb_reg_write(mem_wb_ctrl.reg_write),
    .id_rs1          (if_id_instr[19:15]),  // ID stage - load-use detection
    .id_rs2          (if_id_instr[24:20]),  // ID stage - load-use detection
    .ex_rs1          (id_ex_rs1),           // EX stage - forwarding
    .ex_rs2          (id_ex_rs2),           // EX stage - forwarding
    .branch_taken    (ex_mem_branch_taken),
    .ex_mem_valid    (ex_mem_valid),
    .trap_valid      (trap_valid),
    .eret_valid      (is_mret | is_sret),
    .stall_if        (stall_if),
    .stall_id        (stall_id),
    .flush_id        (flush_id),
    .flush_ex        (flush_ex),
    .load_use_hazard (load_use_hazard),
    .fwd_a_sel       (fwd_a_sel),
    .fwd_b_sel       (fwd_b_sel)
);

// ============================================================
//  fetch stage
// ============================================================
logic [63:0] pc_reg, pc_next;
logic        pc_stall;

assign pc_stall   = stall_if | ~imem_ack;
assign imem_req   = 1'b1;
assign imem_addr  = pc_reg;
assign debug_pc   = pc_reg;

// PC mux
always_comb begin
    pc_next = pc_reg + 64'd4;
    if (trap_valid)            pc_next = trap_vector;
    else if (is_mret | is_sret) pc_next = eret_target;
    else if (ex_mem_branch_taken) pc_next = ex_mem_branch_target;
    else if (load_use_hazard)  pc_next = pc_reg;        // stall
end

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)         pc_reg <= RESET_ADDR;
    else if (!pc_stall) pc_reg <= pc_next;
end

//// ---- SIMULATION PROBE (remove before synthesis) ----
//`ifndef SYNTHESIS
//always_ff @(posedge clk) begin
//    if (rst_n) begin
//        $display("T=%0t PC=%h pc_next=%h trap=%b is_mret=%b branch_tk=%b flush_id=%b if_id_v=%b id_ex_v=%b wb_en=%b wb_rd=x%0d",
//            $time, pc_reg, pc_next,
//            trap_valid, is_mret,
//            ex_mem_branch_taken,
//            flush_id,
//            if_id_valid, id_ex_valid,
//            wb_en, wb_rd);
//    end
//end
//`endif
//// ---- END PROBE ----

// IF/ID pipeline register
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        if_id_pc    <= '0; if_id_pc4  <= '0;
        if_id_instr <= 32'h0000_0013;  // NOP
        if_id_valid <= 1'b0;
    end else if (flush_id || trap_valid || is_mret || is_sret) begin
        if_id_instr <= 32'h0000_0013;
        if_id_valid <= 1'b0;
    end else if (!stall_id && imem_ack) begin
        if_id_pc    <= pc_reg;
        if_id_pc4   <= pc_reg + 64'd4;
        if_id_instr <= imem_err ? 32'hFFFF_FFFF : imem_rdata;
        if_id_valid <= 1'b1;
    end
end

// ============================================================
//  decode stage
// ============================================================
decode_unit u_decode (
    .instr      (if_id_instr),
    .pc         (if_id_pc),
    .ctrl       (id_ctrl),
    .rs1        (rf_rs1_addr),
    .rs2        (rf_rs2_addr),
    .rd         (id_rd),
    .imm        (id_imm),
    .funct3     (id_funct3),
    .funct7     (id_funct7),
    .opcode     (id_opcode),
    .illegal    (id_illegal)
);



always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n || load_use_hazard || trap_valid) begin
        id_ex_ctrl       <= '0;
        id_ex_rd         <= 5'h0;
        id_ex_valid      <= 1'b0;
        id_ex_rs1        <= 5'h0;
        id_ex_rs2        <= 5'h0;
    end else if (!stall_id) begin
        id_ex_pc         <= if_id_pc;
        id_ex_pc4        <= if_id_pc4;
        id_ex_rs1_data   <= rf_rs1_data;
        id_ex_rs2_data   <= rf_rs2_data;
        id_ex_imm        <= id_imm;
        id_ex_rs1        <= rf_rs1_addr;
        id_ex_rs2        <= rf_rs2_addr;
        id_ex_rd         <= id_rd;
        id_ex_opcode     <= id_opcode;
        id_ex_funct3     <= id_funct3;
        id_ex_funct7     <= id_funct7;
        id_ex_ctrl       <= id_ctrl;
        id_ex_valid      <= if_id_valid && !id_illegal;
    end
end

// ============================================================
//  exu stage
// ============================================================


logic [63:0] ex_op_a, ex_op_b, ex_rs2_fwd;
logic [63:0] ex_mem_fwd_data;

assign ex_mem_fwd_data = ex_mem_ctrl.mem_read ? mem_wb_alu_result : ex_mem_alu_result;

always_comb begin
    case (fwd_a_sel)
        2'b00: ex_op_a = id_ex_rs1_data;
        2'b01: ex_op_a = wb_data;
        2'b10: ex_op_a = ex_mem_fwd_data;
        default: ex_op_a = id_ex_rs1_data;
    endcase

    case (fwd_b_sel)
        2'b00: ex_rs2_fwd = id_ex_rs2_data;
        2'b01: ex_rs2_fwd = wb_data;
        2'b10: ex_rs2_fwd = ex_mem_fwd_data;
        default: ex_rs2_fwd = id_ex_rs2_data;
    endcase

    ex_op_b = id_ex_ctrl.alu_src ? id_ex_imm : ex_rs2_fwd;
end

// ALU - Add posit here - VS
logic [63:0] alu_result;
logic        alu_zero, alu_lt, alu_ltu;

alu_unit u_alu (
    .op_a    (id_ex_ctrl.auipc ? id_ex_pc : ex_op_a),
    .op_b    (ex_op_b),
    .alu_op  (id_ex_ctrl.alu_op),
    .word_op (id_ex_ctrl.word_op),
    .result  (alu_result),
    .zero    (alu_zero),
    .lt      (alu_lt),
    .ltu     (alu_ltu)
);

// Branch/jump target - tests failed, check again
logic [63:0] branch_target;
logic        branch_taken;

assign branch_target = id_ex_ctrl.jalr ?
                       (ex_op_a + id_ex_imm) & ~64'h1 :
                       id_ex_pc + id_ex_imm;

branch_unit u_branch (
    .funct3      (id_ex_funct3),
    .is_branch   (id_ex_ctrl.branch),
    .is_jal      (id_ex_ctrl.jal),
    .is_jalr     (id_ex_ctrl.jalr),
    .zero        (alu_zero),
    .lt          (alu_lt),
    .ltu         (alu_ltu),
    .taken       (branch_taken)
);


assign csr_addr  = id_ex_imm[11:0];
assign csr_wdata = (id_ex_ctrl.csr_imm) ? {59'h0, id_ex_rs1} : ex_op_a;
assign csr_op    = id_ex_ctrl.csr_op;
assign is_mret   = id_ex_ctrl.mret & id_ex_valid;
assign is_sret   = id_ex_ctrl.sret & id_ex_valid;


logic ex_trap;
logic [63:0] ex_trap_cause, ex_trap_tval;


logic csr_illegal_gated;
assign csr_illegal_gated = csr_illegal & id_ex_ctrl.csr_read;

exp_handler u_trap (
    .valid        (id_ex_valid),
    .pc           (id_ex_pc),
    .instr        ({id_ex_funct7, id_ex_rs2, id_ex_rs1, id_ex_funct3, id_ex_rd, id_ex_opcode}),
    .priv_mode    (priv_mode),
    .csr_illegal  (csr_illegal_gated),
    .id_illegal   (id_ex_ctrl.illegal),
    .alu_result   (alu_result),
    .is_load      (id_ex_ctrl.mem_read),
    .is_store     (id_ex_ctrl.mem_write),
    .funct3       (id_ex_funct3),
    .is_ecall     (id_ex_ctrl.ecall),
    .is_ebreak    (id_ex_ctrl.ebreak),
    .trap_valid   (trap_valid),
    .trap_cause   (trap_cause),
    .trap_tval    (trap_tval)
);

assign trap_pc = id_ex_pc;

// EX/MEM pipeline register
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n || trap_valid) begin
        ex_mem_ctrl         <= '0;
        ex_mem_rd           <= 5'h0;
        ex_mem_valid        <= 1'b0;
        ex_mem_branch_taken <= 1'b0;
    end else begin
        ex_mem_pc           <= id_ex_pc;
        ex_mem_alu_result   <= id_ex_ctrl.csr_read ? csr_rdata :
                               (id_ex_ctrl.jal | id_ex_ctrl.jalr) ? id_ex_pc4 :
                               alu_result;
        ex_mem_rs2_data     <= ex_rs2_fwd;
        ex_mem_rd           <= id_ex_rd;
        ex_mem_ctrl         <= id_ex_ctrl;
        ex_mem_valid        <= id_ex_valid;
        ex_mem_branch_taken <= (branch_taken | id_ex_ctrl.jal | id_ex_ctrl.jalr) & id_ex_valid;
        ex_mem_branch_target<= branch_target;
    end
end

// ============================================================
// memory stage
// ============================================================
assign dmem_addr  = ex_mem_alu_result;
assign dmem_wdata = store_data_aligned(ex_mem_rs2_data, ex_mem_ctrl.funct3, ex_mem_alu_result[2:0]);
assign dmem_strb  = mem_strb(ex_mem_ctrl.funct3, ex_mem_alu_result[2:0]);
assign dmem_req   = (ex_mem_ctrl.mem_read | ex_mem_ctrl.mem_write) & ex_mem_valid;
assign dmem_we    = ex_mem_ctrl.mem_write;


function automatic [63:0] store_data_aligned(
    input [63:0] data,
    input [2:0]  funct3,
    input [2:0]  offset
);
    case (funct3[1:0])
        2'b00: store_data_aligned = {8{data[7:0]}};
        2'b01: store_data_aligned = {4{data[15:0]}};
        2'b10: store_data_aligned = {2{data[31:0]}};
        2'b11: store_data_aligned = data;
        default: store_data_aligned = data;
    endcase
endfunction

function automatic [7:0] mem_strb(
    input [2:0] funct3,
    input [2:0] offset
);
    logic [7:0] base;
    case (funct3[1:0])
        2'b00: base = 8'b0000_0001;
        2'b01: base = 8'b0000_0011;
        2'b10: base = 8'b0000_1111;
        2'b11: base = 8'b1111_1111;
        default: base = 8'b0000_0000;
    endcase
    mem_strb = base << offset;
endfunction

// MEM/WB pipeline register
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        mem_wb_ctrl    <= '0;
        mem_wb_rd      <= 5'h0;
        mem_wb_valid   <= 1'b0;
    end else if (!dmem_req || dmem_ack) begin
        mem_wb_alu_result <= ex_mem_alu_result;
        mem_wb_mem_rdata  <= load_extend(dmem_rdata, ex_mem_ctrl.funct3, ex_mem_alu_result[2:0]);
        mem_wb_pc4        <= ex_mem_pc + 64'd4;
        mem_wb_rd         <= ex_mem_rd;
        mem_wb_ctrl       <= ex_mem_ctrl;
        mem_wb_valid      <= ex_mem_valid;
    end
end

// Load data sign/zero extension
function automatic [63:0] load_extend(
    input [63:0] data,
    input [2:0]  funct3,
    input [2:0]  offset
);
    logic [63:0] shifted;
    shifted = data >> {offset, 3'b000};
    case (funct3)
        3'b000: load_extend = {{56{shifted[7]}},  shifted[7:0]};   // LB
        3'b001: load_extend = {{48{shifted[15]}}, shifted[15:0]};  // LH
        3'b010: load_extend = {{32{shifted[31]}}, shifted[31:0]};  // LW
        3'b011: load_extend = shifted;                              // LD
        3'b100: load_extend = {56'h0, shifted[7:0]};               // LBU
        3'b101: load_extend = {48'h0, shifted[15:0]};              // LHU
        3'b110: load_extend = {32'h0, shifted[31:0]};              // LWU
        default: load_extend = shifted; // catch-all
    endcase
endfunction

// ============================================================
//  wb stage
// ============================================================
always_comb begin
    wb_en   = mem_wb_valid & mem_wb_ctrl.reg_write;
    wb_rd   = mem_wb_rd;
    wb_data = mem_wb_ctrl.mem_read  ? mem_wb_mem_rdata :
              mem_wb_ctrl.jal       ? mem_wb_pc4 :
              mem_wb_ctrl.jalr      ? mem_wb_pc4 :
              mem_wb_alu_result;
end

endmodule

