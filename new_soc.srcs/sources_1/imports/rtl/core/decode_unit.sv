// ============================================================
//  decode_unit.sv  -  RV64IMAC full decoder  (IIITB 1TOPs SoC)
//  Fixes from session:
//  - AMO: alu_src=1, imm=0 so addr=rs1+0 (not rs1+rs2)
//  - CSRRWI/CSRRSI/CSRRCI: imm = CSR address (not UIMM)
//  - SFENCE.VMA decoded and ctrl.sfence_vma set
// ============================================================
`timescale 1ns/1ps

`include "riscv_pkg.svh"

module decode_unit (
    input  logic [31:0] instr,
    input  logic [63:0] pc,
    output ctrl_signals_t ctrl,
    output logic [4:0]  rs1,
    output logic [4:0]  rs2,
    output logic [4:0]  rd,
    output logic [63:0] imm,
    output logic [2:0]  funct3,
    output logic [6:0]  funct7,
    output logic [6:0]  opcode,
    output logic        illegal
);

`include "riscv_pkg.svh"

assign opcode = instr[6:0];
assign rd     = instr[11:7];
assign funct3 = instr[14:12];
assign rs1    = instr[19:15];
assign rs2    = instr[24:20];
assign funct7 = instr[31:25];

// Immediate variants
logic [63:0] imm_i, imm_s, imm_b, imm_u, imm_j, imm_csr;

assign imm_i   = {{52{instr[31]}}, instr[31:20]};
assign imm_s   = {{52{instr[31]}}, instr[31:25], instr[11:7]};
assign imm_b   = {{51{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0};
assign imm_u   = {{32{instr[31]}}, instr[31:12], 12'h0};
assign imm_j   = {{43{instr[31]}}, instr[31], instr[19:12], instr[20], instr[30:21], 1'b0};
assign imm_csr = {59'h0, instr[19:15]}; // UIMM for CSRRxI

always_comb begin
    ctrl        = '0;
    ctrl.alu_op = ALU_ADD;   // explicit enum init (Vivado requires this)
    ctrl.csr_op = CSR_NOP;   // explicit enum init
    imm         = 64'h0;
    illegal     = 1'b0;

    case (opcode)

        // ---- LUI ----
        OP_LUI: begin
            ctrl.reg_write = 1'b1;
            ctrl.alu_op    = ALU_LUI;
            ctrl.alu_src   = 1'b1;
            imm = imm_u;
        end

        // ---- AUIPC ----
        OP_AUIPC: begin
            ctrl.reg_write = 1'b1;
            ctrl.alu_op    = ALU_ADD;
            ctrl.alu_src   = 1'b1;
            ctrl.auipc     = 1'b1;
            imm = imm_u;
        end

        // ---- JAL ----
        OP_JAL: begin
            ctrl.reg_write = 1'b1;
            ctrl.jal       = 1'b1;
            ctrl.alu_op    = ALU_ADD;
            ctrl.alu_src   = 1'b1;
            imm = imm_j;
        end

        // ---- JALR ----
        OP_JALR: begin
            ctrl.reg_write = 1'b1;
            ctrl.jalr      = 1'b1;
            ctrl.alu_op    = ALU_ADD;
            ctrl.alu_src   = 1'b1;
            imm = imm_i;
        end

        // ---- BRANCH ----
        OP_BRANCH: begin
            ctrl.branch  = 1'b1;
            ctrl.alu_src = 1'b0;
            imm = imm_b;
            case (funct3)
                3'b000: ctrl.alu_op = ALU_SUB;  // BEQ
                3'b001: ctrl.alu_op = ALU_SUB;  // BNE
                3'b100: ctrl.alu_op = ALU_SLT;  // BLT
                3'b101: ctrl.alu_op = ALU_SLT;  // BGE
                3'b110: ctrl.alu_op = ALU_SLTU; // BLTU
                3'b111: ctrl.alu_op = ALU_SLTU; // BGEU
                default: illegal = 1'b1;
            endcase
        end

        // ---- LOAD ----
        OP_LOAD: begin
            ctrl.reg_write = 1'b1;
            ctrl.mem_read  = 1'b1;
            ctrl.alu_op    = ALU_ADD;
            ctrl.alu_src   = 1'b1;
            ctrl.funct3    = funct3;
            imm = imm_i;
        end

        // ---- STORE ----
        OP_STORE: begin
            ctrl.mem_write = 1'b1;
            ctrl.alu_op    = ALU_ADD;
            ctrl.alu_src   = 1'b1;
            ctrl.funct3    = funct3;
            imm = imm_s;
        end

        // ---- OP-IMM ----
        OP_OP_IMM: begin
            ctrl.reg_write = 1'b1;
            ctrl.alu_src   = 1'b1;
            imm = imm_i;
            case (funct3)
                3'b000: ctrl.alu_op = ALU_ADD;
                3'b010: ctrl.alu_op = ALU_SLT;
                3'b011: ctrl.alu_op = ALU_SLTU;
                3'b100: ctrl.alu_op = ALU_XOR;
                3'b110: ctrl.alu_op = ALU_OR;
                3'b111: ctrl.alu_op = ALU_AND;
                3'b001: begin
                    ctrl.alu_op = ALU_SLL;
                    imm = {58'h0, instr[25:20]}; // shamt6
                end
                3'b101: begin
                    ctrl.alu_op = instr[30] ? ALU_SRA : ALU_SRL;
                    imm = {58'h0, instr[25:20]};
                end
                default: illegal = 1'b1;
            endcase
        end

        // ---- OP (R-type) ----
        OP_OP: begin
            ctrl.reg_write = 1'b1;
            ctrl.alu_src   = 1'b0;
            case ({funct7, funct3})
                10'b0000000_000: ctrl.alu_op = ALU_ADD;
                10'b0100000_000: ctrl.alu_op = ALU_SUB;
                10'b0000000_001: ctrl.alu_op = ALU_SLL;
                10'b0000000_010: ctrl.alu_op = ALU_SLT;
                10'b0000000_011: ctrl.alu_op = ALU_SLTU;
                10'b0000000_100: ctrl.alu_op = ALU_XOR;
                10'b0000000_101: ctrl.alu_op = ALU_SRL;
                10'b0100000_101: ctrl.alu_op = ALU_SRA;
                10'b0000000_110: ctrl.alu_op = ALU_OR;
                10'b0000000_111: ctrl.alu_op = ALU_AND;
                // M-extension
                10'b0000001_000: ctrl.alu_op = ALU_MUL;
                10'b0000001_001: ctrl.alu_op = ALU_MULH;
                10'b0000001_010: ctrl.alu_op = ALU_MULHSU;
                10'b0000001_011: ctrl.alu_op = ALU_MULHU;
                10'b0000001_100: ctrl.alu_op = ALU_DIV;
                10'b0000001_101: ctrl.alu_op = ALU_DIVU;
                10'b0000001_110: ctrl.alu_op = ALU_REM;
                10'b0000001_111: ctrl.alu_op = ALU_REMU;
                default: illegal = 1'b1;
            endcase
        end

        // ---- OP-IMM-32 ----
        OP_OP_IMM32: begin
            ctrl.reg_write = 1'b1;
            ctrl.alu_src   = 1'b1;
            ctrl.word_op   = 1'b1;
            imm = imm_i;
            case (funct3)
                3'b000: ctrl.alu_op = ALU_ADD;
                3'b001: begin ctrl.alu_op = ALU_SLL; imm = {59'h0, instr[24:20]}; end
                3'b101: begin
                    ctrl.alu_op = instr[30] ? ALU_SRA : ALU_SRL;
                    imm = {59'h0, instr[24:20]};
                end
                default: illegal = 1'b1;
            endcase
        end

        // ---- OP-32 ----
        OP_OP32: begin
            ctrl.reg_write = 1'b1;
            ctrl.alu_src   = 1'b0;
            ctrl.word_op   = 1'b1;
            case ({funct7, funct3})
                10'b0000000_000: ctrl.alu_op = ALU_ADD;
                10'b0100000_000: ctrl.alu_op = ALU_SUB;
                10'b0000000_001: ctrl.alu_op = ALU_SLL;
                10'b0000000_101: ctrl.alu_op = ALU_SRL;
                10'b0100000_101: ctrl.alu_op = ALU_SRA;
                10'b0000001_000: ctrl.alu_op = ALU_MUL;
                10'b0000001_100: ctrl.alu_op = ALU_DIV;
                10'b0000001_101: ctrl.alu_op = ALU_DIVU;
                10'b0000001_110: ctrl.alu_op = ALU_REM;
                10'b0000001_111: ctrl.alu_op = ALU_REMU;
                default: illegal = 1'b1;
            endcase
        end

        // ---- MISC-MEM (FENCE / FENCE.I) ----
        OP_MISC_MEM: begin
            if (funct3 == 3'b001)
                ctrl.fence = 1'b1; // FENCE.I - flush I-cache
            else
                ctrl.fence = 1'b1; // FENCE - no-op in simple pipeline
        end

        // ---- AMO  (A-extension: LR/SC + AMOSWAP/AMOADD/...) ----
        OP_AMO: begin
            ctrl.reg_write = 1'b1;
            ctrl.amo       = 1'b1;
            ctrl.amo_op    = funct7[6:2]; // funct5
            ctrl.funct3    = funct3;
            ctrl.mem_read  = 1'b1;
            ctrl.mem_write = (funct7[6:2] != 5'b00010); // not LR
            ctrl.alu_op    = ALU_ADD;
            // KEY FIX: AMO address = rs1 + 0, NOT rs1 + rs2
            ctrl.alu_src   = 1'b1;
            imm            = 64'h0;
        end

        // ---- SYSTEM ----
        OP_SYSTEM: begin
            case (funct3)
                3'b000: begin
                    // Use field comparisons (avoids 25-bit literal issues in XSIM)
                    // funct7=instr[31:25], rs2=instr[24:20], rs1=instr[19:15]
                    if      (instr[31:7] == 25'h0000000) ctrl.ecall  = 1'b1; // ECALL
                    else if (instr[31:7] == 25'h0002000) ctrl.ebreak = 1'b1; // EBREAK
                    else if (instr[31:7] == 25'h0204000) ctrl.sret   = 1'b1; // SRET
                    else if (instr[31:7] == 25'h0604000) ctrl.mret   = 1'b1; // MRET
                    else if (instr[31:7] == 25'h020A000) ctrl.wfi    = 1'b1; // WFI
                    else if (instr[31:25] == 7'b000_1001)ctrl.sfence_vma=1'b1; // SFENCE.VMA
                    else                                 illegal = 1'b1;
                end
                3'b001: begin // CSRRW
                    ctrl.reg_write = 1'b1;
                    ctrl.csr_read  = 1'b1;
                    ctrl.csr_op    = CSR_RW;
                    imm = {{52{instr[31]}}, instr[31:20]}; // CSR addr
                end
                3'b010: begin // CSRRS
                    ctrl.reg_write = 1'b1;
                    ctrl.csr_read  = 1'b1;
                    ctrl.csr_op    = CSR_RS;
                    imm = {{52{instr[31]}}, instr[31:20]};
                end
                3'b011: begin // CSRRC
                    ctrl.reg_write = 1'b1;
                    ctrl.csr_read  = 1'b1;
                    ctrl.csr_op    = CSR_RC;
                    imm = {{52{instr[31]}}, instr[31:20]};
                end
                3'b101: begin // CSRRWI
                    ctrl.reg_write = 1'b1;
                    ctrl.csr_read  = 1'b1;
                    ctrl.csr_op    = CSR_RW;
                    ctrl.csr_imm   = 1'b1;
                    // KEY FIX: imm = CSR address (not UIMM)
                    imm = {{52{1'b0}}, instr[31:20]};
                end
                3'b110: begin // CSRRSI
                    ctrl.reg_write = 1'b1;
                    ctrl.csr_read  = 1'b1;
                    ctrl.csr_op    = CSR_RS;
                    ctrl.csr_imm   = 1'b1;
                    imm = {{52{1'b0}}, instr[31:20]};
                end
                3'b111: begin // CSRRCI
                    ctrl.reg_write = 1'b1;
                    ctrl.csr_read  = 1'b1;
                    ctrl.csr_op    = CSR_RC;
                    ctrl.csr_imm   = 1'b1;
                    imm = {{52{1'b0}}, instr[31:20]};
                end
                default: illegal = 1'b1;
            endcase
        end

        default: illegal = 1'b1;
    endcase
end

endmodule
`default_nettype wire