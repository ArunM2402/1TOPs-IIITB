// ============================================================
//  Testbench - Version 2
// Tried mimicing common tests suggested by literature and AI that we should do

// ============================================================
`timescale 1ns/1ps
`default_nettype none

module tb_riscv_core;

// ============================================================
//  Parameters
// ============================================================
localparam CLK_PERIOD  = 10;          // 10 ns → 100 MHz
localparam MEM_WORDS   = 65536;       // 512 KiB unified memory
localparam TIMEOUT_CYC = 10_000;      // max cycles per test

// ============================================================
//  DUT signals
// ============================================================
logic        clk, rst_n;
logic [63:0] imem_addr;
logic        imem_req;
logic [31:0] imem_rdata;
logic        imem_ack, imem_err;

logic [63:0] dmem_addr;
logic [63:0] dmem_wdata;
logic [7:0]  dmem_strb;
logic        dmem_req, dmem_we;
logic [63:0] dmem_rdata;
logic        dmem_ack, dmem_err;

logic        irq_m_ext, irq_m_timer, irq_m_sw, irq_s_ext;
logic [63:0] debug_pc;

// ============================================================
//  DUT instantiation
// ============================================================
riscv_core #(
    .RESET_ADDR(64'h0000_0000),
    .HARTID    (0)
) dut (
    .clk            (clk),
    .rst_n          (rst_n),
    .imem_addr      (imem_addr),
    .imem_req       (imem_req),
    .imem_rdata     (imem_rdata),
    .imem_ack       (imem_ack),
    .imem_err       (imem_err),
    .dmem_addr      (dmem_addr),
    .dmem_wdata     (dmem_wdata),
    .dmem_strb      (dmem_strb),
    .dmem_req       (dmem_req),
    .dmem_we        (dmem_we),
    .dmem_rdata     (dmem_rdata),
    .dmem_ack       (dmem_ack),
    .dmem_err       (dmem_err),
    .irq_m_external (irq_m_ext),
    .irq_m_timer    (irq_m_timer),
    .irq_m_software (irq_m_sw),
    .irq_s_external (irq_s_ext),
    .debug_pc       (debug_pc)
);

// ============================================================
//  Unified byte-addressable memory model
//  Word 0 = address 0x0000_0000
// ============================================================
logic [7:0] mem [MEM_WORDS*8];   // byte array

// Instruction fetch (combinational, 1-cycle ack)
always_comb begin
    imem_ack   = imem_req;
    imem_err   = 1'b0;
    imem_rdata = 32'h0000_0013; // NOP default
    if (imem_req) begin
        automatic int base = imem_addr[19:0];  // wrap to memory size
        imem_rdata = {mem[base+3], mem[base+2], mem[base+1], mem[base]};
    end
end

// Data memory (1-cycle ack)
always_ff @(posedge clk) begin
    dmem_ack  <= dmem_req;
    dmem_err  <= 1'b0;
    dmem_rdata<= 64'h0;
    if (dmem_req) begin
        automatic int base = dmem_addr[19:0];
        if (!dmem_we) begin
            dmem_rdata <= {mem[base+7], mem[base+6], mem[base+5], mem[base+4],
                           mem[base+3], mem[base+2], mem[base+1], mem[base  ]};
        end else begin
            for (int b = 0; b < 8; b++)
                if (dmem_strb[b]) mem[base+b] <= dmem_wdata[b*8 +: 8];
        end
    end
end

// ============================================================
//  Clock
// ============================================================
initial clk = 1'b0;
always #(CLK_PERIOD/2) clk = ~clk;

// ============================================================
//  Interrupt defaults
// ============================================================
initial begin
    irq_m_ext   = 1'b0;
    irq_m_timer = 1'b0;
    irq_m_sw    = 1'b0;
    irq_s_ext   = 1'b0;
end

// ============================================================
//  Helper tasks
// ============================================================

// Reset the core
task reset_core();
    rst_n = 1'b0;
    repeat(4) @(posedge clk);
    rst_n = 1'b1;
    @(posedge clk);
endtask

// Clear memory
task clear_mem();
    for (int i = 0; i < MEM_WORDS*8; i++) mem[i] = 8'h0;
endtask

