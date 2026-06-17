// ============================================================
//  tb_riscv_core.sv  -  Complete self-checking testbench
//  RV64IMAC + Zicsr  20 tests
//  XSIM / Vivado 2023.1 compatible
//  Key: go() waits at negedge after cycles to avoid FF timing race
// ============================================================
`timescale 1ns/1ps


module tb_riscv_core;

localparam CLK_HALF   = 5;
localparam MEM_SIZE   = 65536;

logic clk = 0;
logic rst_n;
always #CLK_HALF clk = ~clk;

logic [63:0] imem_addr, dmem_addr, ptw_addr;
logic        imem_req,  dmem_req,  ptw_req;
logic [31:0] imem_rdata;
logic [63:0] dmem_rdata, ptw_rdata;
logic        imem_ack, dmem_ack, ptw_ack, imem_err, dmem_err;
logic [63:0] dmem_wdata;
logic [7:0]  dmem_strb;
logic        dmem_we;
logic        irq_m_ext, irq_m_timer, irq_m_sw, irq_s_ext;
logic [63:0] debug_pc;

logic [7:0] mem [MEM_SIZE];

// Instruction fetch - combinational, 1-cycle
always_comb begin
    imem_ack   = imem_req;
    imem_err   = 1'b0;
    imem_rdata = 32'h0000_0013; // NOP default
    if (imem_req) begin
        automatic int b = imem_addr[$clog2(MEM_SIZE)-1:0];
        imem_rdata = {mem[b+3], mem[b+2], mem[b+1], mem[b]};
    end
end

// Data memory - combinational read (8-byte aligned), clocked write
always_comb begin
    dmem_ack   = dmem_req;
    dmem_err   = 1'b0;
    dmem_rdata = 64'h0;
    if (dmem_req && !dmem_we) begin
        automatic int b = {dmem_addr[$clog2(MEM_SIZE)-1:3], 3'b000};
        dmem_rdata = {mem[b+7],mem[b+6],mem[b+5],mem[b+4],
                      mem[b+3],mem[b+2],mem[b+1],mem[b]};
    end
end
always_ff @(posedge clk) begin
    if (dmem_req && dmem_we) begin
        automatic int b = dmem_addr[$clog2(MEM_SIZE)-1:0];
        for (int i = 0; i < 8; i++)
            if (dmem_strb[i]) mem[b+i] <= dmem_wdata[i*8+:8];
    end
end

assign ptw_rdata = 64'h0;
assign ptw_ack   = 1'b0;

riscv_core #(.RESET_ADDR(64'h0), .HARTID(64'h0)) dut (
    .clk(clk), .rst_n(rst_n),
    .imem_addr(imem_addr), .imem_req(imem_req),
    .imem_rdata(imem_rdata), .imem_ack(imem_ack), .imem_err(imem_err),
    .dmem_addr(dmem_addr), .dmem_wdata(dmem_wdata), .dmem_strb(dmem_strb),
    .dmem_req(dmem_req), .dmem_we(dmem_we),
    .dmem_rdata(dmem_rdata), .dmem_ack(dmem_ack), .dmem_err(dmem_err),
    .ptw_addr(ptw_addr), .ptw_req(ptw_req),
    .ptw_rdata(ptw_rdata), .ptw_ack(ptw_ack),
    .irq_m_external(irq_m_ext), .irq_m_timer(irq_m_timer),
    .irq_m_software(irq_m_sw),  .irq_s_external(irq_s_ext),
    .debug_pc(debug_pc)
);


//  Helpers

task write_instr(input int addr, input logic [31:0] v);
    mem[addr]=v[7:0]; mem[addr+1]=v[15:8]; mem[addr+2]=v[23:16]; mem[addr+3]=v[31:24];
endtask

task write_mem64(input int addr, input logic [63:0] v);
    for (int b=0;b<8;b++) mem[addr+b]=v[b*8+:8];
endtask


function [63:0] rr(input int r);
    return dut.regfile[r];
endfunction

task clear_mem();
    for (int i=0;i<MEM_SIZE;i++) mem[i]=8'h0;
endtask


task go(input int n);
    rst_n=0; irq_m_ext=0; irq_m_timer=0; irq_m_sw=0; irq_s_ext=0;
    repeat(6) @(posedge clk);
    rst_n=1;
    repeat(n) @(posedge clk);
    @(negedge clk);
endtask

localparam [31:0] HALT = 32'h0000_006F; // JAL x0,0

// ============================================================
//  Instruction encoders
// ============================================================
localparam [6:0]
    OP=7'b011_0011, OP_IMM=7'b001_0011, OP32=7'b011_1011, OPI32=7'b001_1011,
    LOAD=7'b000_0011, STORE=7'b010_0011, BRANCH=7'b110_0011,
    JALR_OP=7'b110_0111, LUI_OP=7'b011_0111, AUIPC_OP=7'b001_0111,
    AMO_OP=7'b010_1111, SYSTEM=7'b111_0011;

function [31:0] R(input [6:0] op,[4:0] rd,[2:0] f3,[4:0] rs1,[4:0] rs2,[6:0] f7);
    R={f7,rs2,rs1,f3,rd,op}; endfunction
function [31:0] I(input [6:0] op,[4:0] rd,[2:0] f3,[4:0] rs1,[11:0] imm);
    I={imm,rs1,f3,rd,op}; endfunction
function [31:0] S(input [6:0] op,[2:0] f3,[4:0] rs1,[4:0] rs2,[11:0] imm);
    S={imm[11:5],rs2,rs1,f3,imm[4:0],op}; endfunction
function [31:0] B(input [2:0] f3,[4:0] rs1,[4:0] rs2,[12:1] off);
    B={off[12],off[10:5],rs2,rs1,f3,off[4:1],off[11],BRANCH}; endfunction
function [31:0] U(input [6:0] op,[4:0] rd,[31:12] imm);
    U={imm,rd,op}; endfunction
function [31:0] J(input [4:0] rd,[20:1] off);
    J={off[20],off[10:1],off[11],off[19:12],rd,7'b110_1111}; endfunction
function [31:0] CSR(input [4:0] rd,[2:0] f3,[4:0] rs1,[11:0] csr);
    CSR=I(SYSTEM,rd,f3,rs1,csr); endfunction
function [31:0] AMO(input [4:0] f5,[4:0] rd,[2:0] f3,[4:0] rs1,[4:0] rs2);
    AMO={f5,2'b00,rs2,rs1,f3,rd,AMO_OP}; endfunction

`define ADDI(rd,rs1,imm) I(OP_IMM,rd,3'b000,rs1,imm)
`define ADD(rd,rs1,rs2)  R(OP,rd,3'b000,rs1,rs2,7'h00)
`define SUB(rd,rs1,rs2)  R(OP,rd,3'b000,rs1,rs2,7'h20)

// ============================================================
//  Bookkeeping
// ============================================================
int pass_cnt=0, fail_cnt=0;

task chk(input string name, input logic [63:0] got, exp);
    if (got===exp) begin $display("  PASS  %s",name); pass_cnt++; end
    else begin $display("  FAIL  %s  got=%016h  exp=%016h",name,got,exp); fail_cnt++; end
endtask

// ============================================================
//  TEST 1 - ADDI
// ============================================================
task test_addi();
    $display("\n[TEST 1] ADDI / register file");
    clear_mem();
    write_instr('h00, `ADDI(5'd1,5'd0,12'd5));
    write_instr('h04, `ADDI(5'd2,5'd1,12'd3));
    write_instr('h08, `ADDI(5'd3,5'd2,12'hFFE));
    write_instr('h0C, HALT);
    go(25);
    chk("x1=5",rr(1),64'd5); chk("x2=8",rr(2),64'd8);
    chk("x3=6",rr(3),64'd6); chk("x0=0",rr(0),64'd0);
endtask

// ============================================================
//  TEST 2 - LUI / AUIPC
// ============================================================
task test_lui_auipc();
    $display("\n[TEST 2] LUI / AUIPC");
    clear_mem();
    write_instr('h00, U(LUI_OP,   5'd1, 20'hABCDE));
    write_instr('h04, U(AUIPC_OP, 5'd2, 20'h00001));
    write_instr('h08, HALT);
    go(20);
    chk("LUI  x1=sign-ext",rr(1),64'hFFFF_FFFF_ABCDE000);
    chk("AUIPC x2=0x1004", rr(2),64'h1004);
endtask

// ============================================================
//  TEST 3 - ALU R-type
// ============================================================
task test_alu_rtype();
    $display("\n[TEST 3] ALU R-type");
    clear_mem();
    write_instr('h00, `ADDI(5'd1,5'd0,12'd10));
    write_instr('h04, `ADDI(5'd2,5'd0,12'd3));
    write_instr('h08, `ADD (5'd3,5'd1,5'd2));
    write_instr('h0C, `SUB (5'd4,5'd1,5'd2));
    write_instr('h10, R(OP,5'd5, 3'b111,5'd1,5'd2,7'h00));
    write_instr('h14, R(OP,5'd6, 3'b110,5'd1,5'd2,7'h00));
    write_instr('h18, R(OP,5'd7, 3'b100,5'd1,5'd2,7'h00));
    write_instr('h1C, R(OP,5'd8, 3'b001,5'd1,5'd2,7'h00));
    write_instr('h20, R(OP,5'd9, 3'b101,5'd1,5'd2,7'h00));
    write_instr('h24, R(OP,5'd10,3'b010,5'd2,5'd1,7'h00));
    write_instr('h28, `ADDI(5'd11,5'd0,12'hFF8));
    write_instr('h2C, `ADDI(5'd12,5'd0,12'd2));
    write_instr('h30, R(OP,5'd13,3'b101,5'd11,5'd12,7'h20));
    write_instr('h34, HALT);
    go(40);
    chk("ADD  13",rr(3), 64'd13);  chk("SUB  7", rr(4), 64'd7);
    chk("AND  2", rr(5), 64'd2);   chk("OR   11",rr(6), 64'd11);
    chk("XOR  9", rr(7), 64'd9);   chk("SLL  80",rr(8), 64'd80);
    chk("SRL  1", rr(9), 64'd1);   chk("SLT  1", rr(10),64'd1);
    chk("SRA -2", rr(13),64'hFFFF_FFFF_FFFF_FFFE);
endtask

// ============================================================
//  TEST 4 - Load / Store
// ============================================================
task test_load_store();
    $display("\n[TEST 4] Load / Store");
    clear_mem();
    write_mem64('h200, 64'hDEAD_BEEF_1234_5678);
    write_instr('h00, `ADDI(5'd1,5'd0,12'h200));
    write_instr('h04, I(LOAD,5'd2,3'b011,5'd1,12'h0));
    write_instr('h08, I(LOAD,5'd3,3'b010,5'd1,12'h0));
    write_instr('h0C, I(LOAD,5'd4,3'b001,5'd1,12'h0));
    write_instr('h10, I(LOAD,5'd5,3'b000,5'd1,12'h0));
    write_instr('h14, I(LOAD,5'd6,3'b100,5'd1,12'h7));
    write_instr('h18, S(STORE,3'b010,5'd1,5'd3,12'h10));
    write_instr('h1C, I(LOAD,5'd7,3'b011,5'd1,12'h10));
    write_instr('h20, HALT);
    go(40);
    chk("LD  64b",  rr(2),64'hDEAD_BEEF_1234_5678);
    chk("LW  sign", rr(3),64'h0000_0000_1234_5678);
    chk("LH  sign", rr(4),64'h0000_0000_0000_5678);
    chk("LB  sign", rr(5),64'h0000_0000_0000_0078);
    chk("LBU zero", rr(6),64'h0000_0000_0000_00DE);
    chk("SW/LD",    rr(7),64'h0000_0000_1234_5678);
endtask

// ============================================================
//  TEST 5 - Branches
//  Uses memory polling to avoid XSIM hierarchical ref timing
// ============================================================
task test_branches();
    $display("\n[TEST 5] Branches");
    clear_mem();
    // Program
    write_instr('h00, `ADDI(5'd1,5'd0,12'd5));
    write_instr('h04, `ADDI(5'd2,5'd0,12'd5));
    write_instr('h08, `ADDI(5'd3,5'd0,12'd3));
    write_instr('h0C, B(3'b000,5'd1,5'd2,12'd4));   // BEQ +8→0x14
    write_instr('h10, `ADDI(5'd9,5'd0,12'hFFF));    // POISON x9
    write_instr('h14, `ADDI(5'd10,5'd0,12'd1));     // x10=1
    write_instr('h18, B(3'b001,5'd1,5'd2,12'd4));   // BNE not taken
    write_instr('h1C, `ADDI(5'd11,5'd0,12'd1));     // x11=1
    write_instr('h20, B(3'b100,5'd3,5'd1,12'd4));   // BLT +8→0x28
    write_instr('h24, `ADDI(5'd8,5'd0,12'hFFF));    // POISON x8
    write_instr('h28, `ADDI(5'd12,5'd0,12'd1));     // x12=1
    write_instr('h2C, B(3'b101,5'd1,5'd3,12'd4));   // BGE +8→0x34
    write_instr('h30, `ADDI(5'd7,5'd0,12'hFFF));    // POISON x7
    write_instr('h34, `ADDI(5'd13,5'd0,12'd1));     // x13=1

    write_instr('h38, `ADDI(5'd30,5'd0,12'h0));
    write_instr('h3C, U(LUI_OP,5'd30,20'h00001));   // x30 = 0x1000
    write_instr('h40, S(STORE,3'b011,5'd30,5'd7, 12'h000)); // x7→0x1000
    write_instr('h44, S(STORE,3'b011,5'd30,5'd8, 12'h008)); // x8→0x1008
    write_instr('h48, S(STORE,3'b011,5'd30,5'd9, 12'h010)); // x9→0x1010
    write_instr('h4C, S(STORE,3'b011,5'd30,5'd10,12'h018)); // x10→0x1018
    write_instr('h50, S(STORE,3'b011,5'd30,5'd11,12'h020)); // x11→0x1020
    write_instr('h54, S(STORE,3'b011,5'd30,5'd12,12'h028)); // x12→0x1028
    write_instr('h58, S(STORE,3'b011,5'd30,5'd13,12'h030)); // x13→0x1030
    write_instr('h5C, HALT);
    go(100);

    $display("DEBUG T5: PC=%h x10(reg)=%h x13(reg)=%h",
        debug_pc, rr(10), rr(13));
    $display("DEBUG T5: mem[0x1018]=%h mem[0x1030]=%h",
        {mem['h101F],mem['h101E],mem['h101D],mem['h101C],mem['h101B],mem['h101A],mem['h1019],mem['h1018]},
        {mem['h1037],mem['h1036],mem['h1035],mem['h1034],mem['h1033],mem['h1032],mem['h1031],mem['h1030]});
    chk("BEQ taken  x10=1",
        {mem['h101F],mem['h101E],mem['h101D],mem['h101C],mem['h101B],mem['h101A],mem['h1019],mem['h1018]},
        64'd1);
    chk("BEQ skip   x9=0",
        {mem['h1017],mem['h1016],mem['h1015],mem['h1014],mem['h1013],mem['h1012],mem['h1011],mem['h1010]},
        64'd0);
    chk("BNE fall   x11=1",
        {mem['h1027],mem['h1026],mem['h1025],mem['h1024],mem['h1023],mem['h1022],mem['h1021],mem['h1020]},
        64'd1);
    chk("BLT taken  x12=1",
        {mem['h102F],mem['h102E],mem['h102D],mem['h102C],mem['h102B],mem['h102A],mem['h1029],mem['h1028]},
        64'd1);
    chk("BLT skip   x8=0",
        {mem['h100F],mem['h100E],mem['h100D],mem['h100C],mem['h100B],mem['h100A],mem['h1009],mem['h1008]},
        64'd0);
    chk("BGE taken  x13=1",
        {mem['h1037],mem['h1036],mem['h1035],mem['h1034],mem['h1033],mem['h1032],mem['h1031],mem['h1030]},
        64'd1);
endtask

// ============================================================
//  TEST 6 - JAL
// ============================================================
task test_jal();
    $display("\n[TEST 6] JAL");
    clear_mem();
    write_instr('h00, J(5'd1, 20'd6));   // JAL x1,+12→0x0C (off[20:1]=6 → byte=12)
    write_instr('h04, `ADDI(5'd9,5'd0,12'hFFF));
    write_instr('h08, `ADDI(5'd9,5'd0,12'hFFF));
    write_instr('h0C, `ADDI(5'd2,5'd0,12'd42));
    write_instr('h10, U(LUI_OP,5'd30,20'h00002));   // x30=0x2000
    write_instr('h14, S(STORE,3'b011,5'd30,5'd1,12'h000)); // x1→0x2000
    write_instr('h18, S(STORE,3'b011,5'd30,5'd2,12'h008)); // x2→0x2008
    write_instr('h1C, S(STORE,3'b011,5'd30,5'd9,12'h010)); // x9→0x2010
    write_instr('h20, HALT);
    go(40);
    chk("JAL link x1=4",
        {mem['h2007],mem['h2006],mem['h2005],mem['h2004],mem['h2003],mem['h2002],mem['h2001],mem['h2000]},
        64'h4);
    chk("JAL jump x2=42",
        {mem['h200F],mem['h200E],mem['h200D],mem['h200C],mem['h200B],mem['h200A],mem['h2009],mem['h2008]},
        64'd42);
    chk("JAL skip x9=0",
        {mem['h2017],mem['h2016],mem['h2015],mem['h2014],mem['h2013],mem['h2012],mem['h2011],mem['h2010]},
        64'd0);
endtask

// ============================================================
//  TEST 7 - Forwarding
// ============================================================
task test_forwarding();
    $display("\n[TEST 7] Forwarding");
    clear_mem();
    write_instr('h00, `ADDI(5'd1,5'd0,12'd1));
    write_instr('h04, `ADD (5'd2,5'd1,5'd1));
    write_instr('h08, `ADD (5'd3,5'd2,5'd1));
    write_instr('h0C, `ADD (5'd4,5'd3,5'd2));
    write_instr('h10, `ADD (5'd5,5'd4,5'd3));
    write_instr('h14, HALT);
    go(25);
    chk("x1=1",rr(1),64'd1); chk("x2=2",rr(2),64'd2);
    chk("x3=3",rr(3),64'd3); chk("x4=5",rr(4),64'd5);
    chk("x5=8",rr(5),64'd8);
endtask

// ============================================================
//  TEST 8 - Load-use stall
// ============================================================
task test_load_use();
    $display("\n[TEST 8] Load-Use Stall");
    clear_mem();
    write_mem64('h200, 64'd100);
    write_instr('h00, `ADDI(5'd1,5'd0,12'h200));
    write_instr('h04, I(LOAD,5'd2,3'b011,5'd1,12'h0));
    write_instr('h08, `ADD(5'd3,5'd2,5'd2));
    write_instr('h0C, HALT);
    go(25);
    chk("x2=100",rr(2),64'd100); chk("x3=200",rr(3),64'd200);
endtask

// ============================================================
//  TEST 9 - RV64 *W
// ============================================================
task test_rv64w();
    $display("\n[TEST 9] RV64 *W");
    clear_mem();
    write_instr('h00, I(OPI32,5'd1,3'b000,5'd0,12'd5));
    write_instr('h04, I(OPI32,5'd2,3'b000,5'd0,12'd3));
    write_instr('h08, R(OP32,5'd3,3'b000,5'd1,5'd2,7'h00));
    write_instr('h0C, R(OP32,5'd4,3'b000,5'd1,5'd2,7'h20));
    write_instr('h10, I(OPI32,5'd5,3'b000,5'd0,12'hFFF));
    write_instr('h14, HALT);
    go(25);
    chk("ADDIW x1=5",rr(1),64'd5); chk("ADDIW x2=3",rr(2),64'd3);
    chk("ADDW  x3=8",rr(3),64'd8); chk("SUBW  x4=2",rr(4),64'd2);
    chk("ADDIW x5=-1",rr(5),64'hFFFF_FFFF_FFFF_FFFF);
endtask

// ============================================================
//  TEST 10 - Loop
// ============================================================
task test_loop();
    $display("\n[TEST 10] Loop");
    clear_mem();
    write_instr('h00, `ADDI(5'd1,5'd0,12'd0));
    write_instr('h04, `ADDI(5'd2,5'd0,12'd10));
    write_instr('h08, `ADDI(5'd1,5'd1,12'd1));
    write_instr('h0C, B(3'b001,5'd1,5'd2,12'hFFE));
    write_instr('h10, HALT);
    go(120);
    chk("x1=10",rr(1),64'd10);
endtask

// ============================================================
//  TEST 11 - M-extension
// ============================================================
task test_mext();
    $display("\n[TEST 11] M-extension");
    clear_mem();
    write_instr('h00, `ADDI(5'd1,5'd0,12'd6));
    write_instr('h04, `ADDI(5'd2,5'd0,12'd7));
    write_instr('h08, R(OP,5'd3,3'b000,5'd1,5'd2,7'b000_0001));
    write_instr('h0C, R(OP,5'd4,3'b100,5'd3,5'd2,7'b000_0001));
    write_instr('h10, `ADDI(5'd5,5'd0,12'd43));
    write_instr('h14, R(OP,5'd6,3'b110,5'd5,5'd2,7'b000_0001));
    write_instr('h18, R(OP,5'd7,3'b101,5'd1,5'd0,7'b000_0001));
    write_instr('h1C, HALT);
    go(30);
    chk("MUL 42",rr(3),64'd42); chk("DIV 6",rr(4),64'd6);
    chk("REM 1", rr(6),64'd1);  chk("DIVU /0",rr(7),64'hFFFF_FFFF_FFFF_FFFF);
endtask

// ============================================================
//  TEST 12 - CSR
//  Reads CSR results via CSRRS into registers, stores to mem
// ============================================================
task test_csr();
    $display("\n[TEST 12] CSR");
    clear_mem();
    write_instr('h00, CSR(5'd1,3'b001,5'd0,  12'h340)); // CSRRW  x1=0
    write_instr('h04, `ADDI(5'd2,5'd0,12'hABC));
    write_instr('h08, CSR(5'd3,3'b001,5'd2,  12'h340)); // CSRRW  x3,mscratch←x2
    write_instr('h0C, `ADDI(5'd0,5'd0,12'h0));           // NOP
    write_instr('h10, `ADDI(5'd0,5'd0,12'h0));           // NOP (CSR needs 2 cycles)
    write_instr('h14, CSR(5'd4,3'b010,5'd0,  12'h340)); // CSRRS  x4=mscratch=FABC
    write_instr('h18, CSR(5'd5,3'b011,5'd2,  12'h340)); // CSRRC  x5=FABC, clr mscratch
    write_instr('h1C, `ADDI(5'd0,5'd0,12'h0));           // NOP
    write_instr('h20, CSR(5'd6,3'b010,5'd0,  12'h340)); // CSRRS  x6=0
    write_instr('h24, CSR(5'd7,3'b101,5'd15, 12'h340)); // CSRRWI mscratch=15
    write_instr('h28, `ADDI(5'd0,5'd0,12'h0));           // NOP
    write_instr('h2C, `ADDI(5'd0,5'd0,12'h0));           // NOP
    write_instr('h30, CSR(5'd8,3'b010,5'd0,  12'h340)); // CSRRS  x8=15
    
    write_instr('h34, U(LUI_OP,5'd30,20'h00003));        // x30=0x3000
    write_instr('h38, S(STORE,3'b011,5'd30,5'd1,12'h000));
    write_instr('h3C, S(STORE,3'b011,5'd30,5'd3,12'h008));
    write_instr('h40, S(STORE,3'b011,5'd30,5'd4,12'h010));
    write_instr('h44, S(STORE,3'b011,5'd30,5'd5,12'h018));
    write_instr('h48, S(STORE,3'b011,5'd30,5'd6,12'h020));
    write_instr('h4C, S(STORE,3'b011,5'd30,5'd7,12'h028));
    write_instr('h50, S(STORE,3'b011,5'd30,5'd8,12'h030));
    write_instr('h54, HALT);
    // To verify instruction memory contents
    $display("DEBUG T12 instrs: [0x30]=%08h [0x34]=%08h",
        {mem['h33],mem['h32],mem['h31],mem['h30]},
        {mem['h37],mem['h36],mem['h35],mem['h34]});
    go(80);
    $display("DEBUG T12 regs: x1=%h x2=%h x3=%h x4=%h x8=%h",
        rr(1), rr(2), rr(3), rr(4), rr(8));
    $display("DEBUG T12 CSR:  mscratch=%h mcause=%h",
        dut.u_csr.mscratch, dut.u_csr.mcause);
    $display("DEBUG T12 mem:  [3000]=%h [3008]=%h [3010]=%h [3030]=%h",
        {mem['h3007],mem['h3006],mem['h3005],mem['h3004],mem['h3003],mem['h3002],mem['h3001],mem['h3000]},
        {mem['h300F],mem['h300E],mem['h300D],mem['h300C],mem['h300B],mem['h300A],mem['h3009],mem['h3008]},
        {mem['h3017],mem['h3016],mem['h3015],mem['h3014],mem['h3013],mem['h3012],mem['h3011],mem['h3010]},
        {mem['h3037],mem['h3036],mem['h3035],mem['h3034],mem['h3033],mem['h3032],mem['h3031],mem['h3030]});
    chk("CSRRW  x1=0",   {mem['h3007],mem['h3006],mem['h3005],mem['h3004],mem['h3003],mem['h3002],mem['h3001],mem['h3000]}, 64'h0);
    chk("CSRRW  x3=0",   {mem['h300F],mem['h300E],mem['h300D],mem['h300C],mem['h300B],mem['h300A],mem['h3009],mem['h3008]}, 64'h0);
    chk("CSRRS  x4=FABC",{mem['h3017],mem['h3016],mem['h3015],mem['h3014],mem['h3013],mem['h3012],mem['h3011],mem['h3010]}, 64'hFFFF_FFFF_FFFF_FABC);
    chk("CSRRC  x5=FABC",{mem['h301F],mem['h301E],mem['h301D],mem['h301C],mem['h301B],mem['h301A],mem['h3019],mem['h3018]}, 64'hFFFF_FFFF_FFFF_FABC);
    chk("CSRRS  x6=0",   {mem['h3027],mem['h3026],mem['h3025],mem['h3024],mem['h3023],mem['h3022],mem['h3021],mem['h3020]}, 64'h0);
    chk("CSRRWI x7=0",   {mem['h302F],mem['h302E],mem['h302D],mem['h302C],mem['h302B],mem['h302A],mem['h3029],mem['h3028]}, 64'h0);
    chk("CSRRS  x8=15",  {mem['h3037],mem['h3036],mem['h3035],mem['h3034],mem['h3033],mem['h3032],mem['h3031],mem['h3030]}, 64'hF);
endtask

// ============================================================
//  TEST 13 - ECALL
// ============================================================
task test_ecall();
    $display("\n[TEST 13] ECALL");
    clear_mem();
    write_instr('h100, `ADDI(5'd10,5'd0,12'd99));
    write_instr('h104, HALT);
    write_instr('h00, `ADDI(5'd1,5'd0,12'h100));
    write_instr('h04, CSR(5'd0,3'b001,5'd1,12'h305));
    write_instr('h08, 32'h0000_0073);
    write_instr('h0C, `ADDI(5'd9,5'd0,12'hFFF));
    go(35);
    chk("handler x10=99",rr(10),64'd99);
    chk("poison  x9=0",  rr(9), 64'd0);
    chk("mcause=11",     dut.u_csr.mcause, 64'd11);
    chk("mepc=0x08",     dut.u_csr.mepc,   64'h08);
endtask

// ============================================================
//  TEST 14 - Timer IRQ
//  Handler reads mcause and stores to memory
// ============================================================
task test_timer_irq();
    $display("\n[TEST 14] Timer IRQ");
    clear_mem();
    // Handler at 0x200: use x28 as scratch to avoid ordering ambiguity
    // Step 1: read mcause into x28, store to 0x4000
    // Step 2: write sentinel into x28, store to 0x4008
    write_instr('h200, CSR(5'd28,3'b010,5'd0,12'h342));        // x28=mcause
    write_instr('h204, U(LUI_OP,5'd29,20'h00004));             // x29=0x4000
    write_instr('h208, S(STORE,3'b011,5'd29,5'd28,12'h000));   // mcause→0x4000
    write_instr('h20C, `ADDI(5'd28,5'd0,12'hBEF));             // x28=0xBEF sentinel
    write_instr('h210, S(STORE,3'b011,5'd29,5'd28,12'h008));   // sentinel→0x4008
    write_instr('h214, HALT);
    // Main program:
    write_instr('h00, `ADDI(5'd1,5'd0,12'h200));
    write_instr('h04, CSR(5'd0,3'b001,5'd1,12'h305));           // mtvec=0x200
    write_instr('h08, `ADDI(5'd2,5'd0,12'h080));
    write_instr('h0C, CSR(5'd0,3'b010,5'd2,12'h304));           // mie|=MTIE
    write_instr('h10, CSR(5'd0,3'b110,5'd8,12'h300));           // mstatus|=MIE
    write_instr('h14, `ADDI(5'd3,5'd3,12'd1));                  // spin
    write_instr('h18, B(3'b000,5'd0,5'd0,12'hFFE));             // BEQ x0,x0,-4→0x14
    rst_n=0; irq_m_ext=0; irq_m_timer=0; irq_m_sw=0; irq_s_ext=0;
    repeat(6) @(posedge clk); rst_n=1;
    repeat(25) @(posedge clk);
    irq_m_timer=1;
    repeat(30) @(posedge clk);
    irq_m_timer=0;
    repeat(20) @(posedge clk);
    @(negedge clk);
    
    chk("mcause MTI",
        {mem['h4007],mem['h4006],mem['h4005],mem['h4004],mem['h4003],mem['h4002],mem['h4001],mem['h4000]},
        64'h8000_0000_0000_0007);
    chk("handler ran",
        {mem['h400F],mem['h400E],mem['h400D],mem['h400C],mem['h400B],mem['h400A],mem['h4009],mem['h4008]},
        64'hFFFF_FFFF_FFFF_FBEF);
endtask

// ============================================================
//  TEST 15 - LR/SC
// ============================================================
task test_lr_sc();
    $display("\n[TEST 15] LR/SC");
    clear_mem();
    write_mem64('h300, 64'hCAFE_BABE_1234_5678);
    write_instr('h00, `ADDI(5'd1,5'd0,12'h300));
    write_instr('h04, AMO(5'b00010,5'd2,3'b011,5'd1,5'd0)); // LR.D x2
    write_instr('h08, U(LUI_OP,5'd3,20'hDEADC));
    write_instr('h0C, `ADDI(5'd3,5'd3,12'h0DE));
    write_instr('h10, AMO(5'b00011,5'd4,3'b011,5'd1,5'd3)); // SC.D x4
    write_instr('h14, I(LOAD,5'd5,3'b011,5'd1,12'h0));      // LD x5 back
    write_instr('h18, AMO(5'b00010,5'd6,3'b011,5'd1,5'd0)); // LR.D x6
    write_instr('h1C, S(STORE,3'b011,5'd1,5'd3,12'h00));    // SD to 0x300 clears reservation
    write_instr('h20, AMO(5'b00011,5'd7,3'b011,5'd1,5'd3)); // SC.D x7→fail
    write_instr('h24, HALT);
    go(80);
    chk("LR.D x2=old",rr(2),64'hCAFE_BABE_1234_5678);
    chk("SC.D x4=0",  rr(4),64'h0);
    chk("SC.D mem=x3",rr(5),rr(3));
    chk("SC.D x7=1",  rr(7),64'h1);
endtask

// ============================================================
//  TEST 16 - AMO
// ============================================================
task test_amo();
    $display("\n[TEST 16] AMO");
    clear_mem();
    write_mem64('h400, 64'hA);
    write_instr('h00, `ADDI(5'd1,5'd0,12'h400));
    write_instr('h04, `ADDI(5'd2,5'd0,12'd5));
    write_instr('h08, AMO(5'b00001,5'd3,3'b011,5'd1,5'd2)); // AMOSWAP
    write_instr('h0C, AMO(5'b00000,5'd4,3'b011,5'd1,5'd2)); // AMOADD
    write_instr('h10, AMO(5'b01000,5'd5,3'b011,5'd1,5'd2)); // AMOOR
    write_instr('h14, AMO(5'b01100,5'd6,3'b011,5'd1,5'd2)); // AMOAND
    write_instr('h18, I(LOAD,5'd7,3'b011,5'd1,12'h0));
    write_instr('h1C, HALT);
    go(80);
    chk("AMOSWAP x3=10",rr(3),64'd10);
    chk("AMOADD  x4=5", rr(4),64'd5);
    chk("AMOOR   x5=10",rr(5),64'd10);
    chk("AMOAND  x6=15",rr(6),64'd15);
    chk("mem=5",        rr(7),64'd5);
endtask

// ============================================================
//  TEST 17 - SFENCE.VMA
// ============================================================
task test_sfence();
    $display("\n[TEST 17] SFENCE.VMA");
    clear_mem();
    write_instr('h00, `ADDI(5'd1,5'd0,12'd1));
    write_instr('h04, 32'h1200_0073);
    write_instr('h08, `ADDI(5'd2,5'd0,12'd2));
    write_instr('h0C, HALT);
    go(25);
    chk("x1=1",rr(1),64'd1); chk("x2=2",rr(2),64'd2);
    chk("no trap",dut.u_csr.mcause,64'h0);
endtask

// ============================================================
//  TEST 18 - WFI
// ============================================================
task test_wfi();
    $display("\n[TEST 18] WFI");
    clear_mem();
    write_instr('h00, `ADDI(5'd1,5'd0,12'd1));
    write_instr('h04, 32'h1050_0073);
    write_instr('h08, `ADDI(5'd2,5'd0,12'd2));
    write_instr('h0C, HALT);
    go(25);
    chk("x1=1",rr(1),64'd1); chk("x2=2",rr(2),64'd2);
    chk("no trap",dut.u_csr.mcause,64'h0);
endtask

// ============================================================
//  TEST 19 - FENCE.I
// ============================================================
task test_fencei();
    $display("\n[TEST 19] FENCE.I");
    clear_mem();
    write_instr('h00, `ADDI(5'd1,5'd0,12'd1));
    write_instr('h04, 32'h0000_100F);
    write_instr('h08, `ADDI(5'd2,5'd0,12'd2));
    write_instr('h0C, HALT);
    go(25);
    chk("x1=1",rr(1),64'd1); chk("x2=2",rr(2),64'd2);
endtask

// ============================================================
//  TEST 20 - Load misalign
// ============================================================
task test_misalign();
    $display("\n[TEST 20] Load Misalign");
    clear_mem();
    write_instr('h300, `ADDI(5'd15,5'd0,12'hDEA));
    write_instr('h304, HALT);
    write_instr('h00, `ADDI(5'd1,5'd0,12'h200));
    write_instr('h04, `ADDI(5'd2,5'd0,12'h300));
    write_instr('h08, CSR(5'd0,3'b001,5'd2,12'h305));
    write_instr('h0C, I(LOAD,5'd3,3'b001,5'd1,12'h1));
    write_instr('h10, `ADDI(5'd9,5'd0,12'hFFF));
    go(35);
    chk("handler x15",rr(15),64'hFFFF_FFFF_FFFF_FDEA);
    chk("poison  x9=0",rr(9), 64'h0);
    chk("mcause=4",    dut.u_csr.mcause, 64'h4);
    chk("mepc=0x0C",   dut.u_csr.mepc,   64'h0C);
endtask

// ============================================================
//  MAIN
// ============================================================
initial begin
    $display("============================================");
    $display("  RV64IMAC Core - Self-Checking Testbench  ");
    $display("============================================");
    test_addi();       test_lui_auipc();  test_alu_rtype();
    test_load_store(); test_branches();   test_jal();
    test_forwarding(); test_load_use();   test_rv64w();
    test_loop();       test_mext();       test_csr();
    test_ecall();      test_timer_irq();  test_lr_sc();
    test_amo();        test_sfence();     test_wfi();
    test_fencei();     test_misalign();
    $display("\n============================================");
    $display("  %0d PASSED  /  %0d FAILED", pass_cnt, fail_cnt);
    $display("============================================");
    if (fail_cnt==0) $display("  ALL TESTS PASSED");
    $finish;
end

initial begin #200_000_000; $display("WATCHDOG"); $finish; end

endmodule

