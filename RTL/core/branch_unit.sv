`timescale 1ns/1ps
// basic branch written rn. now improvisie. 

module branch_unit (
    input  logic [2:0] funct3,
    input  logic       is_branch,
    input  logic       is_jal,
    input  logic       is_jalr,
    input  logic       zero,
    input  logic       lt,
    input  logic       ltu,
    output logic       taken
);

always_comb begin
    taken = 1'b0;
    if (is_jal || is_jalr) begin
        taken = 1'b1;
    end else if (is_branch) begin
      case (funct3)
            3'b000: taken = zero;        // BEQ
            3'b001: taken = !zero;       // BNE
            3'b100: taken = lt;          // BLT
            3'b101: taken = !lt;         // BGE
            3'b110: taken = ltu;         // BLTU
            3'b111: taken = !ltu;        // BGEU
            default: taken = 1'b0;
        endcase
    end
end

endmodule

