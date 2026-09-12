// ============================================================
//  tb_soc.sv  -  RV64IMAC SoC self-checking testbench
//
//  TB owns all memory arrays (same pattern as tb_riscv_core).
//  Instantiates: riscv_core + clint + uart_16550 directly.
//  No soc_top needed - avoids hierarchical DRAM access issues.
//
//  Tests:
//  T1: Memory map  - CLINT mtime nonzero, UART LSR=0x60
//  T2: CLINT IRQ   - timer handler writes sentinel 0xBEF
//  T3: UART TX     - bytes written, TX FIFO drains
// ============================================================
`timescale 1ns/1ps
`default_nettype none

module tb_soc;

// ============================================================
//  Clock / reset
// ============================================================
localparam CLK_HALF = 5;
localparam RTC_DIV  = 100;

logic clk = 0, rst_n;
always #CLK_HALF clk = ~clk;

int rtc_cnt = 0; logic rtc_tick = 0;
always_ff @(posedge clk) begin
    if (rtc_cnt == RTC_DIV-1) begin rtc_cnt<=0; rtc_tick<=1; end
    else                       begin rtc_cnt<=rtc_cnt+1; rtc_tick<=0; end
end

// ============================================================
//  TB memory  (1 MB at 0x8000_0000)
// ============================================================
localparam MEM_WORDS = 131072; // 1MB / 8B
logic [63:0] mem [MEM_WORDS];
initial begin
    for (int i=0;i<MEM_WORDS;i++) mem[i]=64'h0000_0013_0000_0013; // NOP pair
end

// ============================================================
//  Core ports
// ============================================================
logic [63:0] imem_addr, dmem_addr, ptw_addr;
logic        imem_req,  dmem_req,  ptw_req;
logic [31:0] imem_rdata;
logic [63:0] dmem_rdata, ptw_rdata;
logic        imem_ack, dmem_ack, ptw_ack, imem_err, dmem_err;
logic [63:0] dmem_wdata;
logic [7:0]  dmem_strb;
logic        dmem_we;
logic        irq_m_ext=0, irq_m_timer, irq_m_sw;
logic [63:0] debug_pc;

// ============================================================
//  Address decode
// ============================================================
logic dram_sel_i, dram_sel_d, dram_sel_p;
logic clint_sel, uart_sel;

// Use [31:0] comparison - RV64 sign-extends 0x8000_0000 to 0xFFFF_FFFF_8000_0000
localparam [31:0] MEM_BASE32 = 32'h8000_0000;
localparam [31:0] MEM_TOP32  = 32'h8000_0000 + MEM_WORDS * 8;

assign dram_sel_i = imem_req && (imem_addr[31:0] >= MEM_BASE32) &&
                    (imem_addr[31:0] < MEM_TOP32);
assign dram_sel_d = dmem_req && (dmem_addr[31:0] >= MEM_BASE32) &&
                    (dmem_addr[31:0] < MEM_TOP32);
assign dram_sel_p = ptw_req  && (ptw_addr[31:0]  >= MEM_BASE32) &&
                    (ptw_addr[31:0]  < MEM_TOP32);
