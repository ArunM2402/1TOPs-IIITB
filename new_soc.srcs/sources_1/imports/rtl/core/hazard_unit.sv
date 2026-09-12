// ============================================================
//  hazard_unit.sv  —  IIITB RV64IMAC
//  Combinational branch flush (fires same cycle as branch in EX)
// ============================================================
`timescale 1ns/1ps
`default_nettype none

module hazard_unit (
    // Load-use
    input  logic [4:0]  id_ex_rd,
    input  logic        id_ex_mem_read,
    input  logic [4:0]  ex_mem_rd,
    input  logic        ex_mem_reg_write,
    input  logic [4:0]  mem_wb_rd,
    input  logic        mem_wb_reg_write,

    input  logic [4:0]  id_rs1,
    input  logic [4:0]  id_rs2,
    input  logic [4:0]  ex_rs1,
    input  logic [4:0]  ex_rs2,

    // Branch — combinational from branch_unit (fires same cycle branch is in EX)
    input  logic        branch_taken,
    input  logic        id_ex_valid,

    // Traps / ERET
    input  logic        trap_valid,
    input  logic        irq_pending,
    input  logic        eret_valid,

    // AMO stall (2-cycle operation)
    input  logic        amo_stall,


    output logic        stall_if,
    output logic        stall_id,
    output logic        flush_if,
    output logic        flush_id,
    output logic        flush_ex,
    output logic        load_use_hazard,
    output logic [1:0]  fwd_a_sel,
    output logic [1:0]  fwd_b_sel
);

assign load_use_hazard = id_ex_mem_read &&
                         ((id_ex_rd == id_rs1 && id_rs1 != 5'h0) ||
                          (id_ex_rd == id_rs2 && id_rs2 != 5'h0));

logic branch_flush;
assign branch_flush = branch_taken & id_ex_valid;

assign stall_if = load_use_hazard | amo_stall;
assign stall_id = load_use_hazard | amo_stall;

assign flush_if = branch_flush | trap_valid | irq_pending | eret_valid;
assign flush_id = branch_flush | trap_valid | irq_pending | eret_valid;
assign flush_ex = branch_flush | load_use_hazard | trap_valid | irq_pending | eret_valid;

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
`default_nettype wire
