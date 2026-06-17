`timescale 1ns/1ps


module tb_trace;

logic clk=0; logic rst_n;
always #5 clk=~clk;

logic [63:0] imem_addr,dmem_addr,ptw_addr;
logic imem_req,dmem_req,ptw_req;
logic [31:0] imem_rdata;
logic [63:0] dmem_rdata,ptw_rdata;
logic imem_ack,dmem_ack,ptw_ack,imem_err,dmem_err;
logic [63:0] dmem_wdata; logic [7:0] dmem_strb; logic dmem_we;
logic [63:0] debug_pc;
logic [7:0] mem [4096];

// Aligned 8-byte read
always_comb begin
    imem_ack=imem_req; imem_err=0; imem_rdata=32'h0000_0013;
    if(imem_req) begin automatic int b=imem_addr[11:0];
        imem_rdata={mem[b+3],mem[b+2],mem[b+1],mem[b]}; end
end
always_comb begin
    dmem_ack=dmem_req; dmem_err=0; dmem_rdata=64'h0;
    if(dmem_req&&!dmem_we) begin
        automatic int b={dmem_addr[11:3],3'b000}; // 8-byte aligned
        dmem_rdata={mem[b+7],mem[b+6],mem[b+5],mem[b+4],mem[b+3],mem[b+2],mem[b+1],mem[b]}; end
end
always_ff @(posedge clk) if(dmem_req&&dmem_we) begin
    automatic int b=dmem_addr[11:0];
    for(int i=0;i<8;i++) if(dmem_strb[i]) mem[b+i]<=dmem_wdata[i*8+:8]; end
assign ptw_rdata=0; assign ptw_ack=0;

riscv_core #(.RESET_ADDR(64'h0),.HARTID(64'h0)) dut(
    .clk(clk),.rst_n(rst_n),
    .imem_addr(imem_addr),.imem_req(imem_req),
    .imem_rdata(imem_rdata),.imem_ack(imem_ack),.imem_err(imem_err),
    .dmem_addr(dmem_addr),.dmem_wdata(dmem_wdata),.dmem_strb(dmem_strb),
    .dmem_req(dmem_req),.dmem_we(dmem_we),
    .dmem_rdata(dmem_rdata),.dmem_ack(dmem_ack),.dmem_err(dmem_err),
    .ptw_addr(ptw_addr),.ptw_req(ptw_req),
    .ptw_rdata(ptw_rdata),.ptw_ack(ptw_ack),
    .irq_m_external(0),.irq_m_timer(0),.irq_m_software(0),.irq_s_external(0),
    .debug_pc(debug_pc));

task wi(input int a, input logic [31:0] v);
    mem[a]=v[7:0];mem[a+1]=v[15:8];mem[a+2]=v[23:16];mem[a+3]=v[31:24]; endtask
task wm(input int a, input logic [63:0] v);
    for(int i=0;i<8;i++) mem[a+i]=v[i*8+:8]; endtask

initial begin
    for(int i=0;i<4096;i++) mem[i]=8'h0;

    // ---- AMO test: AMOSWAP ----
    // mem[0x400] = 10
    wm('h400, 64'hA);
    // x1=0x400, x2=5
    wi('h00, 32'h40000093); // ADDI x1,x0,0x400
    wi('h04, 32'h00500113); // ADDI x2,x0,5
    // AMOSWAP.D x3,(x1),x2 : funct5=00001, rd=x3, f3=011, rs1=x1, rs2=x2
    // {00001,00,x2,x1,011,x3,0101111} = {00001,00,00010,00001,011,00011,0101111}
    wi('h08, 32'h0820B1AF); // AMOSWAP.D x3,(x1),x2
    wi('h0C, 32'h0000B103); // LD x2, 0(x1) - read back mem[0x400]
    wi('h10, 32'h0000006F); // HALT

    rst_n=0; repeat(6) @(posedge clk); rst_n=1;

    $display("Cyc | PC   | ex_mem_v | ex_mem_amo | amo_state | dmem_req | dmem_we | dmem_addr | dmem_rdata      | wb_en | wb_rd | wb_data");
    for(int i=0;i<30;i++) begin
        @(posedge clk); #1;
        $display("%3d | %4h |    %b     |     %b      |    %2b     |    %b     |    %b    | %8h  | %16h | %b | x%02d | %h",
            i, debug_pc[11:0],
            dut.ex_mem_valid, dut.ex_mem_ctrl.amo,
            dut.amo_state,
            dut.dmem_req, dut.dmem_we,
            dut.dmem_addr[11:0],
            dut.dmem_rdata,
            dut.wb_en, dut.wb_rd, dut.wb_data);
    end

    #1;
    $display("\nx1=%h x2=%h x3=%h",dut.regfile[1],dut.regfile[2],dut.regfile[3]);
    $display("Expected: x3=10(old), x2=5(new mem value)");
    $finish;
end
initial begin #5000; $display("TIMEOUT"); $finish; end
endmodule
`default_nettype wire
