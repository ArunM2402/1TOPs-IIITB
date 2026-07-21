// ============================================================
//  tb_act.sv — RISC-V Architecture Certification Testbench
//  Loads hex from ELF, monitors HTIF tohost, dumps signature
// ============================================================
`timescale 1ns/1ps

module tb_act;

localparam CLK_HALF   = 5;
localparam MEM_SIZE   = 524288;  // 512KB — covers all arch-test ELFs
localparam [63:0] BASE_ADDR = 64'h8000_0000;

logic clk = 0;
always #CLK_HALF clk = ~clk;
logic rst_n;

// ── Core interface ──
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

// ── Memory ──
reg [7:0] mem [0:MEM_SIZE-1];

// ── Plusarg variables ──
reg [256*8-1:0] hex_file;
reg [256*8-1:0] sig_file;
integer tohost_off, sig_start, sig_end;

// ── Instruction fetch (combinational, 1-cycle) ──
reg [31:0] imem_rd_tmp;
always @(*) begin
    imem_ack   = imem_req;
    imem_err   = 1'b0;
    imem_rd_tmp = 32'h0000_0013;
    if (imem_req) begin : ifetch
        integer idx;
        idx = imem_addr - BASE_ADDR;
        if (idx >= 0 && idx < MEM_SIZE - 3)
            imem_rd_tmp = {mem[idx+3], mem[idx+2], mem[idx+1], mem[idx]};
    end
    imem_rdata = imem_rd_tmp;
end

// ── Data read (combinational) ──
reg [63:0] dmem_rd_tmp;
always @(*) begin
    dmem_ack   = dmem_req;
    dmem_err   = 1'b0;
    dmem_rd_tmp = 64'h0;
    if (dmem_req && !dmem_we) begin : dread
        integer idx;
        idx = dmem_addr - BASE_ADDR;
        idx = {idx[31:3], 3'b000};
        if (idx >= 0 && idx < MEM_SIZE - 7)
            dmem_rd_tmp = {mem[idx+7], mem[idx+6], mem[idx+5], mem[idx+4],
                           mem[idx+3], mem[idx+2], mem[idx+1], mem[idx]};
    end
    dmem_rdata = dmem_rd_tmp;
end

// ── Data write (clocked) ──
always @(posedge clk) begin : dwrite
    integer idx, i;
    if (dmem_req && dmem_we) begin
        idx = dmem_addr - BASE_ADDR;
        if (idx >= 0 && idx < MEM_SIZE)
            for (i = 0; i < 8; i = i + 1)
                if (dmem_strb[i] && (idx + i) < MEM_SIZE)
                    mem[idx + i] <= dmem_wdata[i*8 +: 8];
    end
end

// ── PTW (unused for M-mode tests) ──
assign ptw_rdata = 64'h0;
assign ptw_ack   = 1'b0;

// ── DUT ──
riscv_core #(.RESET_ADDR(BASE_ADDR), .HARTID(64'h0)) dut (
    .clk(clk), .rst_n(rst_n),
    .imem_addr(imem_addr),   .imem_req(imem_req),
    .imem_rdata(imem_rdata), .imem_ack(imem_ack), .imem_err(imem_err),
    .dmem_addr(dmem_addr),   .dmem_wdata(dmem_wdata), .dmem_strb(dmem_strb),
    .dmem_req(dmem_req),     .dmem_we(dmem_we),
    .dmem_rdata(dmem_rdata), .dmem_ack(dmem_ack),     .dmem_err(dmem_err),
    .ptw_addr(ptw_addr),     .ptw_req(ptw_req),
    .ptw_rdata(ptw_rdata),   .ptw_ack(ptw_ack),
    .irq_m_external(irq_m_ext),  .irq_m_timer(irq_m_timer),
    .irq_m_software(irq_m_sw),  .irq_s_external(irq_s_ext),
    .debug_pc(debug_pc)
);

// ── HTIF tohost monitor ──
wire [63:0] tohost_val = (tohost_off >= 0 && tohost_off < MEM_SIZE - 7) ?
    {mem[tohost_off+7], mem[tohost_off+6], mem[tohost_off+5], mem[tohost_off+4],
     mem[tohost_off+3], mem[tohost_off+2], mem[tohost_off+1], mem[tohost_off]} :
    64'h0;

// ── Main ──
integer cycle_cnt;
initial begin
    if (!$value$plusargs("HEX_FILE=%s",  hex_file))  begin $display("ERROR: +HEX_FILE= required"); $finish; end
    if (!$value$plusargs("TOHOST=%d",    tohost_off)) begin $display("ERROR: +TOHOST= required");   $finish; end
    if (!$value$plusargs("SIG_START=%d", sig_start))  sig_start = -1;
    if (!$value$plusargs("SIG_END=%d",   sig_end))    sig_end   = -1;
    if (!$value$plusargs("SIG_FILE=%s",  sig_file))   sig_file  = "DUT.signature";

    // Init memory
    for (integer i = 0; i < MEM_SIZE; i = i + 1) mem[i] = 8'h0;
    $readmemh(hex_file, mem);

    // Reset sequence
    irq_m_ext = 0; irq_m_timer = 0; irq_m_sw = 0; irq_s_ext = 0;
    rst_n = 0;
    repeat (10) @(posedge clk);
    rst_n = 1;

    // Run until tohost is written or timeout
    cycle_cnt = 0;
    forever begin
        @(posedge clk);
        cycle_cnt = cycle_cnt + 1;

        // Check HTIF tohost
        if (tohost_val == 64'h1) begin
            $display("HTIF_PASS cycle=%0d", cycle_cnt);
            dump_sig();
            $finish;
        end else if (tohost_val == 64'h3) begin
            $display("HTIF_FAIL cycle=%0d", cycle_cnt);
            dump_sig();
            $finish;
        end else if (tohost_val != 64'h0 && tohost_val[63:32] != 32'h0) begin
            // Console I/O — clear tohost so test can continue
            mem[tohost_off]   = 8'h0; mem[tohost_off+1] = 8'h0;
            mem[tohost_off+2] = 8'h0; mem[tohost_off+3] = 8'h0;
            mem[tohost_off+4] = 8'h0; mem[tohost_off+5] = 8'h0;
            mem[tohost_off+6] = 8'h0; mem[tohost_off+7] = 8'h0;
        end

        // Watchdog: 2M cycles
        if (cycle_cnt > 2000000) begin
            $display("TIMEOUT cycle=%0d pc=%h", cycle_cnt, debug_pc);
            dump_sig();
            $finish;
        end
    end
end

// ── Signature dump ──
task dump_sig;
    integer fd, a;
    if (sig_start >= 0 && sig_end > sig_start) begin
        fd = $fopen(sig_file, "w");
        if (fd) begin
            for (a = sig_start; a < sig_end; a = a + 8)
                $fwrite(fd, "%02h%02h%02h%02h%02h%02h%02h%02h\n",
                    mem[a+7], mem[a+6], mem[a+5], mem[a+4],
                    mem[a+3], mem[a+2], mem[a+1], mem[a]);
            $fclose(fd);
        end
    end
endtask

endmodule
