`ifndef RISCV_PKG_SVH
`define RISCV_PKG_SVH
// ============================================================
//  riscv_pkg.svh  –  RV64IMAC  (IIITB 1TOPs SoC)
// ============================================================

localparam [6:0]
    OP_LOAD     = 7'b000_0011,
    OP_STORE    = 7'b010_0011,
    OP_BRANCH   = 7'b110_0011,
    OP_JALR     = 7'b110_0111,
    OP_MISC_MEM = 7'b000_1111,
    OP_AMO      = 7'b010_1111,
    OP_JAL      = 7'b110_1111,
    OP_OP_IMM   = 7'b001_0011,
    OP_OP       = 7'b011_0011,
    OP_AUIPC    = 7'b001_0111,
    OP_LUI      = 7'b011_0111,
    OP_OP_IMM32 = 7'b001_1011,
    OP_OP32     = 7'b011_1011,
    OP_SYSTEM   = 7'b111_0011;

typedef enum logic [4:0] {
    ALU_ADD    = 5'h00,
    ALU_SUB    = 5'h01,
    ALU_SLL    = 5'h02,
    ALU_SLT    = 5'h03,
    ALU_SLTU   = 5'h04,
    ALU_XOR    = 5'h05,
    ALU_SRL    = 5'h06,
    ALU_SRA    = 5'h07,
    ALU_OR     = 5'h08,
    ALU_AND    = 5'h09,
    ALU_LUI    = 5'h0A,
    ALU_MUL    = 5'h0B,
    ALU_MULH   = 5'h0C,
    ALU_MULHSU = 5'h0D,
    ALU_MULHU  = 5'h0E,
    ALU_DIV    = 5'h0F,
    ALU_DIVU   = 5'h10,
    ALU_REM    = 5'h11,
    ALU_REMU   = 5'h12,
    ALU_PASS_B = 5'h13
} alu_op_t;

localparam [1:0]
    CSR_NOP = 2'b00,
    CSR_RW  = 2'b01,
    CSR_RS  = 2'b10,
    CSR_RC  = 2'b11;

localparam [1:0]
    PRIV_U = 2'b00,
    PRIV_S = 2'b01,
    PRIV_M = 2'b11;

// Control signals — extended for AMO (A-ext) and SFENCE.VMA (MMU)
typedef struct packed {
    logic        reg_write;
    alu_op_t     alu_op;       // 5 bits
    logic        alu_src;
    logic        word_op;
    logic        auipc;
    logic        branch;
    logic        jal;
    logic        jalr;
    logic        mem_read;
    logic        mem_write;
    logic [2:0]  funct3;
    logic        amo;          // A-extension AMO instruction
    logic [4:0]  amo_op;      // funct5: LR=00010 SC=00011 SWAP=00001 ADD=00000 ...
    logic        csr_read;
    logic [1:0]  csr_op;
    logic        csr_imm;
    logic        ecall;
    logic        ebreak;
    logic        mret;
    logic        sret;
    logic        wfi;
    logic        fence;
    logic        sfence_vma;   // flush TLB
    logic        illegal;
} ctrl_signals_t;

`endif // RISCV_PKG_SVH