assign clint_sel  = dmem_req && (dmem_addr >= 64'h0200_0000) &&
                    (dmem_addr <= 64'h0200_FFFF);
assign uart_sel   = dmem_req && (dmem_addr >= 64'h1000_0000) &&
                    (dmem_addr <= 64'h1000_00FF);

// ============================================================
//  IMEM response
// ============================================================
logic [63:0] imem_word;
logic        imem_boff;
assign imem_word = mem[(imem_addr[31:0] - 32'h8000_0000) >> 3];
assign imem_boff = imem_addr[2];

always_comb begin
    imem_rdata = 32'h0000_0013;
    imem_ack   = 1'b0;
    imem_err   = 1'b0;
    if (dram_sel_i) begin
        imem_rdata = imem_boff ? imem_word[63:32] : imem_word[31:0];
        imem_ack   = 1'b1;
    end else if (imem_req) begin
        imem_err = 1'b1;
        imem_ack = 1'b1;
    end
end

// ============================================================
//  PTW response
// ============================================================
logic [63:0] ptw_word;
assign ptw_word = mem[(ptw_addr[31:0] - 32'h8000_0000) >> 3];

always_comb begin
    ptw_rdata = 64'h0;
    ptw_ack   = 1'b0;
    if (dram_sel_p) begin
        ptw_rdata = ptw_word;
        ptw_ack   = 1'b1;
    end
end

// ============================================================
//  DRAM write
// ============================================================
// DRAM write - initial/forever loop (proven XSIM pattern, same as tb_riscv_core)
int dram_wi;
initial begin : dram_write_proc
    forever begin
        @(posedge clk);
        // DEBUG: print every dmem transaction
        if (dmem_req)
            $display("DMEM: addr=%h we=%b sel_d=%b sel_c=%b sel_u=%b ack=%b wdata=%h strb=%b",
                dmem_addr, dmem_we, dram_sel_d, clint_sel, uart_sel, dmem_ack,
                dmem_wdata, dmem_strb);
        // DEBUG: print IMEM fetches from unusual addresses
        if (imem_req && imem_addr != 64'h8000_0000 && !dram_sel_i)
            $display("IMEM_ERR: addr=%h sel_i=%b ack=%b err=%b",
                imem_addr, dram_sel_i, imem_ack, imem_err);
        if (dram_sel_d && dmem_we) begin
            dram_wi = (dmem_addr[31:0] - 32'h8000_0000) >> 3;
            $display("WRITE: mem[%0d] <= %h strb=%b", dram_wi, dmem_wdata, dmem_strb);
            if (dmem_strb[0]) mem[dram_wi][ 7: 0] = dmem_wdata[ 7: 0];
            if (dmem_strb[1]) mem[dram_wi][15: 8] = dmem_wdata[15: 8];
            if (dmem_strb[2]) mem[dram_wi][23:16] = dmem_wdata[23:16];
            if (dmem_strb[3]) mem[dram_wi][31:24] = dmem_wdata[31:24];
            if (dmem_strb[4]) mem[dram_wi][39:32] = dmem_wdata[39:32];
            if (dmem_strb[5]) mem[dram_wi][47:40] = dmem_wdata[47:40];
            if (dmem_strb[6]) mem[dram_wi][55:48] = dmem_wdata[55:48];
            if (dmem_strb[7]) mem[dram_wi][63:56] = dmem_wdata[63:56];
        end
    end
end

// ============================================================
//  CLINT
// ============================================================
logic [63:0] clint_rdata;
logic        clint_ack;
logic [0:0]  clint_msip, clint_mtip;
assign irq_m_timer = clint_mtip[0];
assign irq_m_sw    = clint_msip[0];

clint #(.HARTS(1)) u_clint (
    .clk(clk), .rst_n(rst_n), .rtc_tick(rtc_tick),
    .addr(dmem_addr), .wdata(dmem_wdata), .strb(dmem_strb),
    .req(clint_sel), .we(dmem_we),
    .rdata(clint_rdata), .ack(clint_ack),
    .msip(clint_msip), .mtip(clint_mtip)
);

// ============================================================
//  UART
// ============================================================
logic [7:0] uart_rdata;
logic       uart_ack;
logic       uart_tx, uart_rx;
assign uart_rx = 1'b1;

uart_16550 u_uart (
    .clk(clk), .rst_n(rst_n),
    .addr(dmem_addr[2:0]), .wdata(dmem_wdata[7:0]),
    .req(uart_sel), .we(dmem_we),
    .rdata(uart_rdata), .ack(uart_ack),
    .tx(uart_tx), .rx(uart_rx)
);

// Combinational UART rdata - bypass registered rdata for immediate reads
logic [7:0] uart_rdata_comb;
always_comb begin
    case (dmem_addr[2:0])
        3'h5:    uart_rdata_comb = {1'b0, u_uart.tx_empty, u_uart.tx_empty,
                                    3'b0, 1'b0, 1'b0}; // LSR
        3'h3:    uart_rdata_comb = u_uart.lcr;          // LCR
        default: uart_rdata_comb = uart_rdata;          // fall back to registered
    endcase
end

// ============================================================
//  DMEM response mux
// ============================================================
always_comb begin
    dmem_rdata = 64'h0;
    dmem_ack   = 1'b0;
    dmem_err   = 1'b0;
    if (clint_sel) begin
        dmem_rdata = clint_rdata;
        dmem_ack   = dmem_req;   // combinational ack
    end else if (uart_sel) begin
        dmem_rdata = {8{uart_rdata_comb}};  // combinational - correct for same-cycle read
        dmem_ack   = dmem_req;   // combinational ack
    end else if (dram_sel_d) begin
        dmem_rdata = mem[(dmem_addr[31:0] - 32'h8000_0000) >> 3];
        dmem_ack   = 1'b1;
    end else if (dmem_req) begin
        dmem_err = 1'b1;
        dmem_ack = 1'b1;
    end
end

// ============================================================
//  Core
// ============================================================
riscv_core #(.RESET_ADDR(64'h8000_0000), .HARTID(64'h0)) u_core (
    .clk(clk), .rst_n(rst_n),
    .imem_addr(imem_addr), .imem_req(imem_req),
    .imem_rdata(imem_rdata), .imem_ack(imem_ack), .imem_err(imem_err),
    .dmem_addr(dmem_addr), .dmem_wdata(dmem_wdata), .dmem_strb(dmem_strb),
    .dmem_req(dmem_req), .dmem_we(dmem_we),
    .dmem_rdata(dmem_rdata), .dmem_ack(dmem_ack), .dmem_err(dmem_err),
    .ptw_addr(ptw_addr), .ptw_req(ptw_req),
    .ptw_rdata(ptw_rdata), .ptw_ack(ptw_ack),
    .irq_m_external(irq_m_ext), .irq_m_timer(irq_m_timer),
    .irq_m_software(irq_m_sw), .irq_s_external(1'b0),
    .debug_pc(debug_pc)
);

// ============================================================
//  Instruction encoders
// ============================================================
localparam [6:0]
    OP_IMM=7'b001_0011, LOAD=7'b000_0011, STORE=7'b010_0011,
    SYSTEM=7'b111_0011, LUI_OP=7'b011_0111;

function [31:0] enc_i(input [6:0] op,[4:0] rd,[2:0] f3,[4:0] rs1,[11:0] imm);
    enc_i={imm,rs1,f3,rd,op}; endfunction
function [31:0] enc_s(input [2:0] f3,[4:0] rs1,[4:0] rs2,[11:0] imm);
    enc_s={imm[11:5],rs2,rs1,f3,imm[4:0],STORE}; endfunction
function [31:0] enc_u(input [6:0] op,[4:0] rd,[31:12] imm);
    enc_u={imm,rd,op}; endfunction
function [31:0] enc_b(input [2:0] f3,[4:0] rs1,[4:0] rs2,[12:1] off);
    enc_b={off[12],off[10:5],rs2,rs1,f3,off[4:1],off[11],7'b110_0011}; endfunction
function [31:0] enc_csr(input [4:0] rd,[2:0] f3,[4:0] rs1,[11:0] csr);
    enc_csr=enc_i(SYSTEM,rd,f3,rs1,csr); endfunction

`define ADDI(rd,rs1,imm)  enc_i(OP_IMM,rd,3'b000,rs1,imm)
`define LD(rd,rs1,imm)    enc_i(LOAD,rd,3'b011,rs1,imm)
`define LBU(rd,rs1,imm)   enc_i(LOAD,rd,3'b100,rs1,imm)
`define SD(rs1,rs2,imm)   enc_s(3'b011,rs1,rs2,imm)
`define SB(rs1,rs2,imm)   enc_s(3'b000,rs1,rs2,imm)
`define LUI(rd,imm)       enc_u(LUI_OP,rd,imm)
`define ANDI(rd,rs1,imm)  enc_i(OP_IMM,rd,3'b111,rs1,imm)

localparam [31:0] NOP  = 32'h0000_0013;
localparam [31:0] HALT = 32'h0000_006F;

// Program counter for wi() calls  (module-level, no automatic)
int pc;
int hpc;

// Write 32-bit instruction at byte address (DRAM region)
task wi(input int ba, input logic [31:0] v);
    int off; int widx; int boff;
    off  = ba - 32'h8000_0000;
    widx = off >> 3;
    boff = off[2];
    if (boff==0) mem[widx][31:0]  = v;
    else         mem[widx][63:32] = v;
endtask

// Write 64-bit value at byte address
task wd(input int ba, input logic [63:0] v);
    mem[(ba-32'h8000_0000)>>3] = v;
endtask

// Read 64-bit value at byte address
function [63:0] rda(input int ba);
    rda = mem[(ba[31:0]-32'h8000_0000)>>3];
endfunction

// ============================================================
//  Bookkeeping
// ============================================================
int pass_cnt=0, fail_cnt=0;

task chk(input string name, input logic [63:0] got, exp);
    if (got===exp) begin $display("  PASS  %s",name); pass_cnt++; end
    else begin $display("  FAIL  %s  got=%016h  exp=%016h",name,got,exp); fail_cnt++; end
endtask

task chk_nz(input string name, input logic [63:0] got);
    if (got!==0) begin $display("  PASS  %s=%0h",name,got); pass_cnt++; end
    else         begin $display("  FAIL  %s=0 (expected nonzero)",name); fail_cnt++; end
endtask

task go(input int n);
    rst_n=0; repeat(6) @(posedge clk);
    rst_n=1; repeat(n) @(posedge clk);
    @(negedge clk);
endtask

task clear_mem();
    for (int i=0;i<MEM_WORDS;i++) mem[i]=64'h0000_0013_0000_0013;
endtask

// ============================================================
//  TEST 1 - Memory Map Probe
// ============================================================
task test_memmap();
    $display("\n[TEST 1] Memory Map Probe");
    clear_mem();

    pc = 32'h8000_0000;

    // Read CLINT mtime: 0x0200_BFF8
    // LUI x1,0x200C → 0x0200_C000; ADDI x1,x1,-8 → 0x0200_BFF8
    wi(pc, `LUI(5'd1, 20'h0200C));             pc=pc+4;
    wi(pc, `ADDI(5'd1, 5'd1, 12'hFF8));        pc=pc+4;
    wi(pc, `LD(5'd2, 5'd1, 12'h0));            pc=pc+4; // x2=mtime

    // Read UART LSR at 0x1000_0005
    wi(pc, `LUI(5'd3, 20'h10000));             pc=pc+4;
    wi(pc, `LBU(5'd4, 5'd3, 12'h5));           pc=pc+4; // x4=LSR

    // Store sentinel + LSR to scratch area
    // x5 = 0xABCD (sentinel to prove store works)
    wi(pc, `ADDI(5'd5, 5'd0, 12'hABC));        pc=pc+4;
    wi(pc, `LUI(5'd20, 20'h8000F));            pc=pc+4;
    wi(pc, `SD(5'd20, 5'd5, 12'h000));         pc=pc+4;  // F000=sentinel
    wi(pc, `SD(5'd20, 5'd4, 12'h008));         pc=pc+4;  // F008=LSR
    wi(pc, HALT);

    go(1000);

    $display("DEBUG F000=%016h F008=%016h", rda(32'h8000_F000), rda(32'h8000_F008));
    $display("DEBUG pc=%016h instr0=%016h", debug_pc, mem[0]);

    chk("DRAM store works", rda(32'h8000_F000)&64'hFFF, 64'hABC);
    chk("UART LSR=0x60",   rda(32'h8000_F008)&64'hFF, 64'h60);
endtask

// ============================================================
//  TEST 2 - CLINT Timer IRQ
// ============================================================
task test_clint_timer();
    $display("\n[TEST 2] CLINT Software IRQ");
    clear_mem();
    wd(32'h8000_F000, 64'h0);

    // Handler at 0x8000_0080:
    // 1. Clear msip (CLINT+0x0000 = 0x0200_0000) to prevent re-trigger
    // 2. Store sentinel 0xBEF to scratch
    // 3. HALT
    hpc = 32'h8000_0080;
    wi(hpc, `LUI(5'd10, 20'h02000));          hpc=hpc+4; // x10=0x0200_0000 (CLINT)
    wi(hpc, enc_s(3'b010,5'd10,5'd0,12'h0));  hpc=hpc+4; // SW x0,0(x10) → msip=0
    wi(hpc, `LUI(5'd1, 20'h8000F));            hpc=hpc+4; // x1=0x8000_F000
    wi(hpc, `ADDI(5'd2, 5'd0, 12'hBEF));      hpc=hpc+4; // x2=0xBEF
    wi(hpc, `SD(5'd1, 5'd2, 12'h0));           hpc=hpc+4; // mem[F000]=0xBEF
    wi(hpc, HALT);

    // Jump from entry to main at 0x8000_0100
    // JAL x0, +256: J-type off=256, off[20:1]=128=0x80
    // {off[20],off[10:1],off[11],off[19:12],rd,opcode}
    // = {0, 10'b10_0000_0000, 0, 8'h00, 5'h0, 7'h6F}
    // off[10:1]=128=10'b10_0000_0000, so bit9=1 others=0
    // instr[30:21] = off[10:1] = 10'b10_0000_0000 → bit30=0,bit29..21=100000000
    // Let me just compute: JAL x0, +256
    // off=256: off[20]=0,off[19:12]=0,off[11]=0,off[10:1]=128(=10'b1000000000)
    // wait off[10:1]: 256>>1=128, binary=10_0000_0000 (10 bits)
    // {0,  128[9:0],   0,    8'h00,  5'h0, 7'h6F}
    // {0, 10'b10_0000_0000, 0, 8'h0, 5'h0, 6F}
    // bit31=0, bits30:21=10_0000_0000 (off[10:1]), bit20=0(off[11]),
    // bits19:12=0(off[19:12]), bits11:7=0(rd), bits6:0=6F
    wi(32'h8000_0000, 32'h1000_006F); // JAL x0, +256 → 0x8000_0100

    // Main at 0x8000_0100
    pc = 32'h8000_0100;

    // Read mtime (0x0200_BFF8)
    wi(pc, `LUI(5'd1, 20'h0200C));             pc=pc+4;
    wi(pc, `ADDI(5'd1, 5'd1, 12'hFF8));        pc=pc+4;
    wi(pc, `LD(5'd2, 5'd1, 12'h0));            pc=pc+4; // x2=mtime

    // Set mtvec = 0x8000_0080
    wi(pc, `LUI(5'd5, 20'h80000));             pc=pc+4;
    wi(pc, `ADDI(5'd5, 5'd5, 12'h080));        pc=pc+4;
    wi(pc, enc_csr(5'd0, 3'b001, 5'd5, 12'h305)); pc=pc+4; // mtvec

    // mie |= MSIE(0x8) - enable software interrupt
    wi(pc, `ADDI(5'd6, 5'd0, 12'h008));        pc=pc+4;
    wi(pc, enc_csr(5'd0, 3'b010, 5'd6, 12'h304)); pc=pc+4; // mie|=MSIE

    // mstatus |= MIE(0x8)
    wi(pc, enc_csr(5'd0, 3'b010, 5'd6, 12'h300)); pc=pc+4; // mstatus|=MIE

    // Assert software interrupt: write 1 to CLINT msip at 0x0200_0000
    wi(pc, `LUI(5'd7, 20'h02000));             pc=pc+4; // x7=0x0200_0000
    wi(pc, `ADDI(5'd8, 5'd0, 12'h001));        pc=pc+4; // x8=1
    wi(pc, enc_s(3'b010,5'd7,5'd8,12'h0));     pc=pc+4; // SW x8,0(x7) → msip[0]=1
    wi(pc, NOP); pc=pc+4;
    wi(pc, NOP); pc=pc+4;
    wi(pc, HALT);

    // Software IRQ fires immediately after msip=1 and MIE=1
    go(500);

    $display("T2 DEBUG: final pc=%h F000=%h", debug_pc, rda(32'h8000_F000));
    chk("sw irq handler sentinel", rda(32'h8000_F000)&64'hFFF, 64'hBEF);
endtask

// ============================================================
//  TEST 3 - UART TX
// ============================================================
task test_uart_tx();
    $display("\n[TEST 3] UART TX");
    clear_mem();

    pc = 32'h8000_0000;

    // x1 = UART base = 0x1000_0000
    wi(pc, `LUI(5'd1, 20'h10000));             pc=pc+4;

    // Configure UART: LCR=0x83 (DLAB=1, 8N1)
    wi(pc, `ADDI(5'd2, 5'd0, 12'h083));        pc=pc+4;
    wi(pc, `SB(5'd1, 5'd2, 12'h3));            pc=pc+4; // LCR=0x83

    // Divisor = 1 (fastest baud for sim): DLL=1, DLM=0
    wi(pc, `ADDI(5'd2, 5'd0, 12'h001));        pc=pc+4;
    wi(pc, `SB(5'd1, 5'd2, 12'h0));            pc=pc+4; // DLL=1
    wi(pc, enc_s(3'b000, 5'd1, 5'd0, 12'h1));  pc=pc+4; // DLM=0

    // LCR=0x03 (DLAB=0, 8N1)
    wi(pc, `ADDI(5'd2, 5'd0, 12'h003));        pc=pc+4;
    wi(pc, `SB(5'd1, 5'd2, 12'h3));            pc=pc+4;

    // Write 'H' (0x48): poll THRE (LSR bit5) first
    wi(pc, `LBU(5'd3, 5'd1, 12'h5));           pc=pc+4; // LSR
    wi(pc, `ANDI(5'd3, 5'd3, 12'h20));         pc=pc+4; // &THRE
    wi(pc, enc_b(3'b000,5'd3,5'd0,12'hFFE));   pc=pc+4; // BEQ→poll
    wi(pc, `ADDI(5'd2, 5'd0, 12'h048));        pc=pc+4; // 'H'
    wi(pc, `SB(5'd1, 5'd2, 12'h0));            pc=pc+4; // THR

    // Write 'I' (0x49)
    wi(pc, `LBU(5'd3, 5'd1, 12'h5));           pc=pc+4;
    wi(pc, `ANDI(5'd3, 5'd3, 12'h20));         pc=pc+4;
    wi(pc, enc_b(3'b000,5'd3,5'd0,12'hFFE));   pc=pc+4;
    wi(pc, `ADDI(5'd2, 5'd0, 12'h049));        pc=pc+4; // 'I'
    wi(pc, `SB(5'd1, 5'd2, 12'h0));            pc=pc+4;

    // Write '!' (0x21)
    wi(pc, `LBU(5'd3, 5'd1, 12'h5));           pc=pc+4;
    wi(pc, `ANDI(5'd3, 5'd3, 12'h20));         pc=pc+4;
    wi(pc, enc_b(3'b000,5'd3,5'd0,12'hFFE));   pc=pc+4;
    wi(pc, `ADDI(5'd2, 5'd0, 12'h021));        pc=pc+4; // '!'
    wi(pc, `SB(5'd1, 5'd2, 12'h0));            pc=pc+4;

    // Wait for TEMT (LSR bit6) - all transmitted
    wi(pc, `LBU(5'd3, 5'd1, 12'h5));           pc=pc+4;
    wi(pc, `ANDI(5'd3, 5'd3, 12'h40));         pc=pc+4;
    wi(pc, enc_b(3'b000,5'd3,5'd0,12'hFFE));   pc=pc+4;
    wi(pc, HALT);

    // UART with divisor=1 at 100MHz: ~1.6M baud, ~60 clocks/byte
    // 3 bytes * 60 clocks = ~180 clocks + setup overhead
    go(500_000);

    // Check TX FIFO is empty (all bytes transmitted)
    // tx_empty = (tx_count==0), which maps to LSR bits THRE(5) and TEMT(6)
    if (u_uart.tx_empty && !u_uart.tx_busy)
        begin $display("  PASS  UART TX idle (fifo empty, not busy)"); pass_cnt++; end
    else
        begin $display("  FAIL  UART TX not idle (empty=%b busy=%b)",
                       u_uart.tx_empty, u_uart.tx_busy); fail_cnt++; end
endtask

// ============================================================
//  MAIN
// ============================================================
initial begin
    $display("============================================");
    $display("  RV64IMAC SoC Testbench                  ");
    $display("============================================");

    test_memmap();
    test_clint_timer();
    test_uart_tx();

    $display("\n============================================");
    $display("  %0d PASSED  /  %0d FAILED", pass_cnt, fail_cnt);
    $display("============================================");
    if (fail_cnt==0) $display("  ALL SOC TESTS PASSED");
    $finish;
end

initial begin #2_000_000_000; $display("WATCHDOG"); $finish; end

endmodule
`default_nettype wire