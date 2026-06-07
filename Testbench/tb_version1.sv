`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 16/05/2026 09:56:42 AM
// Design Name: 
// Module Name: tb_debug
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

`timescale 1ns/1ps


module tb_debug;

logic clk = 0;
logic rst_n;
always #5 clk = ~clk;

logic [63:0] imem_addr;
logic        imem_req;
logic [31:0] imem_rdata;
logic        imem_ack, imem_err;
logic [63:0] dmem_addr, dmem_wdata;
logic [7:0]  dmem_strb;
logic        dmem_req, dmem_we;
logic [63:0] dmem_rdata;
logic        dmem_ack, dmem_err;
logic [63:0] debug_pc;

logic [7:0] mem [4096];

always_comb begin
    imem_ack   = imem_req;
    imem_err   = 1'b0;
    imem_rdata = 32'h0000_006F; // JAL x0,0 default
    if (imem_req) begin
        automatic int b = imem_addr[11:0];
        imem_rdata = {mem[b+3], mem[b+2], mem[b+1], mem[b]};
    end
end

always_ff @(posedge clk) begin
    dmem_ack   <= dmem_req;
    dmem_err   <= 1'b0;
    dmem_rdata <= 64'h0;
    if (dmem_req) begin
        automatic int b = dmem_addr[11:0];
        if (!dmem_we)
            dmem_rdata <= {mem[b+7],mem[b+6],mem[b+5],mem[b+4],
                           mem[b+3],mem[b+2],mem[b+1],mem[b]};
        else
            for (int i = 0; i < 8; i++)
                if (dmem_strb[i]) mem[b+i] <= dmem_wdata[i*8+:8];
    end
end

riscv_core #(.RESET_ADDR(64'h0), .HARTID(0)) dut (
    .clk(clk), .rst_n(rst_n),
    .imem_addr(imem_addr), .imem_req(imem_req),
    .imem_rdata(imem_rdata), .imem_ack(imem_ack), .imem_err(imem_err),
    .dmem_addr(dmem_addr), .dmem_wdata(dmem_wdata), .dmem_strb(dmem_strb),
    .dmem_req(dmem_req), .dmem_we(dmem_we),
    .dmem_rdata(dmem_rdata), .dmem_ack(dmem_ack), .dmem_err(dmem_err),
    .irq_m_external(1'b0), .irq_m_timer(1'b0),
    .irq_m_software(1'b0), .irq_s_external(1'b0),
    .debug_pc(debug_pc)
);

task write_instr(input int addr, input logic [31:0] instr);
    mem[addr+0] = instr[7:0];  mem[addr+1] = instr[15:8];
    mem[addr+2] = instr[23:16]; mem[addr+3] = instr[31:24];
endtask

function automatic [63:0] read_reg(input int r);
    return dut.regfile[r];
endfunction

initial begin
    logic [63:0] r1, r2, r3;
    for (int i = 0; i < 4096; i++) mem[i] = 8'h0;

    write_instr('h00, 32'h00500093);  // ADDI x1,x0,5
    write_instr('h04, 32'h00308113);  // ADDI x2,x1,3
    write_instr('h08, 32'hFFE10193);  // ADDI x3,x2,-2
    write_instr('h0C, 32'h0000006F);  // JAL x0,0

    $display("Memory loaded OK");

    // Proper reset: hold for 10 cycles
    rst_n = 0;
    repeat(10) @(posedge clk);
    @(negedge clk);  // release on negedge so DUT sees it before next posedge
    rst_n = 1;
    $display("Reset released at %0t ns", $time/1000);

    // Trace 40 cycles
    $display("\n  Cyc |   PC   | if_id_instr | wb_en | wb_rd | wb_data          | x1       | x2       | x3");
    for (int i = 0; i < 40; i++) begin
        @(posedge clk);
        #1; // small delay so FF outputs have settled
        r1 = read_reg(1); r2 = read_reg(2); r3 = read_reg(3);
        $display("  %3d | %6h |  %08h   |   %b   |  x%02d  | %016h | %08h | %08h | %08h",
            i, debug_pc[31:0], dut.if_id_instr,
            dut.wb_en, dut.wb_rd, dut.wb_data,
            r1[31:0], r2[31:0], r3[31:0]);
    end

    $display("\nFinal register values:");
    $display("  x1=%016h  (expect 0000000000000005)", read_reg(1));
    $display("  x2=%016h  (expect 0000000000000008)", read_reg(2));
    $display("  x3=%016h  (expect 0000000000000006)", read_reg(3));
    $display("  PC=%016h  (expect 000000000000000c)", debug_pc);

    // Also dump key pipeline internal signals
    $display("\nPipeline state dump:");
    $display("  stall_if       = %b", dut.stall_if);
    $display("  stall_id       = %b", dut.stall_id);
    $display("  flush_ex       = %b", dut.flush_ex);
    $display("  flush_id       = %b", dut.flush_id);
    $display("  load_use_hzd   = %b", dut.load_use_hazard);
    $display("  trap_valid     = %b", dut.trap_valid);
    $display("  if_id_valid    = %b", dut.if_id_valid);
    $display("  id_ex_valid    = %b", dut.id_ex_valid);
    $display("  ex_mem_valid   = %b", dut.ex_mem_valid);
    $display("  mem_wb_valid   = %b", dut.mem_wb_valid);
    $display("  id_ex_ctrl.reg_write = %b", dut.id_ex_ctrl.reg_write);
    $display("  ex_mem_ctrl.reg_write= %b", dut.ex_mem_ctrl.reg_write);
    $display("  mem_wb_ctrl.reg_write= %b", dut.mem_wb_ctrl.reg_write);

    $finish;
end

initial begin #100000; $display("TIMEOUT"); $finish; end

endmodule
`default_nettype wire