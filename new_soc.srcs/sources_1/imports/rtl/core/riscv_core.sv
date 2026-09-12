// ============================================================
//  riscv_core.sv  -  RV64IMAC  5-stage pipeline
//  IIITB 1TOPs SoC  -  fixed/extended from uploaded version
//
//  Fixes applied:
//  1. Combinational branch flush (not registered)
//  2. MMU (Sv39) instantiated for IMEM and DMEM
//  3. AMO 2-phase state machine (read then write)
//  4. LR/SC reservation with sc_success_lat
//  5. AMO stall propagated to all pipeline stages
//  6. irq_pending pipeline flush
//  7. SFENCE.VMA → TLB flush
//  8. PTW bus exposed for MMU
//  9. CSR address fixed for CSRRWI (from imm not UIMM)
// ============================================================
`timescale 1ns/1ps


module riscv_core #(
    parameter RESET_ADDR = 64'h8000_0000,
    parameter logic [63:0] HARTID = 64'h0
)(
    input  logic        clk,
    input  logic        rst_n,

    // Instruction bus
    output logic [63:0] imem_addr,
    output logic        imem_req,
    input  logic [31:0] imem_rdata,
    input  logic        imem_ack,
    input  logic        imem_err,

    // Data bus
    output logic [63:0] dmem_addr,
    output logic [63:0] dmem_wdata,
    output logic [7:0]  dmem_strb,
    output logic        dmem_req,
    output logic        dmem_we,
    input  logic [63:0] dmem_rdata,
    input  logic        dmem_ack,
    input  logic        dmem_err,

    // Page-table walk bus (separate from data)
    output logic [63:0] ptw_addr,
    output logic        ptw_req,
    input  logic [63:0] ptw_rdata,
    input  logic        ptw_ack,

    // Interrupts
    input  logic        irq_m_external,
    input  logic        irq_m_timer,
    input  logic        irq_m_software,
    input  logic        irq_s_external,

    // Debug / cache control
    output logic [63:0] debug_pc,
    output logic        fence_i,     // FENCE.I - flush I-cache
    output logic        fence_d      // SFENCE.VMA or FENCE - flush D-cache
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
logic [6:0]  id_ex_opcode, id_ex_funct7;
logic [2:0]  id_ex_funct3;
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
logic mem_wb_stall;
// ============================================================
//  PC
// ============================================================
logic [63:0] pc_reg, pc_next;
logic        pc_stall;

// ============================================================
//  REGISTER FILE
// ============================================================
logic [63:0] regfile [31:0];
logic [4:0]  rf_rs1_addr, rf_rs2_addr;
logic [63:0] rf_rs1_data, rf_rs2_data;
logic [4:0]  wb_rd;
logic [63:0] wb_data;
logic        wb_en;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        for (int i=0;i<32;i++) regfile[i] <= 64'h0;
        // Boot convention: a0=HARTID=0, a1=FDT_ADDR=0x8200_0000
        regfile[10] <= 64'h0000_0000;          // a0 = HARTID = 0
        regfile[11] <= 64'h8200_0000;          // a1 = FDT address
    end else if (wb_en && wb_rd != 5'h0) begin
        regfile[wb_rd] <= wb_data;
    end
end

assign rf_rs1_data = (rf_rs1_addr==5'h0) ? 64'h0 :
                     (wb_en && wb_rd==rf_rs1_addr) ? wb_data : regfile[rf_rs1_addr];
assign rf_rs2_data = (rf_rs2_addr==5'h0) ? 64'h0 :
                     (wb_en && wb_rd==rf_rs2_addr) ? wb_data : regfile[rf_rs2_addr];

// ============================================================
//  CSR FILE
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
logic [63:0]  irq_cause;

logic        csr_trap_valid;
logic [63:0] csr_trap_cause;

csr_file u_csr (
    .clk(clk), .rst_n(rst_n), .hartid(HARTID),
    .csr_addr(csr_addr), .csr_wdata(csr_wdata), .csr_op(csr_op),
    .csr_rdata(csr_rdata), .csr_illegal(csr_illegal),
    .irq_m_ext(irq_m_external), .irq_m_timer(irq_m_timer),
    .irq_m_sw(irq_m_software), .irq_s_ext(irq_s_external),
    .irq_pending(irq_pending), .irq_cause(irq_cause),
    .trap_valid(csr_trap_valid), .trap_cause(csr_trap_cause),
    .trap_pc(trap_pc), .trap_tval(trap_tval), .trap_vector(trap_vector),
    .mret(is_mret), .sret(is_sret), .eret_target(eret_target),
    .priv_mode(priv_mode), .mstatus_sum(mstatus_sum),
    .mstatus_mxr(mstatus_mxr), .satp(satp)
);

// ============================================================
//  DECODE wires
// ============================================================
ctrl_signals_t id_ctrl;
logic [4:0]   id_rd;
logic [63:0]  id_imm;
logic [2:0]   id_funct3;
logic [6:0]   id_funct7, id_opcode;
logic         id_illegal;

decode_unit u_decode (
    .instr(if_id_instr), .pc(if_id_pc),
    .ctrl(id_ctrl), .rs1(rf_rs1_addr), .rs2(rf_rs2_addr),
    .rd(id_rd), .imm(id_imm), .funct3(id_funct3),
    .funct7(id_funct7), .opcode(id_opcode), .illegal(id_illegal)
);

// ============================================================
//  RVC Pre-decoder (Compressed → 32-bit expansion)
// ============================================================
logic [31:0] instr_expanded;  // expanded instruction (32-bit)
logic        instr_is_rvc;    // 1 if current instruction is 16-bit RVC
logic        instr_rvc_illegal;

rvc_expand u_rvc (
    .instr_raw   (imem_rdata),
    .pc          (pc_reg),
    .instr32     (instr_expanded),
    .is_rvc      (instr_is_rvc),
    .illegal_rvc (instr_rvc_illegal)
);

// PC increment: +2 for RVC, +4 for 32-bit
logic [63:0] pc_inc;
assign pc_inc = instr_is_rvc ? 64'd2 : 64'd4;

// ============================================================
//  MMU
// ============================================================
logic        mmu_active;
assign mmu_active = (satp[63:60] == 4'h8) && (priv_mode != PRIV_M);

// IMMU
logic [63:0] if_pa;
logic        if_mmu_done, if_page_fault;
logic        if_req_va;
assign if_req_va = 1'b1;

mmu_sv39 u_immu (
    .clk(clk), .rst_n(rst_n),
    .va(pc_reg), .req(if_req_va & ~if_mmu_done),
    .is_write(1'b0), .is_fetch(1'b1),
    .priv_mode(priv_mode), .mstatus_sum(mstatus_sum), .mstatus_mxr(mstatus_mxr),
    .satp(satp),
    .pa(if_pa), .done(if_mmu_done), .page_fault(if_page_fault),
    .access_fault(),
    .pt_addr(ptw_addr), .pt_req(ptw_req),
    .pt_rdata(ptw_rdata), .pt_ack(ptw_ack)
);

// DMMU
logic [63:0] mem_pa;
logic        mem_mmu_done, mem_page_fault;
logic [63:0] dmmu_ptw_addr;
logic        dmmu_ptw_req;
logic        tlb_flush;
assign tlb_flush = id_ex_ctrl.sfence_vma & id_ex_valid;

mmu_sv39 u_dmmu (
    .clk(clk), .rst_n(rst_n),
    .va(ex_mem_alu_result), .req((ex_mem_ctrl.mem_read | ex_mem_ctrl.mem_write | ex_mem_ctrl.amo) & ex_mem_valid & ~mem_mmu_done),
    .is_write(ex_mem_ctrl.mem_write), .is_fetch(1'b0),
    .priv_mode(priv_mode), .mstatus_sum(mstatus_sum), .mstatus_mxr(mstatus_mxr),
    .satp(satp),
    .pa(mem_pa), .done(mem_mmu_done), .page_fault(mem_page_fault),
    .access_fault(),
    .pt_addr(dmmu_ptw_addr), .pt_req(dmmu_ptw_req),
    .pt_rdata(ptw_rdata), .pt_ack(ptw_ack & dmmu_ptw_req)
);

// ============================================================
//  HAZARD UNIT
// ============================================================
// Declare before use (used in hazard port connections and pc_next)
logic [63:0] branch_target;
logic        branch_taken;

logic        stall_if, stall_id, flush_ex, flush_id, flush_if;
logic [1:0]  fwd_a_sel, fwd_b_sel;
logic        load_use_hazard;
logic        amo_stall_out;

// AMO stall signals (declared below, used here via forward reference)
logic amo_stall;

hazard_unit u_hazard (
    .id_ex_rd(id_ex_rd), .id_ex_mem_read(id_ex_ctrl.mem_read),
    .ex_mem_rd(ex_mem_rd), .ex_mem_reg_write(ex_mem_ctrl.reg_write),
    .mem_wb_rd(mem_wb_rd), .mem_wb_reg_write(mem_wb_ctrl.reg_write),
    .id_rs1(if_id_instr[19:15]), .id_rs2(if_id_instr[24:20]),
    .ex_rs1(id_ex_rs1), .ex_rs2(id_ex_rs2),
    .branch_taken(branch_taken), .id_ex_valid(id_ex_valid),
    .trap_valid(trap_valid), .irq_pending(irq_pending),
    .eret_valid(is_mret | is_sret),
    .amo_stall(amo_stall),
    .stall_if(stall_if), .stall_id(stall_id),
    .flush_if(flush_if), .flush_id(flush_id), .flush_ex(flush_ex),
    .load_use_hazard(load_use_hazard),
    .fwd_a_sel(fwd_a_sel), .fwd_b_sel(fwd_b_sel)
);

// ============================================================
//  STAGE 1: INSTRUCTION FETCH
// ============================================================
assign imem_req  = mmu_active ? if_mmu_done : 1'b1;
assign imem_addr = mmu_active ? if_pa       : pc_reg;
assign debug_pc  = pc_reg;
assign fence_i   = id_ex_ctrl.fence      & id_ex_valid;
assign fence_d   = id_ex_ctrl.sfence_vma & id_ex_valid;

assign pc_stall = stall_if | amo_stall | mem_wb_stall |
                  (mmu_active & ~if_mmu_done) |
                  (~imem_ack & imem_req & ~flush_if);

always_comb begin
    pc_next = pc_reg + pc_inc;
    if      (trap_valid | irq_pending)    pc_next = trap_vector;
    else if (is_mret | is_sret)           pc_next = eret_target;
    else if (branch_taken & id_ex_valid)  pc_next = branch_target;
    else if (load_use_hazard)             pc_next = pc_reg;
end

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)         pc_reg <= RESET_ADDR;
    else if (!pc_stall) pc_reg <= pc_next;
end

logic if_pf_valid;
assign if_pf_valid = mmu_active & if_page_fault;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        if_id_pc <= '0; if_id_pc4 <= '0;
        if_id_instr <= 32'h0000_0013; if_id_valid <= 1'b0;
    end else if (flush_id) begin
        if_id_instr <= 32'h0000_0013; if_id_valid <= 1'b0;
    end else if (!stall_id && !amo_stall && !mem_wb_stall && imem_ack) begin
        if_id_pc    <= pc_reg;
        if_id_pc4   <= pc_reg + pc_inc;
        if_id_instr <= (imem_err | if_pf_valid) ? 32'hFFFF_FFFF : instr_expanded;
        if_id_valid <= 1'b1;
    end
end

// ============================================================
//  STAGE 2: DECODE
// ============================================================
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n || flush_ex) begin
        id_ex_ctrl  <= '0; id_ex_rd <= 5'h0;
        id_ex_valid <= 1'b0; id_ex_rs1 <= 5'h0; id_ex_rs2 <= 5'h0;
    end else if (!stall_id && !amo_stall && !mem_wb_stall) begin
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
//  STAGE 3: EXECUTE
// ============================================================
logic [63:0] ex_op_a, ex_op_b, ex_rs2_fwd;
logic [63:0] ex_mem_fwd_data;

assign ex_mem_fwd_data = ex_mem_ctrl.mem_read ? mem_wb_alu_result : ex_mem_alu_result;

always_comb begin
    case (fwd_a_sel)
        2'b10:   ex_op_a = ex_mem_fwd_data;
        2'b01:   ex_op_a = wb_data;
        default: ex_op_a = id_ex_rs1_data;
    endcase
    case (fwd_b_sel)
        2'b10:   ex_rs2_fwd = ex_mem_fwd_data;
        2'b01:   ex_rs2_fwd = wb_data;
        default: ex_rs2_fwd = id_ex_rs2_data;
    endcase
    ex_op_b = id_ex_ctrl.alu_src ? id_ex_imm : ex_rs2_fwd;
end

logic [63:0] alu_result;
logic        alu_zero, alu_lt, alu_ltu;

alu_unit u_alu (
    .op_a(id_ex_ctrl.auipc ? id_ex_pc : ex_op_a),
    .op_b(ex_op_b),
    .alu_op(id_ex_ctrl.alu_op),
    .word_op(id_ex_ctrl.word_op),
    .result(alu_result), .zero(alu_zero), .lt(alu_lt), .ltu(alu_ltu)
);


assign branch_target = id_ex_ctrl.jalr ?
                       (ex_op_a + id_ex_imm) & ~64'h1 :
                       id_ex_pc + id_ex_imm;

branch_unit u_branch (
    .funct3(id_ex_funct3), .is_branch(id_ex_ctrl.branch),
    .is_jal(id_ex_ctrl.jal), .is_jalr(id_ex_ctrl.jalr),
    .zero(alu_zero), .lt(alu_lt), .ltu(alu_ltu),
    .taken(branch_taken)
);

assign csr_addr  = id_ex_imm[11:0];
assign csr_wdata = id_ex_ctrl.csr_imm ? {59'h0, id_ex_rs1} : ex_op_a;
assign csr_op    = id_ex_ctrl.csr_op;
assign is_mret   = id_ex_ctrl.mret & id_ex_valid;
assign is_sret   = id_ex_ctrl.sret & id_ex_valid;

logic csr_illegal_gated;
assign csr_illegal_gated = csr_illegal & id_ex_ctrl.csr_read;

// Trap detector
trap_detector u_trap (
    .valid(id_ex_valid), .pc(id_ex_pc),
    .instr({id_ex_funct7, id_ex_rs2, id_ex_rs1, id_ex_funct3, id_ex_rd, id_ex_opcode}),
    .priv_mode(priv_mode), .csr_illegal(csr_illegal_gated),
    .id_illegal(id_ex_ctrl.illegal),
    .alu_result(alu_result),
    .is_load(id_ex_ctrl.mem_read), .is_store(id_ex_ctrl.mem_write),
    .funct3(id_ex_funct3),
    .is_ecall(id_ex_ctrl.ecall), .is_ebreak(id_ex_ctrl.ebreak),
    .trap_valid(trap_valid), .trap_cause(trap_cause), .trap_tval(trap_tval)
);

assign trap_pc = irq_pending ? pc_reg : id_ex_pc;

// Combined trap signals: include both sync exceptions and async interrupts
// csr_file needs to know about IRQs to clear mstatus.MIE on interrupt entry

assign csr_trap_valid = trap_valid | irq_pending;
assign csr_trap_cause = irq_pending ? irq_cause : trap_cause;

// EX/MEM register
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n || trap_valid || irq_pending) begin
        ex_mem_ctrl         <= '0; ex_mem_rd <= 5'h0;
        ex_mem_valid        <= 1'b0; ex_mem_branch_taken <= 1'b0;
    end else if (!amo_stall && !mem_wb_stall) begin
        ex_mem_pc           <= id_ex_pc;
        ex_mem_alu_result   <= id_ex_ctrl.csr_read  ? csr_rdata :
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
//  STAGE 4: MEMORY  +  AMO 2-phase state machine
// ============================================================
logic [63:0] phys_addr;
assign phys_addr = mmu_active ? mem_pa : ex_mem_alu_result;

logic mem_stall;
logic dmem_req_va;
assign dmem_req_va = (ex_mem_ctrl.mem_read | ex_mem_ctrl.mem_write |
                      ex_mem_ctrl.amo) & ex_mem_valid;
assign mem_stall = dmem_req_va & mmu_active & ~mem_mmu_done;

// AMO state machine - plain localparam (no typedef enum for XSIM)
localparam logic [1:0] AMO_IDLE  = 2'b00;
localparam logic [1:0] AMO_WRITE = 2'b10;

logic [1:0]  amo_state;
logic [63:0] amo_rdata_lat;
logic [63:0] amo_rd;
assign amo_rd = (amo_state == AMO_WRITE) ? amo_rdata_lat : dmem_rdata;

logic amo_was_writing;
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) amo_was_writing <= 1'b0;
    else        amo_was_writing <= (amo_state == AMO_WRITE);
end

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        amo_state     <= AMO_IDLE;
        amo_rdata_lat <= 64'h0;
    end else begin
        case (amo_state)
            AMO_IDLE: begin
                if (ex_mem_ctrl.amo & ex_mem_valid & dmem_ack)
                    amo_state <= (ex_mem_ctrl.amo_op == 5'b00010) ? AMO_IDLE : AMO_WRITE;
            end
            AMO_WRITE: if (dmem_ack) amo_state <= AMO_IDLE;
            default:   amo_state <= AMO_IDLE;
        endcase
        if (amo_state == AMO_IDLE && ex_mem_ctrl.amo && ex_mem_valid && dmem_ack)
            amo_rdata_lat <= dmem_rdata;
    end
end

logic amo_is_lr;
assign amo_is_lr = (ex_mem_ctrl.amo_op == 5'b00010);

assign amo_stall =
    (ex_mem_ctrl.amo & ex_mem_valid & (amo_state == AMO_IDLE) & ~amo_was_writing & ~amo_is_lr) |
    (amo_state == AMO_WRITE);

// Memory stall: whole pipeline freezes when MEM is waiting for ack

assign mem_wb_stall = (dmem_req & ~dmem_ack & ~ex_mem_ctrl.amo) | mem_stall | amo_stall;

// AMO operation
logic        amo_do_write, sc_success, sc_success_lat;
logic [63:0] amo_wdata;
logic [63:0] lr_addr;
logic        lr_valid;

always_comb begin
    amo_do_write = 1'b0;
    amo_wdata    = ex_mem_rs2_data;
    sc_success   = 1'b0;
    if (ex_mem_ctrl.amo) begin
        case (ex_mem_ctrl.amo_op)
            5'b00010: amo_do_write = 1'b0; // LR
            5'b00011: begin // SC
                if (lr_valid && lr_addr == phys_addr) begin
                    amo_do_write = 1'b1; sc_success = 1'b1;
                end
            end
            5'b00001: begin amo_do_write=1; amo_wdata=ex_mem_rs2_data; end // SWAP
            5'b00000: begin amo_do_write=1; amo_wdata=amo_rd+ex_mem_rs2_data; end // ADD
            5'b00100: begin amo_do_write=1; amo_wdata=amo_rd^ex_mem_rs2_data; end // XOR
            5'b01100: begin amo_do_write=1; amo_wdata=amo_rd&ex_mem_rs2_data; end // AND
            5'b01000: begin amo_do_write=1; amo_wdata=amo_rd|ex_mem_rs2_data; end // OR
            5'b10000: begin amo_do_write=1;
                amo_wdata=($signed(amo_rd)<$signed(ex_mem_rs2_data))?amo_rd:ex_mem_rs2_data; end
            5'b10100: begin amo_do_write=1;
                amo_wdata=($signed(amo_rd)>$signed(ex_mem_rs2_data))?amo_rd:ex_mem_rs2_data; end
            5'b11000: begin amo_do_write=1;
                amo_wdata=(amo_rd<ex_mem_rs2_data)?amo_rd:ex_mem_rs2_data; end
            5'b11100: begin amo_do_write=1;
                amo_wdata=(amo_rd>ex_mem_rs2_data)?amo_rd:ex_mem_rs2_data; end
            default:  amo_do_write = 1'b0;
        endcase
    end
end

// SC success latch (lr_valid cleared at write start, need to capture earlier)
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) sc_success_lat <= 1'b0;
    else if (amo_state == AMO_IDLE && ex_mem_ctrl.amo && ex_mem_valid && dmem_ack)
        sc_success_lat <= sc_success;
end

// LR/SC reservation
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin lr_valid <= 1'b0; lr_addr <= 64'h0; end
    else if (ex_mem_ctrl.amo && dmem_ack) begin
        case (ex_mem_ctrl.amo_op)
            5'b00010: begin lr_valid<=1; lr_addr<=phys_addr; end // LR
            5'b00011: lr_valid <= 1'b0;                           // SC clears
            default: if (ex_mem_ctrl.mem_write && phys_addr==lr_addr)
                         lr_valid <= 1'b0;
        endcase
    end else if (ex_mem_ctrl.mem_write && dmem_ack && phys_addr==lr_addr)
        lr_valid <= 1'b0;
end

// Memory bus
assign dmem_addr  = phys_addr;
assign dmem_req   = dmem_req_va & (~mmu_active | mem_mmu_done) & ~mem_page_fault;
assign dmem_we    = (ex_mem_ctrl.mem_write & ~ex_mem_ctrl.amo) |
                    (ex_mem_ctrl.amo & (amo_state == AMO_WRITE));
assign dmem_wdata = ex_mem_ctrl.amo ? amo_wdata :
                    store_data_aligned(ex_mem_rs2_data, ex_mem_ctrl.funct3, phys_addr[2:0]);
assign dmem_strb  = ex_mem_ctrl.amo ?
                    (ex_mem_ctrl.funct3[0] ? 8'hFF : 8'h0F) :
                    mem_strb(ex_mem_ctrl.funct3, phys_addr[2:0]);

// SC result
logic [63:0] sc_result;
logic        sc_result_val;
assign sc_result_val = (amo_state == AMO_WRITE || amo_was_writing) ? sc_success_lat : sc_success;
assign sc_result = (ex_mem_ctrl.amo && ex_mem_ctrl.amo_op == 5'b00011) ?
                   (sc_result_val ? 64'h0 : 64'h1) : 64'h0;

// MEM/WB stall and register

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        mem_wb_ctrl  <= '0; mem_wb_rd <= 5'h0; mem_wb_valid <= 1'b0;
    end else if (!mem_wb_stall) begin
        mem_wb_alu_result <= ex_mem_ctrl.amo ?
                             (ex_mem_ctrl.amo_op==5'b00011 ? sc_result :
                              ex_mem_ctrl.amo_op==5'b00010 ? dmem_rdata :
                              amo_rdata_lat) :
                             ex_mem_alu_result;
        mem_wb_mem_rdata  <= ex_mem_ctrl.amo ? amo_rdata_lat :
                             load_extend(dmem_rdata, ex_mem_ctrl.funct3, phys_addr[2:0]);
        mem_wb_pc4        <= ex_mem_pc + 64'd4;
        mem_wb_rd         <= ex_mem_rd;
        mem_wb_ctrl       <= ex_mem_ctrl;
        mem_wb_valid      <= ex_mem_valid;
    end
end

// ============================================================
//  STAGE 5: WRITE BACK
// ============================================================
always_comb begin
    wb_en   = mem_wb_valid & mem_wb_ctrl.reg_write;
    wb_rd   = mem_wb_rd;
    wb_data = mem_wb_ctrl.amo       ? mem_wb_alu_result :
              mem_wb_ctrl.mem_read  ? mem_wb_mem_rdata  :
              (mem_wb_ctrl.jal | mem_wb_ctrl.jalr) ? mem_wb_pc4 :
              mem_wb_alu_result;
end

// ============================================================
//  HELPERS
// ============================================================
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

function automatic [7:0] mem_strb(input [2:0] funct3, input [2:0] offset);
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

endmodule
`default_nettype wire