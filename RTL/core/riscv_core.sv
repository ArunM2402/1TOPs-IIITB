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



module riscv_core #(
    parameter RESET_ADDR = 64'h8000_0000,
    parameter logic [63:0] HARTID = 64'h0
)(
    input  logic        clk,
    input  logic        rst_n,

    // Instruction bus (physical addresses - post-MMU)
    output logic [63:0] imem_addr,
    output logic        imem_req,
    input  logic [31:0] imem_rdata,
    input  logic        imem_ack,
    input  logic        imem_err,

    // Data bus (physical addresses - post-MMU)
    output logic [63:0] dmem_addr,
    output logic [63:0] dmem_wdata,
    output logic [7:0]  dmem_strb,
    output logic        dmem_req,
    output logic        dmem_we,
    input  logic [63:0] dmem_rdata,
    input  logic        dmem_ack,
    input  logic        dmem_err,

    // Page-table walk bus (separate from data bus)
    output logic [63:0] ptw_addr,
    output logic        ptw_req,
    input  logic [63:0] ptw_rdata,
    input  logic        ptw_ack,

    // External interrupt lines
    input  logic        irq_m_external,
    input  logic        irq_m_timer,
    input  logic        irq_m_software,
    input  logic        irq_s_external,

    // Debug
    output logic [63:0] debug_pc
);

