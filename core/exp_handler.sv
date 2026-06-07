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


module exp_handler (
    input  logic        valid,
    input  logic [63:0] pc,
    input  logic [31:0] instr,
    input  logic [1:0]  priv_mode,
    input  logic        csr_illegal,
    input  logic        id_illegal,
    input  logic [63:0] alu_result,  // effective address
    input  logic        is_load,
    input  logic        is_store,
    input  logic [2:0]  funct3,
    input  logic        is_ecall,
    input  logic        is_ebreak,
    output logic        trap_valid,
    output logic [63:0] trap_cause,
    output logic [63:0] trap_tval
);

`include "riscv_pkg.svh"

// Exception codes (mcause, scause)
localparam [63:0]
    EXC_INST_ALIGN     = 64'h0,
    EXC_INST_FAULT     = 64'h1,
    EXC_ILLEGAL_INST   = 64'h2,
    EXC_BREAKPOINT     = 64'h3,
    EXC_LOAD_ALIGN     = 64'h4,
    EXC_LOAD_FAULT     = 64'h5,
    EXC_STORE_ALIGN    = 64'h6,
    EXC_STORE_FAULT    = 64'h7,
    EXC_ECALL_U        = 64'h8,
    EXC_ECALL_S        = 64'h9,
    EXC_ECALL_M        = 64'hB,
    EXC_INST_PAGE      = 64'hC,
    EXC_LOAD_PAGE      = 64'hD,
    EXC_STORE_PAGE     = 64'hF;

// Alignment check helpers
logic load_misalign, store_misalign, pc_misalign;

always_comb begin
    pc_misalign    = pc[1:0] != 2'b00;

    case (funct3[1:0])
        2'b00: begin load_misalign = 1'b0; store_misalign = 1'b0; end
        2'b01: begin
            load_misalign  = alu_result[0];
            store_misalign = alu_result[0];
        end
        2'b10: begin
            load_misalign  = alu_result[1:0] != 2'b00;
            store_misalign = alu_result[1:0] != 2'b00;
        end
        2'b11: begin
            load_misalign  = alu_result[2:0] != 3'b000;
            store_misalign = alu_result[2:0] != 3'b000;
        end
        default: begin load_misalign = 1'b0; store_misalign = 1'b0; end
    endcase
end

always_comb begin
    trap_valid = 1'b0;
    trap_cause = 64'h0;
    trap_tval  = 64'h0;

    if (valid) begin
        if (pc_misalign) begin
            trap_valid = 1'b1;
            trap_cause = EXC_INST_ALIGN;
            trap_tval  = pc;
        end else if (id_illegal || csr_illegal) begin
            trap_valid = 1'b1;
            trap_cause = EXC_ILLEGAL_INST;
            trap_tval  = {32'h0, instr};
        end else if (is_ecall) begin
            trap_valid = 1'b1;
            case (priv_mode)
                PRIV_U: trap_cause = EXC_ECALL_U;
                PRIV_S: trap_cause = EXC_ECALL_S;
                PRIV_M: trap_cause = EXC_ECALL_M;
                default: trap_cause = EXC_ECALL_M;
            endcase
            trap_tval = 64'h0;
        end else if (is_ebreak) begin
            trap_valid = 1'b1;
            trap_cause = EXC_BREAKPOINT;
            trap_tval  = pc;
        end else if (is_load && load_misalign) begin
            trap_valid = 1'b1;
            trap_cause = EXC_LOAD_ALIGN;
            trap_tval  = alu_result;
        end else if (is_store && store_misalign) begin
            trap_valid = 1'b1;
            trap_cause = EXC_STORE_ALIGN;
            trap_tval  = alu_result;
        end
    end
end

endmodule