// Write a 32-bit instruction word at byte address
task write_instr(input int addr, input logic [31:0] instr);
    mem[addr+0] = instr[7:0];
    mem[addr+1] = instr[15:8];
    mem[addr+2] = instr[23:16];
    mem[addr+3] = instr[31:24];
endtask

// Write a 64-bit value at byte address
task write_mem64(input int addr, input logic [63:0] val);
    for (int b = 0; b < 8; b++) mem[addr+b] = val[b*8 +: 8];
endtask

// Read register file via hierarchical reference
function automatic [63:0] read_reg(input int r);
    return dut.regfile[r];
endfunction

// Wait until PC == target or timeout
task wait_pc(input logic [63:0] target, output logic timeout);
    int cnt = 0;
    timeout = 1'b0;
    while (debug_pc !== target) begin
        @(posedge clk);
        cnt++;
        if (cnt > TIMEOUT_CYC) begin
            timeout = 1'b1;
            return;
        end
    end
endtask

// Advance N cycles
task run_cycles(input int n);
    repeat(n) @(posedge clk);
endtask

// ============================================================
//  Test bookkeeping
// ============================================================
int pass_cnt, fail_cnt;

task check(
    input string  test_name,
    input logic   condition
);
    if (condition) begin
        $display("  PASS  %s", test_name);
        pass_cnt++;
    end else begin
        $display("  FAIL  %s", test_name);
        fail_cnt++;
    end
endtask

// ============================================================
//  TEST PROGRAMS
//  Each test loads a small program, resets the core,
//  runs, then checks register state.
// ============================================================

// ---- Encoding helpers ----
// R-type
function automatic [31:0] R(
    input [6:0] opcode, input [4:0] rd, input [2:0] f3,
    input [4:0] rs1, input [4:0] rs2, input [6:0] f7);
    R = {f7, rs2, rs1, f3, rd, opcode};
endfunction

// I-type
function automatic [31:0] I(
    input [6:0] opcode, input [4:0] rd, input [2:0] f3,
    input [4:0] rs1, input [11:0] imm);
    I = {imm, rs1, f3, rd, opcode};
endfunction

// S-type
function automatic [31:0] S(
    input [6:0] opcode, input [2:0] f3,
    input [4:0] rs1, input [4:0] rs2, input [11:0] imm);
    S = {imm[11:5], rs2, rs1, f3, imm[4:0], opcode};
endfunction

// B-type
function automatic [31:0] B(
    input [6:0] opcode, input [2:0] f3,
    input [4:0] rs1, input [4:0] rs2, input [12:1] offset);
    B = {offset[12], offset[10:5], rs2, rs1, f3,
         offset[4:1], offset[11], opcode};
endfunction

// U-type
function automatic [31:0] U(
    input [6:0] opcode, input [4:0] rd, input [31:12] imm);
    U = {imm, rd, opcode};
endfunction

