//////////////////////////////////////////////////////////////////////////////////
// Company: IIITB
// Engineer: ihs_system11
// 
// Create Date: 16/05/2026 09:56:42 AM
// Design Name: 
// Module Name: 
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


module hazard_unit (
    input  logic [4:0]  id_ex_rd,
    input  logic        id_ex_mem_read,
    input  logic [4:0]  ex_mem_rd,
    input  logic        ex_mem_reg_write,
    input  logic [4:0]  mem_wb_rd,
    input  logic        mem_wb_reg_write,
    input  logic [4:0]  id_rs1,       // if_id_instr[19:15]
    input  logic [4:0]  id_rs2,       // if_id_instr[24:20]
    input  logic [4:0]  ex_rs1,       // id_ex_rs1
    input  logic [4:0]  ex_rs2,       // id_ex_rs2
    input  logic        branch_taken,
    input  logic        ex_mem_valid,
    input  logic        trap_valid,
    input  logic        eret_valid,

    // Outputs
    output logic        stall_if,
    output logic        stall_id,
    output logic        flush_id,
    output logic        flush_ex,
    output logic        load_use_hazard,
    output logic [1:0]  fwd_a_sel,    
    output logic [1:0]  fwd_b_sel
);


assign load_use_hazard = id_ex_mem_read &&
                         ((id_ex_rd == id_rs1 && id_rs1 != 5'h0) ||
                          (id_ex_rd == id_rs2 && id_rs2 != 5'h0));


assign stall_if = load_use_hazard;
assign stall_id = load_use_hazard;

logic branch_flush;
assign branch_flush = branch_taken & ex_mem_valid;
assign flush_ex = load_use_hazard | branch_flush | trap_valid | eret_valid;
assign flush_id = branch_flush | trap_valid | eret_valid;


always_comb begin
    if (ex_mem_reg_write && ex_mem_rd != 5'h0 && ex_mem_rd == ex_rs1)
        fwd_a_sel = 2'b10;   
    else if (mem_wb_reg_write && mem_wb_rd != 5'h0 && mem_wb_rd == ex_rs1)
        fwd_a_sel = 2'b01;   
    else
        fwd_a_sel = 2'b00;   
    if (ex_mem_reg_write && ex_mem_rd != 5'h0 && ex_mem_rd == ex_rs2)
        fwd_b_sel = 2'b10;
    else if (mem_wb_reg_write && mem_wb_rd != 5'h0 && mem_wb_rd == ex_rs2)
        fwd_b_sel = 2'b01;
    else
        fwd_b_sel = 2'b00;
end

endmodule
