`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 05/03/2025 01:08:02 PM
// Design Name: 
// Module Name: posit_mac
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


`timescale 1ns / 1ps


module posit_mac #(parameter N = 12)(
    input clk,
    input  [N-1:0] in1, 
    input  [N-1:0] in2, 
    input  [N-1:0] add_in, 
    input  start,
    output [N-1:0] out,
    output done
    //output[N-1:0] mult_out,
    //input [N:0] add_m
);

// Wires for interconnecting multiplier and adder
wire [N-1:0]  add_out, mult_out;
wire inf_mult, zero_mult, mult_done;
wire inf_add, zero_add, add_done;

// Instantiate Posit Multiplier

posit_mult #(.N(N)) mult_inst (
    .clk(clk),
    .in1_m_kernel(in1), 
    .in2_m_kernel(in2), 
    .start_m(start), 
    .out_m(mult_out), 
    .inf_m(inf_mult), 
    .zero_m(zero_mult), 
    .done_m(mult_done)
);
//// Instantiate Posit Adder

posit_add #(.N(N)) add_inst (
    .clk(clk),
    .in1_svm(mult_out), 
    .in2_svm(add_in), 
    .start(mult_done),  // Adder starts after multiplier is done
    .out(out), 
    .inf(inf_add), 
    .zero(zero_add), 
    .done(add_done)
    //.add_m(add_m)
);
//always @(posedge clk) begin
//$display("in1 = %b, in2 = %b, mult_out =%b, add_in =%b, out = %b",in1, in2, mult_out, add_in, out);
//end
// Final done signal
assign done = add_done;


endmodule