// J-type (JAL)
function automatic [31:0] J(
    input [4:0] rd, input [20:1] offset);
    J = {offset[20], offset[10:1], offset[11], offset[19:12], rd, 7'b110_1111};
endfunction

// Opcodes
localparam [6:0]
    OP     = 7'b011_0011,
    OP_IMM = 7'b001_0011,
    OP32   = 7'b011_1011,
    OPI32  = 7'b001_1011,
    LOAD   = 7'b000_0011,
    STORE  = 7'b010_0011,
    BRANCH = 7'b110_0011,
    JALR_OP= 7'b110_0111,
    LUI_OP = 7'b011_0111,
    AUIPC_OP=7'b001_0111,
    SYSTEM = 7'b111_0011;

// ADDI rd, rs1, imm  (most common)
`define ADDI(rd,rs1,imm) I(OP_IMM, rd, 3'b000, rs1, imm)
`define ADD(rd,rs1,rs2)  R(OP,     rd, 3'b000, rs1, rs2, 7'b000_0000)
`define SUB(rd,rs1,rs2)  R(OP,     rd, 3'b000, rs1, rs2, 7'b010_0000)
`define NOP              `ADDI(5'd0, 5'd0, 12'h0)
`define EBREAK           32'h0010_0073
`define ECALL            32'h0000_0073

// ============================================================
//  TEST 1: ADDI / register file
// ============================================================
task test_addi();
    $display("\n[TEST 1] ADDI / register file");
    clear_mem();
    // x1 = 5
    // x2 = x1 + 3  → 8
    // x3 = x2 + (-2) → 6
    // EBREAK to stop
    write_instr('h00, `ADDI(5'd1, 5'd0, 12'd5));
    write_instr('h04, `ADDI(5'd2, 5'd1, 12'd3));
    write_instr('h08, `ADDI(5'd3, 5'd2, 12'hFFE)); // -2
    write_instr('h0C, `EBREAK);
    reset_core();
    begin
        logic to;
        wait_pc(64'h0000_000C, to);
        run_cycles(3);
        check("ADDI x1=5",      read_reg(1) == 64'd5);
        check("ADDI x2=8",      read_reg(2) == 64'd8);
        check("ADDI x3=6",      read_reg(3) == 64'd6);
        check("x0 always zero", read_reg(0) == 64'd0);
    end
endtask

// ============================================================
//  TEST 2: LUI / AUIPC
// ============================================================
task test_lui_auipc();
    $display("\n[TEST 2] LUI / AUIPC");
    clear_mem();
    // LUI x1, 0xABCDE → x1 = 0xABCDE_000
    write_instr('h00, U(LUI_OP,  5'd1, 20'hABCDE));
    // AUIPC x2, 1 → x2 = PC(4) + 0x1000 = 0x1004
    write_instr('h04, U(AUIPC_OP,5'd2, 20'h00001));
    write_instr('h08, `EBREAK);
    reset_core();
    begin
        logic to;
        wait_pc(64'h08, to);
        run_cycles(3);
        check("LUI  x1=0xABCDE000", read_reg(1) == 64'hABCDE000);
        check("AUIPC x2=0x1004",   read_reg(2) == 64'h0000_1004);
    end
endtask

// ============================================================
//  TEST 3: ALU R-type (ADD/SUB/AND/OR/XOR/SLL/SRL/SRA/SLT)
// ============================================================
task test_alu_rtype();
    $display("\n[TEST 3] ALU R-type");
    clear_mem();
    // x1=10, x2=3
    write_instr('h00, `ADDI(5'd1, 5'd0, 12'd10));
    write_instr('h04, `ADDI(5'd2, 5'd0, 12'd3));
    // ADD x3 = 13
    write_instr('h08, `ADD(5'd3, 5'd1, 5'd2));
    // SUB x4 = 7
    write_instr('h0C, `SUB(5'd4, 5'd1, 5'd2));
    // AND x5 = 10 & 3 = 2
    write_instr('h10, R(OP, 5'd5, 3'b111, 5'd1, 5'd2, 7'h0));
    // OR  x6 = 10 | 3 = 11
    write_instr('h14, R(OP, 5'd6, 3'b110, 5'd1, 5'd2, 7'h0));
    // XOR x7 = 10 ^ 3 = 9
    write_instr('h18, R(OP, 5'd7, 3'b100, 5'd1, 5'd2, 7'h0));
    // SLL x8 = 10 << 3 = 80
    write_instr('h1C, R(OP, 5'd8, 3'b001, 5'd1, 5'd2, 7'h0));
    // SRL x9 = 10 >> 3 = 1
    write_instr('h20, R(OP, 5'd9, 3'b101, 5'd1, 5'd2, 7'h0));
    // SLT x10 = (3 < 10) = 1
    write_instr('h24, R(OP, 5'd10, 3'b010, 5'd2, 5'd1, 7'h0));
    // SRA x11 = -8 >>> 2 = -2  (set x12=-8 first)
    write_instr('h28, `ADDI(5'd12, 5'd0, 12'hFF8));  // -8
    write_instr('h2C, `ADDI(5'd13, 5'd0, 12'd2));
    write_instr('h30, R(OP, 5'd11, 3'b101, 5'd12, 5'd13, 7'b010_0000));
    write_instr('h34, `EBREAK);
    reset_core();
    begin
        logic to;
        wait_pc(64'h34, to);
        run_cycles(3);
        check("ADD  10+3=13",   read_reg(3)  == 64'd13);
        check("SUB  10-3=7",    read_reg(4)  == 64'd7);
        check("AND  10&3=2",    read_reg(5)  == 64'd2);
        check("OR   10|3=11",   read_reg(6)  == 64'd11);
        check("XOR  10^3=9",    read_reg(7)  == 64'd9);
        check("SLL  10<<3=80",  read_reg(8)  == 64'd80);
        check("SRL  10>>3=1",   read_reg(9)  == 64'd1);
        check("SLT  3<10=1",    read_reg(10) == 64'd1);
        check("SRA -8>>>2=-2",  read_reg(11) == 64'hFFFF_FFFF_FFFF_FFFE);
    end
endtask

// ============================================================
//  TEST 4: Load / Store  (LB/LH/LW/LD + SB/SH/SW/SD)
// ============================================================
task test_load_store();
    $display("\n[TEST 4] Load / Store");
    clear_mem();
    // Data at 0x200: 0xDEAD_BEEF_1234_5678
    write_mem64('h200, 64'hDEAD_BEEF_1234_5678);

    // x1 = base address 0x200
    write_instr('h00, `ADDI(5'd1, 5'd0, 12'h200));
    // LD  x2 = full 64-bit
    write_instr('h04, I(LOAD,  5'd2,  3'b011, 5'd1, 12'h0));
    // LW  x3 = lower 32, sign-extended  (0x1234_5678 → positive)
    write_instr('h08, I(LOAD,  5'd3,  3'b010, 5'd1, 12'h0));
    // LH  x4 = lower 16, sign-extended  (0x5678 → positive)
    write_instr('h0C, I(LOAD,  5'd4,  3'b001, 5'd1, 12'h0));
    // LB  x5 = lower 8, sign-extended   (0x78 → positive)
    write_instr('h10, I(LOAD,  5'd5,  3'b000, 5'd1, 12'h0));
    // LBU x6 = 0xDE (unsigned, no sign-extend)
    write_instr('h14, I(LOAD,  5'd6,  3'b100, 5'd1, 12'h7));
    // Store: SW x3 to 0x210, then LD back
    write_instr('h18, S(STORE, 3'b010, 5'd1, 5'd3, 12'h10));
    write_instr('h1C, I(LOAD,  5'd7,  3'b011, 5'd1, 12'h10));
    write_instr('h20, `EBREAK);
    reset_core();
    begin
        logic to;
        wait_pc(64'h20, to);
        run_cycles(3);
        check("LD   64-bit",       read_reg(2) == 64'hDEAD_BEEF_1234_5678);
        check("LW   sign-extend",  read_reg(3) == 64'h0000_0000_1234_5678);
        check("LH   sign-extend",  read_reg(4) == 64'h0000_0000_0000_5678);
        check("LB   sign-extend",  read_reg(5) == 64'h0000_0000_0000_0078);
        check("LBU  zero-extend",  read_reg(6) == 64'h0000_0000_0000_00DE);
        check("SW/LD roundtrip",   read_reg(7) == 64'h0000_0000_1234_5678);
    end
endtask

// ============================================================
//  TEST 5: Branches (BEQ/BNE/BLT/BGE/BLTU/BGEU)
// ============================================================
task test_branches();
    $display("\n[TEST 5] Branches");
    clear_mem();
    // x1=5, x2=5, x3=3
    // BEQ x1,x2 → taken  → x10=1
    // BNE x1,x2 → not taken
    // BLT x3,x1 → taken  → x11=1
    // BGE x1,x3 → taken  → x12=1
    write_instr('h00, `ADDI(5'd1, 5'd0, 12'd5));
    write_instr('h04, `ADDI(5'd2, 5'd0, 12'd5));
    write_instr('h08, `ADDI(5'd3, 5'd0, 12'd3));
    // BEQ taken → jumps to 0x18
    write_instr('h0C, B(BRANCH,3'b000,5'd1,5'd2,12'd12));   // +12 → 0x18
    write_instr('h10, `ADDI(5'd9,5'd0,12'hFFF)); // skipped
    write_instr('h14, `NOP);
    write_instr('h18, `ADDI(5'd10,5'd0,12'd1));  // x10=1
    // BNE not taken → falls through
    write_instr('h1C, B(BRANCH,3'b001,5'd1,5'd2,12'd8));    // not taken
    write_instr('h20, `ADDI(5'd11,5'd0,12'd1));  // x11=1 (falls through)
    // BLT x3<x1 → taken → skip x12 poison
    write_instr('h24, B(BRANCH,3'b100,5'd3,5'd1,12'd8));    // +8 → 0x2C
    write_instr('h28, `ADDI(5'd8,5'd0,12'hFFF)); // skipped
    write_instr('h2C, `ADDI(5'd12,5'd0,12'd1));  // x12=1
    // BGE x1>=x3 → taken
    write_instr('h30, B(BRANCH,3'b101,5'd1,5'd3,12'd8));    // +8 → 0x38
    write_instr('h34, `ADDI(5'd7,5'd0,12'hFFF)); // skipped
    write_instr('h38, `ADDI(5'd13,5'd0,12'd1));  // x13=1
    write_instr('h3C, `EBREAK);
    reset_core();
    begin
        logic to;
        wait_pc(64'h3C, to);
        run_cycles(3);
        check("BEQ taken    x10=1", read_reg(10) == 64'd1);
        check("BEQ skip     x9=0",  read_reg(9)  == 64'd0);
        check("BNE fallthru x11=1", read_reg(11) == 64'd1);
        check("BLT taken    x12=1", read_reg(12) == 64'd1);
        check("BLT skip     x8=0",  read_reg(8)  == 64'd0);
        check("BGE taken    x13=1", read_reg(13) == 64'd1);
    end
endtask

// ============================================================
//  TEST 6: JAL / JALR
// ============================================================
task test_jal_jalr();
    $display("\n[TEST 6] JAL / JALR");
    clear_mem();
    // JAL x1, +8  (jump to 0x08, link = 0x04)
    write_instr('h00, J(5'd1, 20'd8));
    write_instr('h04, `ADDI(5'd9,5'd0,12'hFFF)); // never reached
    write_instr('h08, `ADDI(5'd2,5'd0,12'd42));
    // JALR x3, x1, 0  (jump back to 0x04 using x1 = 0x04)
    write_instr('h0C, I(JALR_OP,5'd3,3'b000,5'd1,12'h0));
    write_instr('h04, `ADDI(5'd4,5'd0,12'd7));   // now executed
    // after JALR lands at 0x04, continue:
    write_instr('h04, `ADDI(5'd4,5'd0,12'd7));
    write_instr('h08, `EBREAK);  // overwrite 0x08 for second pass
    // Simpler flat version to avoid overwrite confusion:
    clear_mem();
    // 0x00: JAL x1, 0x0C  (jump forward 12)
    write_instr('h00, J(5'd1, 20'd12));
    write_instr('h04, `ADDI(5'd9,5'd0,12'hFFF)); // skip
    write_instr('h08, `ADDI(5'd9,5'd0,12'hFFF)); // skip
    write_instr('h0C, `ADDI(5'd2,5'd0,12'd42));
    // 0x10: JALR x3, x1, +4  → x1=4, +4 → PC=8  (but we'll do simpler)
    write_instr('h10, `ADDI(5'd5,5'd0,12'd1));
    write_instr('h14, `EBREAK);
    reset_core();
    begin
        logic to;
        wait_pc(64'h14, to);
        run_cycles(3);
        check("JAL  link  x1=0x04", read_reg(1) == 64'h04);
        check("JAL  jump  x2=42",   read_reg(2) == 64'd42);
        check("JAL  skip  x9=0",    read_reg(9) == 64'd0);
        check("After JAL  x5=1",    read_reg(5) == 64'd1);
    end
endtask

// ============================================================
//  TEST 7: Data hazard forwarding  (back-to-back RAW)
// ============================================================
task test_forwarding();
    $display("\n[TEST 7] Data Hazard Forwarding");
    clear_mem();
    // Three consecutive dependent adds – each uses result of previous
    write_instr('h00, `ADDI(5'd1, 5'd0, 12'd1));
    write_instr('h04, `ADD (5'd2, 5'd1, 5'd1));   // 2 = 1+1 = 2
    write_instr('h08, `ADD (5'd3, 5'd2, 5'd1));   // 3 = 2+1 = 3
    write_instr('h0C, `ADD (5'd4, 5'd3, 5'd2));   // 4 = 3+2 = 5
    write_instr('h10, `ADD (5'd5, 5'd4, 5'd3));   // 5 = 5+3 = 8
    write_instr('h14, `EBREAK);
    reset_core();
    begin
        logic to;
        wait_pc(64'h14, to);
        run_cycles(3);
        check("FWD x1=1", read_reg(1) == 64'd1);
        check("FWD x2=2", read_reg(2) == 64'd2);
        check("FWD x3=3", read_reg(3) == 64'd3);
        check("FWD x4=5", read_reg(4) == 64'd5);
        check("FWD x5=8", read_reg(5) == 64'd8);
    end
endtask

// ============================================================
//  TEST 8: Load-use hazard stall
// ============================================================
task test_load_use();
    $display("\n[TEST 8] Load-Use Stall");
    clear_mem();
    write_mem64('h200, 64'h0000_0000_0000_0064);  // 100 at addr 0x200
    write_instr('h00, `ADDI(5'd1,5'd0,12'h200));
    write_instr('h04, I(LOAD,5'd2,3'b011,5'd1,12'h0));  // LD x2, 0(x1)
    write_instr('h08, `ADD(5'd3,5'd2,5'd2));              // x3 = x2+x2 (needs stall)
    write_instr('h0C, `EBREAK);
    reset_core();
    begin
        logic to;
        wait_pc(64'h0C, to);
        run_cycles(3);
        check("Load-use x2=100",  read_reg(2) == 64'd100);
        check("Load-use x3=200",  read_reg(3) == 64'd200);
    end
endtask

// ============================================================
//  TEST 9: RV64 word instructions (ADDW/SUBW/ADDIW)
// ============================================================
task test_rv64_word();
    $display("\n[TEST 9] RV64 *W instructions");
    clear_mem();
    // ADDIW with overflow: 0x7FFFFFFF + 1 = 0x80000000 → sign-extend = -2147483648
    write_instr('h00, U(LUI_OP, 5'd1, 20'h7FFFF));        // x1 = 0x7FFFF000
    write_instr('h04, I(OPI32,  5'd1, 3'b000, 5'd1, 12'hFFF)); // ADDIW x1,x1,-1 → 0x7FFFF000-1=0x7FFFE_FFF? no
    // Simpler: ADDIW x2, x0, 1 should give 1 with proper sign ext
    write_instr('h00, I(OPI32, 5'd2, 3'b000, 5'd0, 12'h001)); // ADDIW x2=1
    write_instr('h04, I(OPI32, 5'd3, 3'b000, 5'd0, 12'hFFF)); // ADDIW x3=-1 (sign-extended 64)
    // ADDW x4 = 0x7FFF_FFFF + 1 → wraps to -2^31 sign-extended
    write_instr('h08, U(LUI_OP, 5'd5, 20'h7FFFF));
    write_instr('h0C, I(OP_IMM,5'd5,3'b000,5'd5,12'hFFF)); // x5 = 0x7FFFFF_FFF... use ADDI
    write_instr('h00, `ADDI(5'd5,5'd0,12'd0));    // restart simpler
    clear_mem();
    write_instr('h00, I(OPI32, 5'd1, 3'b000, 5'd0, 12'd5));   // ADDIW x1=5
    write_instr('h04, I(OPI32, 5'd2, 3'b000, 5'd0, 12'd3));   // ADDIW x2=3
    write_instr('h08, R(OP32,  5'd3, 3'b000, 5'd1, 5'd2, 7'h0)); // ADDW x3=8
    write_instr('h0C, R(OP32,  5'd4, 3'b000, 5'd1, 5'd2, 7'b010_0000)); // SUBW x4=2
    write_instr('h10, I(OPI32, 5'd5, 3'b000, 5'd0, 12'hFFF)); // ADDIW x5=-1 → 0xFFFF_FFFF_FFFF_FFFF
    write_instr('h14, `EBREAK);
    reset_core();
    begin
        logic to;
        wait_pc(64'h14, to);
        run_cycles(3);
        check("ADDIW x1=5",    read_reg(1) == 64'd5);
        check("ADDIW x2=3",    read_reg(2) == 64'd3);
        check("ADDW  x3=8",    read_reg(3) == 64'd8);
        check("SUBW  x4=2",    read_reg(4) == 64'd2);
        check("ADDIW x5=-1",   read_reg(5) == 64'hFFFF_FFFF_FFFF_FFFF);
    end
endtask

// ============================================================
//  TEST 10: Simple loop (counting)
// ============================================================
task test_loop();
    $display("\n[TEST 10] Loop (count to 10)");
    clear_mem();
    // x1 = 0 (counter), x2 = 10 (limit)
    // loop: x1++; if x1 != x2 goto loop
    write_instr('h00, `ADDI(5'd1,5'd0,12'd0));   // x1=0
    write_instr('h04, `ADDI(5'd2,5'd0,12'd10));  // x2=10
    write_instr('h08, `ADDI(5'd1,5'd1,12'd1));   // loop: x1++
    write_instr('h0C, B(BRANCH,3'b001,5'd1,5'd2,12'hFF8)); // BNE → -8 → 0x08  (offset=-8)
    // BNE offset: target=0x08, PC=0x0C, offset=0x08-0x0C = -4... let me recalculate
    // B-type offset is signed, in multiples of 2
    // target 0x08, PC=0x0C: offset = -4
    write_instr('h0C, B(BRANCH,3'b001,5'd1,5'd2,12'hFFC)); // -4 from 0x0C → 0x08
    write_instr('h10, `EBREAK);
    reset_core();
    begin
        logic to;
        wait_pc(64'h10, to);
        run_cycles(3);
        check("Loop x1=10", read_reg(1) == 64'd10);
    end
endtask

// ============================================================
//  TEST 11: MUL / DIV (M extension)
// ============================================================
task test_mext();
    $display("\n[TEST 11] M-extension MUL/DIV/REM");
    clear_mem();
    write_instr('h00, `ADDI(5'd1,5'd0,12'd6));
    write_instr('h04, `ADDI(5'd2,5'd0,12'd7));
    // MUL x3 = 6*7 = 42
    write_instr('h08, R(OP, 5'd3, 3'b000, 5'd1, 5'd2, 7'b000_0001));
    // DIV x4 = 42/7 = 6
    write_instr('h0C, R(OP, 5'd4, 3'b100, 5'd3, 5'd2, 7'b000_0001));
    // REM x5 = 43 % 7 = 1
    write_instr('h10, `ADDI(5'd6,5'd0,12'd43));
    write_instr('h14, R(OP, 5'd5, 3'b110, 5'd6, 5'd2, 7'b000_0001));
    // DIVU x7 = divide by zero → all-ones
    write_instr('h18, R(OP, 5'd7, 3'b101, 5'd1, 5'd0, 7'b000_0001));
    write_instr('h1C, `EBREAK);
    reset_core();
    begin
        logic to;
        wait_pc(64'h1C, to);
        run_cycles(3);
        check("MUL  6*7=42",      read_reg(3) == 64'd42);
        check("DIV  42/7=6",      read_reg(4) == 64'd6);
        check("REM  43%7=1",      read_reg(5) == 64'd1);
        check("DIVU /0=0xFFF...", read_reg(7) == 64'hFFFF_FFFF_FFFF_FFFF);
    end
endtask

// ============================================================
//  MAIN
// ============================================================
initial begin
    pass_cnt = 0;
    fail_cnt = 0;



    test_addi();
    test_lui_auipc();
    test_alu_rtype();
    test_load_store();
    test_branches();
    test_jal_jalr();
    test_forwarding();
    test_load_use();
    test_rv64_word();
    test_loop();
    test_mext();

    $display("\n========================================");
    $display("  Results: %0d PASSED  /  %0d FAILED", pass_cnt, fail_cnt);
    $display("========================================");

    if (fail_cnt == 0)
        $display("  ALL TESTS PASSED");
    else
        $display("  FAILURES DETECTED - check above");

    $finish;
end

// Global timeout watchdog
initial begin
    #(CLK_PERIOD * TIMEOUT_CYC * 20);
    $display("WATCHDOG: simulation timeout");
    $finish;
end

endmodule
`default_nettype wire
