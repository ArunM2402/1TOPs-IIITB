// ============================================================
//  rvc_expand.sv  -  RVC (Compressed) instruction expander
//  RV64C → RV64I/M equivalent 32-bit instructions
//  XSIM-safe: no local variable declarations inside always_comb
// ============================================================
`timescale 1ns/1ps


module rvc_expand (
    input  logic [31:0] instr_raw,
    input  logic [63:0] pc,
    output logic [31:0] instr32,
    output logic        is_rvc,
    output logic        illegal_rvc
);

logic [15:0] c;
assign c = instr_raw[15:0];
assign is_rvc = (instr_raw[1:0] != 2'b11);

// CL/CS register: rp(f) = {2'b01, f} = x8..x15
// Inline expansion below uses {2'b01, c[X:Y]} directly

// Module-level intermediates (XSIM requires these outside always_comb)
logic [11:0] imm12;
logic [19:0] imm20;
logic [20:1] imm21;
logic [12:1] imm13;
logic [5:0]  shamt6;
logic [6:0]  imm7hi;
logic [4:0]  imm5lo;
logic [4:0]  rp1, rp2, rpd;
logic        sign12;   // c[12] as explicit 1-bit for replication (XSIM safe)
assign sign12 = c[12];

// Register decode helpers
assign rp1  = {2'b01, c[9:7]};   // rs1' in CL/CS/CB
assign rp2  = {2'b01, c[4:2]};   // rs2' in CL/CS
assign rpd  = {2'b01, c[9:7]};   // rd' same as rs1' for CA/CB

always_comb begin
    instr32     = instr_raw;
    illegal_rvc = 1'b0;
    imm12  = 12'h0;
    imm20  = 20'h0;
    imm21  = 20'h0;
    imm13  = 12'h0;
    shamt6 = 6'h0;
    imm7hi = 7'h0;
    imm5lo = 5'h0;

    if (is_rvc) begin
        case (c[1:0])

        // ── Quadrant 0 ─────────────────────────────────────
        2'b00: begin
            case (c[15:13])
                // C.ADDI4SPN: ADDI rd',x2,nzuimm
                3'b000: begin
                    imm12 = {2'b0, c[10:7], c[12:11], c[5], c[6], 2'b00};
                    if (imm12 == 12'h0) illegal_rvc = 1'b1;
                    else instr32 = {imm12, 5'd2, 3'b000, rp2, 7'b001_0011};
                end
                3'b001: illegal_rvc = 1'b1; // C.FLD (no FP)
                // C.LW: LW rd',off(rs1')
                3'b010: begin
                    imm12 = {5'b0, c[5], c[12:10], c[6], 2'b00};
                    instr32 = {imm12, rp1, 3'b010, rp2, 7'b000_0011};
                end
                // C.LD: LD rd',off(rs1')
                3'b011: begin
                    imm12 = {4'b0, c[6:5], c[12:10], 3'b000};
                    instr32 = {imm12, rp1, 3'b011, rp2, 7'b000_0011};
                end
                3'b100: illegal_rvc = 1'b1;
                3'b101: illegal_rvc = 1'b1; // C.FSD (no FP)
                // C.SW: SW rs2',off(rs1')
                3'b110: begin
                    imm12 = {5'b0, c[5], c[12:10], c[6], 2'b00};
                    instr32 = {imm12[11:5], rp2, rp1, 3'b010, imm12[4:0], 7'b010_0011};
                end
                // C.SD: SD rs2',off(rs1')
                3'b111: begin
                    imm12 = {4'b0, c[6:5], c[12:10], 3'b000};
                    instr32 = {imm12[11:5], rp2, rp1, 3'b011, imm12[4:0], 7'b010_0011};
                end
                default: illegal_rvc = 1'b1;
            endcase
        end

        // ── Quadrant 1 ─────────────────────────────────────
        2'b01: begin
            case (c[15:13])
                // C.ADDI: ADDI rd,rd,nzimm
                3'b000: begin
                    imm12 = {{6{sign12}}, sign12, c[6:2]};
                    instr32 = {imm12, c[11:7], 3'b000, c[11:7], 7'b001_0011};
                end
                // C.ADDIW: ADDIW rd,rd,imm (RV64)
                3'b001: begin
                    imm12 = {{6{sign12}}, sign12, c[6:2]};
                    if (c[11:7] == 5'h0) illegal_rvc = 1'b1;
                    else instr32 = {imm12, c[11:7], 3'b000, c[11:7], 7'b001_1011};
                end
                // C.LI: ADDI rd,x0,imm
                3'b010: begin
                    imm12 = {{6{sign12}}, sign12, c[6:2]};
                    instr32 = {imm12, 5'h0, 3'b000, c[11:7], 7'b001_0011};
                end
                // C.ADDI16SP / C.LUI
                3'b011: begin
                    if (c[11:7] == 5'd2) begin
                        imm12 = {{2{sign12}}, sign12, c[4:3], c[5], c[2], c[6], 4'b0000};
                        if (imm12 == 12'h0) illegal_rvc = 1'b1;
                        else instr32 = {imm12, 5'd2, 3'b000, 5'd2, 7'b001_0011};
                    end else begin
                        imm20 = {{14{sign12}}, sign12, c[6:2]};
                        if (imm20 == 20'h0) illegal_rvc = 1'b1;
                        else instr32 = {imm20, c[11:7], 7'b011_0111};
                    end
                end
                // C.SRLI/SRAI/ANDI + C.SUB/XOR/OR/AND/SUBW/ADDW
                3'b100: begin
                    shamt6 = {c[12], c[6:2]};
                    case (c[11:10])
                        2'b00: instr32 = {1'b0, shamt6, rp1, 3'b101, rp1, 7'b001_0011};
                        2'b01: instr32 = {1'b1, shamt6, rp1, 3'b101, rp1, 7'b001_0011};
                        2'b10: begin
                            imm12 = {{6{sign12}}, sign12, c[6:2]};
                            instr32 = {imm12, rp1, 3'b111, rp1, 7'b001_0011};
                        end
                        2'b11: begin
                            case ({c[12], c[6:5]})
                                3'b000: instr32={7'b010_0000,rp2,rp1,3'b000,rp1,7'b011_0011}; // SUB
                                3'b001: instr32={7'b000_0000,rp2,rp1,3'b100,rp1,7'b011_0011}; // XOR
                                3'b010: instr32={7'b000_0000,rp2,rp1,3'b110,rp1,7'b011_0011}; // OR
                                3'b011: instr32={7'b000_0000,rp2,rp1,3'b111,rp1,7'b011_0011}; // AND
                                3'b100: instr32={7'b010_0000,rp2,rp1,3'b000,rp1,7'b011_1011}; // SUBW
                                3'b101: instr32={7'b000_0000,rp2,rp1,3'b000,rp1,7'b011_1011}; // ADDW
                                default: illegal_rvc = 1'b1;
                            endcase
                        end
                    endcase
                end
                // C.J: JAL x0,offset
                3'b101: begin
                    imm21 = {c[12],c[8],c[10:9],c[6],c[7],c[2],c[11],c[5:3],1'b0};
                    instr32 = {imm21[20],imm21[10:1],imm21[11],{8{imm21[20]}},5'h0,7'b110_1111};
                end
                // C.BEQZ: BEQ rs1',x0,offset
                3'b110: begin
                    imm13 = {c[12],c[6:5],c[2],c[11:10],c[4:3],1'b0};
                    instr32 = {imm13[12],imm13[10:5],5'h0,rp1,3'b000,imm13[4:1],imm13[11],7'b110_0011};
                end
                // C.BNEZ: BNE rs1',x0,offset
                3'b111: begin
                    imm13 = {c[12],c[6:5],c[2],c[11:10],c[4:3],1'b0};
                    instr32 = {imm13[12],imm13[10:5],5'h0,rp1,3'b001,imm13[4:1],imm13[11],7'b110_0011};
                end
                default: illegal_rvc = 1'b1;
            endcase
        end

        // ── Quadrant 2 ─────────────────────────────────────
        2'b10: begin
            case (c[15:13])
                // C.SLLI: SLLI rd,rd,shamt
                3'b000: begin
                    shamt6 = {c[12], c[6:2]};
                    instr32 = {1'b0, shamt6, c[11:7], 3'b001, c[11:7], 7'b001_0011};
                end
                3'b001: illegal_rvc = 1'b1; // C.FLDSP (no FP)
                // C.LWSP: LW rd,off(x2)
                3'b010: begin
                    imm12 = {4'b0, c[3:2], c[12], c[6:4], 2'b00};
                    if (c[11:7]==5'h0) illegal_rvc=1'b1;
                    else instr32 = {imm12, 5'd2, 3'b010, c[11:7], 7'b000_0011};
                end
                // C.LDSP: LD rd,off(x2)
                3'b011: begin
                    imm12 = {3'b0, c[4:2], c[12], c[6:5], 3'b000};
                    if (c[11:7]==5'h0) illegal_rvc=1'b1;
                    else instr32 = {imm12, 5'd2, 3'b011, c[11:7], 7'b000_0011};
                end
                // C.JR/MV/EBREAK/JALR/ADD
                3'b100: begin
                    if (!c[12]) begin
                        if (c[6:2]==5'h0) begin // C.JR
                            if (c[11:7]==5'h0) illegal_rvc=1'b1;
                            else instr32={12'h0,c[11:7],3'b000,5'h0,7'b110_0111};
                        end else begin // C.MV: ADD rd,x0,rs2
                            instr32={7'b000_0000,c[6:2],5'h0,3'b000,c[11:7],7'b011_0011};
                        end
                    end else begin
                        if (c[11:7]==5'h0 && c[6:2]==5'h0) // C.EBREAK
                            instr32 = 32'h00100073;
                        else if (c[6:2]==5'h0) // C.JALR: JALR x1,0(rs1)
                            instr32={12'h0,c[11:7],3'b000,5'd1,7'b110_0111};
                        else // C.ADD: ADD rd,rd,rs2
                            instr32={7'b000_0000,c[6:2],c[11:7],3'b000,c[11:7],7'b011_0011};
                    end
                end
                3'b101: illegal_rvc = 1'b1; // C.FSDSP (no FP)
                // C.SWSP: SW rs2,off(x2)
                3'b110: begin
                    imm12 = {4'b0, c[8:7], c[12:9], 2'b00};
                    instr32 = {imm12[11:5], c[6:2], 5'd2, 3'b010, imm12[4:0], 7'b010_0011};
                end
                // C.SDSP: SD rs2,off(x2)
                3'b111: begin
                    imm12 = {3'b0, c[9:7], c[12:10], 3'b000};
                    instr32 = {imm12[11:5], c[6:2], 5'd2, 3'b011, imm12[4:0], 7'b010_0011};
                end
                default: illegal_rvc = 1'b1;
            endcase
        end

        default: instr32 = instr_raw; // 32-bit, no expansion

        endcase
    end // is_rvc
end

endmodule
`default_nettype wire