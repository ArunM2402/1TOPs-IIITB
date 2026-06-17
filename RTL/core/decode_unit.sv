module decode_unit (
    input  logic [31:0]    instr,
    input  logic [63:0]    pc,
    output ctrl_signals_t  ctrl,
    output logic [4:0]     rs1,
    output logic [4:0]     rs2,
    output logic [4:0]     rd,
    output logic [63:0]    imm,
    output logic [2:0]     funct3,
    output logic [6:0]     funct7,
    output logic [6:0]     opcode,
    output logic           illegal
);




assign opcode = instr[6:0];
assign rd     = instr[11:7];
assign funct3 = instr[14:12];
assign rs1    = instr[19:15];
assign rs2    = instr[24:20];
assign funct7 = instr[31:25];


logic [63:0] imm_i, imm_s, imm_b, imm_u, imm_j, imm_csr;

assign imm_i   = {{52{instr[31]}}, instr[31:20]};
assign imm_s   = {{52{instr[31]}}, instr[31:25], instr[11:7]};
assign imm_b   = {{51{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0};
assign imm_u   = {{32{instr[31]}}, instr[31:12], 12'h0};
assign imm_j   = {{43{instr[31]}}, instr[31], instr[19:12], instr[20], instr[30:21], 1'b0};
assign imm_csr = {59'h0, instr[19:15]};  


always_comb begin
   
    ctrl         = '0;
    ctrl.alu_op  = ALU_ADD;
    imm          = imm_i;
    illegal      = 1'b0;

    case (opcode)
        // ------ LUI ------
        OP_LUI: begin
            ctrl.reg_write = 1'b1;
            ctrl.alu_op    = ALU_LUI;
            ctrl.alu_src   = 1'b1;
            imm            = imm_u;
        end

        // ------ AUIPC ------
        OP_AUIPC: begin
            ctrl.reg_write = 1'b1;
            ctrl.auipc     = 1'b1;
            ctrl.alu_op    = ALU_ADD;
            ctrl.alu_src   = 1'b1;
            imm            = imm_u;
        end

        // ------ JAL ------
        OP_JAL: begin
            ctrl.reg_write = 1'b1;
            ctrl.jal       = 1'b1;
            ctrl.alu_op    = ALU_ADD;
            imm            = imm_j;
        end

        // ------ JALR ------
        OP_JALR: begin
            ctrl.reg_write = 1'b1;
            ctrl.jalr      = 1'b1;
            ctrl.alu_src   = 1'b1;
            ctrl.alu_op    = ALU_ADD;
            if (funct3 != 3'b000) illegal = 1'b1;
        end

        // ------ BRANCH ------
        OP_BRANCH: begin
            ctrl.branch    = 1'b1;
            ctrl.alu_src   = 1'b0;
            imm            = imm_b;
            case (funct3)
                3'b000: ctrl.alu_op = ALU_SUB;  // BEQ
                3'b001: ctrl.alu_op = ALU_SUB;  // BNE
                3'b100: ctrl.alu_op = ALU_SLT;  // BLT
                3'b101: ctrl.alu_op = ALU_SLT;  // BGE
                3'b110: ctrl.alu_op = ALU_SLTU; // BLTU
                3'b111: ctrl.alu_op = ALU_SLTU; // BGEU
                default: illegal = 1'b1;
            endcase
        end

        // ------ LOAD ------
        OP_LOAD: begin
            ctrl.reg_write = 1'b1;
            ctrl.mem_read  = 1'b1;
            ctrl.alu_op    = ALU_ADD;
            ctrl.alu_src   = 1'b1;
            ctrl.funct3    = funct3;
            if (funct3 == 3'b111) illegal = 1'b1;
        end

        // ------ STORE ------
        OP_STORE: begin
            ctrl.mem_write = 1'b1;
            ctrl.alu_op    = ALU_ADD;
            ctrl.alu_src   = 1'b1;
            ctrl.funct3    = funct3;
            imm            = imm_s;
            if (funct3[2]) illegal = 1'b1;
        end

        // ------ OP-IMM (64-bit) ------
        OP_OP_IMM: begin
            ctrl.reg_write = 1'b1;
            ctrl.alu_src   = 1'b1;
            decode_alu_imm(funct3, funct7, instr[26], ctrl.alu_op, illegal);
            if (funct3 == 3'b001 || funct3 == 3'b101)
                imm = {58'h0, instr[25:20]};  // shamt6
        end

        // ------ OP (64-bit) ------
        OP_OP: begin
            ctrl.reg_write = 1'b1;
            decode_alu_reg(funct3, funct7, ctrl.alu_op, illegal);
        end

        // ------ OP-IMM-32 (RV64 *W imm) ------
        OP_OP_IMM32: begin
            ctrl.reg_write = 1'b1;
            ctrl.alu_src   = 1'b1;
            ctrl.word_op   = 1'b1;
            decode_alu_imm32(funct3, funct7, ctrl.alu_op, illegal);
            if (funct3 == 3'b001 || funct3 == 3'b101)
                imm = {59'h0, instr[24:20]};  // shamt5
        end

        // ------ OP-32 (RV64 *W) ------
        OP_OP32: begin
            ctrl.reg_write = 1'b1;
            ctrl.word_op   = 1'b1;
            decode_alu_reg32(funct3, funct7, ctrl.alu_op, illegal);
        end

        // ------ MISC-MEM (FENCE) ------
        OP_MISC_MEM: begin
            ctrl.fence = 1'b1;  // NOP functionality modelling
        end

        // ------ AMO (A extension - full) ------
        OP_AMO: begin
            ctrl.reg_write = 1'b1;
            ctrl.amo       = 1'b1;
            ctrl.amo_op    = funct7[6:2];  // funct5
            ctrl.funct3    = funct3;       // .W vs .D
            // LR: read-only, SC+others: read-modify-write
            ctrl.mem_read  = 1'b1;
            ctrl.mem_write = (funct7[6:2] != 5'b00010);  // not LR
            ctrl.alu_op    = ALU_ADD;
            // AMO address = rs1 + 0 (no immediate offset)
            // Set alu_src=1 with imm=0 so op_b=0, not rs2
            ctrl.alu_src   = 1'b1;
            imm            = 64'h0;
        end

        // ------ SYSTEM ------
        OP_SYSTEM: begin
            case (funct3)
                3'b000: begin
                    case (instr[31:7])
                        25'h0000000: ctrl.ecall  = 1'b1;            // ECALL
                        25'h0000100: ctrl.ebreak = 1'b1;            // EBREAK
                        25'h0180000: ctrl.sret   = 1'b1;            // SRET
                        25'h0300000: ctrl.mret   = 1'b1;            // MRET
                        25'h0100000: ctrl.wfi         = 1'b1;  // WFI
                        
                        default: begin
                            
                            if (funct7 == 7'b000_1001)
                                ctrl.sfence_vma = 1'b1;
                            else
                                illegal = 1'b1;
                        end
                    endcase
                end
                3'b001: begin // CSRRW
                    ctrl.reg_write = 1'b1;
                    ctrl.csr_read  = 1'b1;
                    ctrl.csr_op    = CSR_RW;
                    imm            = {{52{instr[31]}}, instr[31:20]};
                end
                3'b010: begin // CSRRS
                    ctrl.reg_write = 1'b1;
                    ctrl.csr_read  = 1'b1;
                    ctrl.csr_op    = CSR_RS;
                    imm            = {{52{instr[31]}}, instr[31:20]};
                end
                3'b011: begin // CSRRC
                    ctrl.reg_write = 1'b1;
                    ctrl.csr_read  = 1'b1;
                    ctrl.csr_op    = CSR_RC;
                    imm            = {{52{instr[31]}}, instr[31:20]};
                end
                3'b101: begin // CSRRWI
                    ctrl.reg_write = 1'b1;
                    ctrl.csr_read  = 1'b1;
                    ctrl.csr_op    = CSR_RW;
                    ctrl.csr_imm   = 1'b1;
                   
                    imm            = {{52{1'b0}}, instr[31:20]};
                end
                3'b110: begin // CSRRSI
                    ctrl.reg_write = 1'b1;
                    ctrl.csr_read  = 1'b1;
                    ctrl.csr_op    = CSR_RS;
                    ctrl.csr_imm   = 1'b1;
                    imm            = {{52{1'b0}}, instr[31:20]};
                end
                3'b111: begin // CSRRCI
                    ctrl.reg_write = 1'b1;
                    ctrl.csr_read  = 1'b1;
                    ctrl.csr_op    = CSR_RC;
                    ctrl.csr_imm   = 1'b1;
                    imm            = {{52{1'b0}}, instr[31:20]};
                end
                default: illegal = 1'b1;
            endcase
        end

        default: begin
            illegal = 1'b1;
        end
    endcase

    if (illegal) ctrl = '0;
    ctrl.illegal = illegal;
end

// ---- Helper tasks ----

task automatic decode_alu_imm(
    input  [2:0]    f3,
    input  [6:0]    f7,
    input           bit26,
    output alu_op_t op,
    output logic    ill
);
    ill = 1'b0;
    case (f3)
        3'b000: op = ALU_ADD;
        3'b001: op = (f7[5]) ? ALU_SLL : ALU_SLL;  // SLLI
        3'b010: op = ALU_SLT;
        3'b011: op = ALU_SLTU;
        3'b100: op = ALU_XOR;
        3'b101: op = f7[5] ? ALU_SRA : ALU_SRL;
        3'b110: op = ALU_OR;
        3'b111: op = ALU_AND;
        default: begin op = ALU_ADD; ill = 1'b1; end
    endcase
endtask

task automatic decode_alu_reg(
    input  [2:0]    f3,
    input  [6:0]    f7,
    output alu_op_t op,
    output logic    ill
);
    ill = 1'b0;
    if (f7 == 7'b000_0001) begin
        // M extension
        case (f3)
            3'b000: op = ALU_MUL;
            3'b001: op = ALU_MULH;
            3'b010: op = ALU_MULHSU;
            3'b011: op = ALU_MULHU;
            3'b100: op = ALU_DIV;
            3'b101: op = ALU_DIVU;
            3'b110: op = ALU_REM;
            3'b111: op = ALU_REMU;
            default: begin op = ALU_ADD; ill = 1'b1; end
        endcase
    end else begin
        case (f3)
            3'b000: op = f7[5] ? ALU_SUB : ALU_ADD;
            3'b001: op = ALU_SLL;
            3'b010: op = ALU_SLT;
            3'b011: op = ALU_SLTU;
            3'b100: op = ALU_XOR;
            3'b101: op = f7[5] ? ALU_SRA : ALU_SRL;
            3'b110: op = ALU_OR;
            3'b111: op = ALU_AND;
            default: begin op = ALU_ADD; ill = 1'b1; end
        endcase
    end
endtask

task automatic decode_alu_imm32(
    input  [2:0]    f3,
    input  [6:0]    f7,
    output alu_op_t op,
    output logic    ill
);
    ill = 1'b0;
    case (f3)
        3'b000: op = ALU_ADD;
        3'b001: op = ALU_SLL;
        3'b101: op = f7[5] ? ALU_SRA : ALU_SRL;
        default: begin op = ALU_ADD; ill = 1'b1; end
    endcase
endtask

task automatic decode_alu_reg32(
    input  [2:0]    f3,
    input  [6:0]    f7,
    output alu_op_t op,
    output logic    ill
);
    ill = 1'b0;
    if (f7 == 7'b000_0001) begin
        case (f3)
            3'b000: op = ALU_MUL;
            3'b100: op = ALU_DIV;
            3'b101: op = ALU_DIVU;
            3'b110: op = ALU_REM;
            3'b111: op = ALU_REMU;
            default: begin op = ALU_ADD; ill = 1'b1; end
        endcase
    end else begin
        case (f3)
            3'b000: op = f7[5] ? ALU_SUB : ALU_ADD;
            3'b001: op = ALU_SLL;
            3'b101: op = f7[5] ? ALU_SRA : ALU_SRL;
            default: begin op = ALU_ADD; ill = 1'b1; end
        endcase
    end
endtask

endmodule