`include "riscv_pkg.svh"

// ============================================================
//  PIPELINE REGISTERS
// ============================================================
logic [63:0] if_id_pc, if_id_pc4;
logic [31:0] if_id_instr;
logic        if_id_valid;

logic [63:0] id_ex_pc, id_ex_pc4;
logic [63:0] id_ex_rs1_data, id_ex_rs2_data;
logic [63:0] id_ex_imm;
logic [4:0]  id_ex_rs1, id_ex_rs2, id_ex_rd;
logic [6:0]  id_ex_opcode;
logic [2:0]  id_ex_funct3;
logic [6:0]  id_ex_funct7;
logic        id_ex_valid;
ctrl_signals_t id_ex_ctrl;

logic [63:0] ex_mem_pc, ex_mem_alu_result, ex_mem_rs2_data;
logic [4:0]  ex_mem_rd;
logic        ex_mem_valid;
logic        ex_mem_branch_taken;
logic [63:0] ex_mem_branch_target;
ctrl_signals_t ex_mem_ctrl;

logic [63:0] mem_wb_alu_result, mem_wb_mem_rdata, mem_wb_pc4;
logic [4:0]  mem_wb_rd;
logic        mem_wb_valid;
ctrl_signals_t mem_wb_ctrl;


logic [63:0] pc_reg, pc_next;
logic        pc_stall;
logic        imem_req_va;
logic [63:0] irq_cause;
logic [63:0] branch_target;
logic        branch_taken;

logic        dmem_req_va;

logic        sc_success;
logic        sc_success_lat;  // latched at end of read phase, used in write phase
logic amo_stall;
// ============================================================
//  REGISTER FILE
// ============================================================
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

// ============================================================
//  CSR wires / Trap wires
// ============================================================
logic [11:0]  csr_addr;
logic [63:0]  csr_wdata, csr_rdata;
logic [1:0]   csr_op;
logic         csr_illegal;
logic [1:0]   priv_mode;
logic         mstatus_sum, mstatus_mxr;
logic [63:0]  satp;
logic         trap_valid;
logic [63:0]  trap_cause, trap_pc, trap_tval, trap_vector;
logic         is_mret, is_sret;
logic [63:0]  eret_target;


logic         irq_pending;
ctrl_signals_t id_ctrl;
logic [4:0]   id_rd;
logic [63:0]  id_imm;
logic [2:0]   id_funct3;
logic [6:0]   id_funct7, id_opcode;
logic         id_illegal;

// ============================================================
//  CSR FILE
// ============================================================
csr_file u_csr (
    .clk          (clk),
    .rst_n        (rst_n),
    .hartid       (HARTID),
    .csr_addr     (csr_addr),
    .csr_wdata    (csr_wdata),
    .csr_op       (csr_op),
    .csr_rdata    (csr_rdata),
    .csr_illegal  (csr_illegal),
    .irq_m_ext    (irq_m_external),
    .irq_m_timer  (irq_m_timer),
    .irq_m_sw     (irq_m_software),
    .irq_s_ext    (irq_s_external),
    .irq_pending  (irq_pending),
    .irq_cause    (irq_cause),
    .trap_valid   (trap_valid),
    .trap_cause   (trap_cause),
    .trap_pc      (trap_pc),
    .trap_tval    (trap_tval),
    .trap_vector  (trap_vector),
    .mret         (is_mret),
    .sret         (is_sret),
    .eret_target  (eret_target),
    .priv_mode    (priv_mode),
    .mstatus_sum  (mstatus_sum),
    .mstatus_mxr  (mstatus_mxr),
    .satp         (satp)
);

// ============================================================
//  HAZARD / FORWARD UNIT
// ============================================================
logic        stall_if, stall_id, flush_ex, flush_id, flush_if;
logic [1:0]  fwd_a_sel, fwd_b_sel;
logic        load_use_hazard;
logic        mmu_stall;

hazard_unit u_hazard (
    .id_ex_rd        (id_ex_rd),
    .id_ex_mem_read  (id_ex_ctrl.mem_read),
    .ex_mem_rd       (ex_mem_rd),
    .ex_mem_reg_write(ex_mem_ctrl.reg_write),
    .mem_wb_rd       (mem_wb_rd),
    .mem_wb_reg_write(mem_wb_ctrl.reg_write),
    .id_rs1          (if_id_instr[19:15]),
    .id_rs2          (if_id_instr[24:20]),
    .ex_rs1          (id_ex_rs1),
    .ex_rs2          (id_ex_rs2),
    .branch_taken    (branch_taken),
    .id_ex_valid     (id_ex_valid),
    .ex_mem_valid    (ex_mem_valid),
    .trap_valid      (trap_valid),
    .irq_pending     (irq_pending),
    .eret_valid      (is_mret | is_sret),
    .stall_if        (stall_if),
    .stall_id        (stall_id),
    .flush_if        (flush_if),
    .flush_id        (flush_id),
    .flush_ex        (flush_ex),
    .load_use_hazard (load_use_hazard),
    .fwd_a_sel       (fwd_a_sel),
    .fwd_b_sel       (fwd_b_sel)
);

// ============================================================
//  MMU (Sv39)
// ============================================================
logic [63:0] if_pa;
logic        if_mmu_done, if_page_fault, if_access_fault;
logic        mmu_active;
assign mmu_active = (satp[63:60] == 4'h8) && (priv_mode != PRIV_M);

mmu_sv39 u_immu (
    .clk         (clk),
    .rst_n       (rst_n),
    .va          (pc_reg),
    .req         (imem_req_va & ~if_mmu_done),
    .is_write    (1'b0),
    .is_fetch    (1'b1),
    .priv_mode   (priv_mode),
    .mstatus_sum (mstatus_sum),
    .mstatus_mxr (mstatus_mxr),
    .satp        (satp),
    .tlb_flush   (1'b0),
    .pa          (if_pa),
    .done        (if_mmu_done),
    .page_fault  (if_page_fault),
    .access_fault(if_access_fault),
    .pt_addr     (ptw_addr),
    .pt_req      (ptw_req),
    .pt_rdata    (ptw_rdata),
    .pt_ack      (ptw_ack)
);

logic [63:0] mem_pa;
logic        mem_mmu_done, mem_page_fault, mem_access_fault;
logic [63:0] dmmu_ptw_addr;
logic        dmmu_ptw_req;
logic        tlb_flush;
assign tlb_flush = id_ex_ctrl.sfence_vma & id_ex_valid;

mmu_sv39 u_dmmu (
    .clk         (clk),
    .rst_n       (rst_n),
    .va          (ex_mem_alu_result),
    .req         (dmem_req_va & ~mem_mmu_done),
    .is_write    (ex_mem_ctrl.mem_write),
    .is_fetch    (1'b0),
    .priv_mode   (priv_mode),
    .mstatus_sum (mstatus_sum),
    .mstatus_mxr (mstatus_mxr),
    .satp        (satp),
    .tlb_flush   (tlb_flush),
    .pa          (mem_pa),
    .done        (mem_mmu_done),
    .page_fault  (mem_page_fault),
    .access_fault(mem_access_fault),
    .pt_addr     (dmmu_ptw_addr),
    .pt_req      (dmmu_ptw_req),
    .pt_rdata    (ptw_rdata),
    .pt_ack      (ptw_ack & dmmu_ptw_req)
);

// ============================================================
//  STAGE 1 : INSTRUCTION FETCH
// ============================================================
assign imem_req_va = 1'b1;
assign imem_req    = mmu_active ? if_mmu_done  : 1'b1;
assign imem_addr   = mmu_active ? if_pa        : pc_reg;
assign debug_pc    = pc_reg;
assign pc_stall    = stall_if | amo_stall | (mmu_active & ~if_mmu_done) | (~imem_ack & imem_req & ~flush_if);

always_comb begin
    pc_next = pc_reg + 64'd4;
    if      (trap_valid | irq_pending)       pc_next = trap_vector;
    else if (is_mret | is_sret)              pc_next = eret_target;
    else if (branch_taken & id_ex_valid)     pc_next = branch_target;
    else if (load_use_hazard)                pc_next = pc_reg;
end

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)         pc_reg <= RESET_ADDR;
    else if (!pc_stall) pc_reg <= pc_next;
end

logic if_pf_valid;
assign if_pf_valid = mmu_active & if_page_fault;


always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        if_id_pc    <= '0; if_id_pc4 <= '0;
        if_id_instr <= 32'h0000_0013;
        if_id_valid <= 1'b0;
    end else if (flush_id) begin
        if_id_instr <= 32'h0000_0013;
        if_id_valid <= 1'b0;
    end else if (!stall_id && !amo_stall && imem_ack) begin
        if_id_pc    <= pc_reg;
        if_id_pc4   <= pc_reg + 64'd4;
        if_id_instr <= (imem_err | if_pf_valid) ? 32'hFFFF_FFFF : imem_rdata;
        if_id_valid <= 1'b1;
    end
end

// ============================================================
//  STAGE 2 : INSTRUCTION DECODE
// ============================================================
decode_unit u_decode (
    .instr   (if_id_instr),
    .pc      (if_id_pc),
    .ctrl    (id_ctrl),
    .rs1     (rf_rs1_addr),
    .rs2     (rf_rs2_addr),
    .rd      (id_rd),
    .imm     (id_imm),
    .funct3  (id_funct3),
    .funct7  (id_funct7),
    .opcode  (id_opcode),
    .illegal (id_illegal)
);


always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n || flush_ex) begin
        id_ex_ctrl  <= '0;
        id_ex_rd    <= 5'h0;
        id_ex_valid <= 1'b0;
        id_ex_rs1   <= 5'h0;
        id_ex_rs2   <= 5'h0;
    end else if (!stall_id && !amo_stall) begin
        id_ex_pc       <= if_id_pc;
        id_ex_pc4      <= if_id_pc4;
        id_ex_rs1_data <= rf_rs1_data;
        id_ex_rs2_data <= rf_rs2_data;
        id_ex_imm      <= id_imm;
        id_ex_rs1      <= rf_rs1_addr;
        id_ex_rs2      <= rf_rs2_addr;
        id_ex_rd       <= id_rd;
        id_ex_opcode   <= id_opcode;
        id_ex_funct3   <= id_funct3;
        id_ex_funct7   <= id_funct7;
        id_ex_ctrl     <= id_ctrl;
        id_ex_valid    <= if_id_valid && !id_illegal;
    end
end

// ============================================================
//  STAGE 3 : EXECUTE
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

assign branch_target = id_ex_ctrl.jalr ?
                       (ex_op_a + id_ex_imm) & ~64'h1 :
                       id_ex_pc + id_ex_imm;

branch_unit u_branch (
    .funct3    (id_ex_funct3),
    .is_branch (id_ex_ctrl.branch),
    .is_jal    (id_ex_ctrl.jal),
    .is_jalr   (id_ex_ctrl.jalr),
    .zero      (alu_zero),
    .lt        (alu_lt),
    .ltu       (alu_ltu),
    .taken     (branch_taken)
);

assign csr_addr  = id_ex_imm[11:0];
assign csr_wdata = id_ex_ctrl.csr_imm ? {59'h0, id_ex_rs1} : ex_op_a;
assign csr_op    = id_ex_ctrl.csr_op;
assign is_mret   = id_ex_ctrl.mret & id_ex_valid;
assign is_sret   = id_ex_ctrl.sret & id_ex_valid;

logic csr_illegal_gated;
assign csr_illegal_gated = csr_illegal & id_ex_ctrl.csr_read;

trap_detector u_trap (
    .valid       (id_ex_valid),
    .pc          (id_ex_pc),
    .instr       ({id_ex_funct7, id_ex_rs2, id_ex_rs1, id_ex_funct3, id_ex_rd, id_ex_opcode}),
    .priv_mode   (priv_mode),
    .csr_illegal (csr_illegal_gated),
    .id_illegal  (id_ex_ctrl.illegal),
    .alu_result  (alu_result),
    .is_load     (id_ex_ctrl.mem_read),
    .is_store    (id_ex_ctrl.mem_write),
    .funct3      (id_ex_funct3),
    .is_ecall    (id_ex_ctrl.ecall),
    .is_ebreak   (id_ex_ctrl.ebreak),
    .trap_valid  (trap_valid),
    .trap_cause  (trap_cause),
    .trap_tval   (trap_tval)
);

assign trap_pc = irq_pending ? pc_reg : id_ex_pc;


always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n || trap_valid || irq_pending) begin
        ex_mem_ctrl         <= '0;
        ex_mem_rd           <= 5'h0;
        ex_mem_valid        <= 1'b0;
        ex_mem_branch_taken <= 1'b0;
    end else if (!amo_stall) begin
        ex_mem_pc            <= id_ex_pc;
        ex_mem_alu_result    <= id_ex_ctrl.csr_read  ? csr_rdata :
                                (id_ex_ctrl.jal | id_ex_ctrl.jalr) ? id_ex_pc4 :
                                alu_result;
        ex_mem_rs2_data      <= ex_rs2_fwd;
        ex_mem_rd            <= id_ex_rd;
        ex_mem_ctrl          <= id_ex_ctrl;
        ex_mem_valid         <= id_ex_valid;
        ex_mem_branch_taken  <= (branch_taken | id_ex_ctrl.jal | id_ex_ctrl.jalr) & id_ex_valid;
        ex_mem_branch_target <= branch_target;
    end
end

// ============================================================
//  STAGE 4 : MEMORY ACCESS
// ============================================================
assign dmem_req_va = (ex_mem_ctrl.mem_read | ex_mem_ctrl.mem_write |
                      ex_mem_ctrl.amo) & ex_mem_valid;

logic [63:0] phys_addr;
assign phys_addr = mmu_active ? mem_pa : ex_mem_alu_result;

logic mem_stall;
assign mem_stall = dmem_req_va & mmu_active & ~mem_mmu_done;


logic [1:0]  amo_state;
logic [63:0] amo_rdata_lat;

logic [63:0] amo_rd;
assign amo_rd = (amo_state == 2'b10) ? amo_rdata_lat : dmem_rdata;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        amo_state      <= 2'b00;
        amo_rdata_lat  <= 64'h0;
        sc_success_lat <= 1'b0;
    end else begin
        case (amo_state)
            2'b00: begin  // idle: fire read, then decide
                if (ex_mem_ctrl.amo & ex_mem_valid & dmem_ack)

                    amo_state <= (ex_mem_ctrl.amo_op == 5'b00010) ? 2'b00 : 2'b10;
            end
            2'b10: begin  // write phase
                if (dmem_ack) amo_state <= 2'b00;
            end
            default: amo_state <= 2'b00;
        endcase
       
        if (amo_state == 2'b00 && ex_mem_ctrl.amo && ex_mem_valid && dmem_ack) begin
            amo_rdata_lat  <= dmem_rdata;
            sc_success_lat <= sc_success;  
        end
    end
end


// AMO needs 2 stall cycles:
// Cycle 1 (read phase, state=00): stall so amo_rdata_lat can be latched
// Cycle 2 (write phase, state=10): stall while write executes
// After write done (state back to 00 but previous cycle was state=10): unstall

logic amo_was_writing;
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) amo_was_writing <= 1'b0;
    else        amo_was_writing <= (amo_state == 2'b10);
end
// Stall during read phase (state=00 with active AMO, not just finished write)
// and during write phase (state=10)
// Stall during:
// - Read phase of non-LR AMOs (state=00, not just finished write): wait for rdata to latch
// - Write phase of all AMOs (state=10)
// LR has no write phase, so only stall during its read cycle (amo_was_writing never fires)
// For LR: stall for exactly 1 cycle (the read cycle), then release
// For others: stall during read AND write phases
logic amo_is_lr;
assign amo_is_lr = (ex_mem_ctrl.amo_op == 5'b00010);
assign amo_stall = (ex_mem_ctrl.amo & ex_mem_valid & (amo_state == 2'b00) & ~amo_was_writing & ~amo_is_lr) |
                   (amo_state == 2'b10);

logic        amo_do_write;
logic [63:0] amo_wdata;

logic [63:0] lr_addr;
logic        lr_valid;

assign dmem_addr  = phys_addr;
assign dmem_req   = dmem_req_va & (~mmu_active | mem_mmu_done) & ~mem_page_fault;
assign dmem_we    = (ex_mem_ctrl.mem_write & ~ex_mem_ctrl.amo) |
                    (ex_mem_ctrl.amo & (amo_state == 2'b10));
assign dmem_wdata = ex_mem_ctrl.amo ?
                    amo_wdata :
                    store_data_aligned(ex_mem_rs2_data, ex_mem_ctrl.funct3, phys_addr[2:0]);
assign dmem_strb  = ex_mem_ctrl.amo ?
                    (ex_mem_ctrl.funct3[0] ? 8'hFF : 8'h0F) :
                    mem_strb(ex_mem_ctrl.funct3, phys_addr[2:0]);


always_comb begin
    amo_do_write = 1'b0;
    amo_wdata    = ex_mem_rs2_data;
    sc_success   = 1'b0;

    if (ex_mem_ctrl.amo) begin
        case (ex_mem_ctrl.amo_op)
            5'b00010: amo_do_write = 1'b0;  // LR
            5'b00011: begin  // SC
                if (lr_valid && lr_addr == phys_addr) begin
                    amo_do_write = 1'b1;
                    sc_success   = 1'b1;
                end
            end
            5'b00001: begin amo_do_write=1'b1; amo_wdata=ex_mem_rs2_data;             end // SWAP
            5'b00000: begin amo_do_write=1'b1; amo_wdata=amo_rd+ex_mem_rs2_data;      end // ADD
            5'b00100: begin amo_do_write=1'b1; amo_wdata=amo_rd^ex_mem_rs2_data;      end // XOR
            5'b01100: begin amo_do_write=1'b1; amo_wdata=amo_rd&ex_mem_rs2_data;      end // AND
            5'b01000: begin amo_do_write=1'b1; amo_wdata=amo_rd|ex_mem_rs2_data;      end // OR
            5'b10000: begin amo_do_write=1'b1;
                amo_wdata=($signed(amo_rd)<$signed(ex_mem_rs2_data))?amo_rd:ex_mem_rs2_data; end
            5'b10100: begin amo_do_write=1'b1;
                amo_wdata=($signed(amo_rd)>$signed(ex_mem_rs2_data))?amo_rd:ex_mem_rs2_data; end
            5'b11000: begin amo_do_write=1'b1;
                amo_wdata=(amo_rd<ex_mem_rs2_data)?amo_rd:ex_mem_rs2_data; end
            5'b11100: begin amo_do_write=1'b1;
                amo_wdata=(amo_rd>ex_mem_rs2_data)?amo_rd:ex_mem_rs2_data; end
            default:  amo_do_write = 1'b0;
        endcase
    end
end

// LR/SC reservation register
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        lr_valid <= 1'b0;
        lr_addr  <= 64'h0;
    end else if (ex_mem_ctrl.amo && dmem_ack) begin
        case (ex_mem_ctrl.amo_op)
            5'b00010: begin lr_valid <= 1'b1; lr_addr <= phys_addr; end  // LR
            5'b00011: lr_valid <= 1'b0;                                    // SC clears
            default: if (ex_mem_ctrl.mem_write && phys_addr == lr_addr)
                         lr_valid <= 1'b0;
        endcase
    end else if (ex_mem_ctrl.mem_write && dmem_ack && phys_addr == lr_addr) begin
        lr_valid <= 1'b0;
    end
end


logic mem_wb_stall;


assign mem_wb_stall = (dmem_req & ~dmem_ack & ~ex_mem_ctrl.amo) |
                      mem_stall | amo_stall;

logic [63:0] sc_result;

logic sc_result_val;
assign sc_result_val = (amo_state == 2'b10 || amo_was_writing) ? sc_success_lat : sc_success;
assign sc_result = (ex_mem_ctrl.amo && ex_mem_ctrl.amo_op == 5'b00011) ?
                   (sc_result_val ? 64'h0 : 64'h1) : 64'h0;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        mem_wb_ctrl  <= '0;
        mem_wb_rd    <= 5'h0;
        mem_wb_valid <= 1'b0;
    end else if (!mem_wb_stall) begin

        mem_wb_alu_result <= ex_mem_ctrl.amo ?
                             (ex_mem_ctrl.amo_op == 5'b00011 ? sc_result :
                              ex_mem_ctrl.amo_op == 5'b00010 ? dmem_rdata :  // LR
                              amo_rdata_lat) :
                             ex_mem_alu_result;
        mem_wb_mem_rdata  <= ex_mem_ctrl.amo ?
                             (ex_mem_ctrl.amo_op == 5'b00010 ? dmem_rdata : amo_rdata_lat) :
                             load_extend(dmem_rdata, ex_mem_ctrl.funct3, phys_addr[2:0]);
        mem_wb_pc4        <= ex_mem_pc + 64'd4;
        mem_wb_rd         <= ex_mem_rd;
        mem_wb_ctrl       <= ex_mem_ctrl;
        mem_wb_valid      <= ex_mem_valid;
    end
end

// Store/load helpers
function automatic [63:0] store_data_aligned(
    input [63:0] data, input [2:0] funct3, input [2:0] offset);
    case (funct3[1:0])
        2'b00: store_data_aligned = {8{data[7:0]}};
        2'b01: store_data_aligned = {4{data[15:0]}};
        2'b10: store_data_aligned = {2{data[31:0]}};
        2'b11: store_data_aligned = data;
        default: store_data_aligned = data;
    endcase
endfunction

function automatic [7:0] mem_strb(
    input [2:0] funct3, input [2:0] offset);
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

function automatic [63:0] load_extend(
    input [63:0] data, input [2:0] funct3, input [2:0] offset);
    logic [63:0] shifted;
    shifted = data >> {offset, 3'b000};
    case (funct3)
        3'b000: load_extend = {{56{shifted[7]}},  shifted[7:0]};
        3'b001: load_extend = {{48{shifted[15]}}, shifted[15:0]};
        3'b010: load_extend = {{32{shifted[31]}}, shifted[31:0]};
        3'b011: load_extend = shifted;
        3'b100: load_extend = {56'h0, shifted[7:0]};
        3'b101: load_extend = {48'h0, shifted[15:0]};
        3'b110: load_extend = {32'h0, shifted[31:0]};
        default: load_extend = shifted;
    endcase
endfunction

// ============================================================
//  STAGE 5 : WRITE BACK
// ============================================================
always_comb begin
    wb_en   = mem_wb_valid & mem_wb_ctrl.reg_write;
    wb_rd   = mem_wb_rd;
    
    wb_data = mem_wb_ctrl.amo                      ? mem_wb_alu_result :
              mem_wb_ctrl.mem_read                 ? mem_wb_mem_rdata  :
              (mem_wb_ctrl.jal | mem_wb_ctrl.jalr) ? mem_wb_pc4        :
              mem_wb_alu_result;
end

endmodule

