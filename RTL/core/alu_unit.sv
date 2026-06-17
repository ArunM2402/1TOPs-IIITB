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

// iscas paper posit modules copied into the folder. integration and testing to be done - VS
`include "riscv_pkg.svh"



module alu_unit (
    input  logic [63:0] op_a,
    input  logic [63:0] op_b,
    input  alu_op_t     alu_op,
    input  logic        word_op,   // RV64 *W: operate on [31:0], sign-extend result
    output logic [63:0] result,
    output logic        zero,
    output logic        lt,
    output logic        ltu
);



logic [63:0] a, b, res64;
logic [31:0] a32, b32;
logic [63:0] res_word;


assign a   = op_a;
assign b   = op_b;
assign a32 = op_a[31:0];
assign b32 = op_b[31:0];


logic [5:0] shamt64;
logic [4:0] shamt32;
assign shamt64 = b[5:0];
assign shamt32 = b[4:0];

logic [127:0] mul_pp;
assign mul_pp = {64'h0, a} * {64'h0, b};  


logic [63:0] div_result, divu_result, rem_result, remu_result;
logic [31:0] divw_result, divuw_result, remw_result, remuw_result;

always_comb begin
    
    if (b == 64'h0) begin
        div_result = 64'hFFFF_FFFF_FFFF_FFFF;
        rem_result = a;
    end else if (a == 64'h8000_0000_0000_0000 && $signed(b) == -64'sd1) begin
        div_result = a;
        rem_result = 64'h0;
    end else begin
        div_result = $signed(a) / $signed(b);
        rem_result = $signed(a) % $signed(b);
    end

    
    if (b == 64'h0) begin
        divu_result = 64'hFFFF_FFFF_FFFF_FFFF;
        remu_result = a;
    end else begin
        divu_result = a / b;
        remu_result = a % b;
    end

    
    if (b32 == 32'h0) begin
        divw_result  = 32'hFFFF_FFFF;
        remw_result  = a32;
    end else if (a32 == 32'h8000_0000 && $signed(b32) == -32'sd1) begin
        divw_result  = a32;
        remw_result  = 32'h0;
    end else begin
        divw_result  = $signed(a32) / $signed(b32);
        remw_result  = $signed(a32) % $signed(b32);
    end

    
    if (b32 == 32'h0) begin
        divuw_result = 32'hFFFF_FFFF;
        remuw_result = a32;
    end else begin
        divuw_result = a32 / b32;
        remuw_result = a32 % b32;
    end
end


always_comb begin
    res64 = '0;
    case (alu_op)
        ALU_ADD:    res64 = a + b;
        ALU_SUB:    res64 = a - b;
        ALU_SLL:    res64 = a << shamt64;
        ALU_SLT:    res64 = ($signed(a) < $signed(b)) ? 64'h1 : 64'h0;
        ALU_SLTU:   res64 = (a < b) ? 64'h1 : 64'h0;
        ALU_XOR:    res64 = a ^ b;
        ALU_SRL:    res64 = a >> shamt64;
        ALU_SRA:    res64 = $signed(a) >>> shamt64;
        ALU_OR:     res64 = a | b;
        ALU_AND:    res64 = a & b;
        ALU_LUI:    res64 = b;
        ALU_MUL:    res64 = mul_pp[63:0];
        ALU_MULH:   res64 = ($signed({1'b0,a}) * $signed({1'b0,b})) >> 64; // signed*signed high
        ALU_MULHSU: res64 = ($signed(a) * $unsigned(b)) >> 64;
        ALU_MULHU:  res64 = mul_pp[127:64];
        ALU_DIV:    res64 = div_result;
        ALU_DIVU:   res64 = divu_result;
        ALU_REM:    res64 = rem_result;
        ALU_REMU:   res64 = remu_result;
        ALU_PASS_B: res64 = b;
        default:    res64 = '0; // catch-all
    endcase
end


logic [31:0] w_add, w_sub, w_sll, w_srl, w_sra, w_mul;
assign w_add = a32 + b32;
assign w_sub = a32 - b32;
assign w_sll = a32 << shamt32;
assign w_srl = a32 >> shamt32;
assign w_sra = $signed(a32) >>> shamt32;
assign w_mul = a32 * b32;

always_comb begin
    res_word = '0;
    case (alu_op)
        ALU_ADD:   res_word = {{32{w_add[31]}}, w_add};
        ALU_SUB:   res_word = {{32{w_sub[31]}}, w_sub};
        ALU_SLL:   res_word = {{32{w_sll[31]}}, w_sll};
        ALU_SRL:   res_word = {32'h0,           w_srl};
        ALU_SRA:   res_word = {{32{w_sra[31]}}, w_sra};
        ALU_MUL:   res_word = {{32{w_mul[31]}}, w_mul};
        ALU_DIV:   res_word = {{32{divw_result[31]}},  divw_result};
        ALU_DIVU:  res_word = {32'h0,                  divuw_result};
        ALU_REM:   res_word = {{32{remw_result[31]}},  remw_result};
        ALU_REMU:  res_word = {32'h0,                  remuw_result};
        default:   res_word = res64;
    endcase
end

assign result = word_op ? res_word : res64;
assign zero   = (result == 64'h0);

assign lt     = $signed(a) < $signed(b);
assign ltu    = a < b;

endmodule

