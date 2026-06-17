// ============================================================
//  boot_rom.sv  -  64KB read-only boot ROM
//  Default content: jump to DRAM base (0x8000_0000)
//  Override with $readmemh for real firmware
// ============================================================


module boot_rom (
    input  logic        clk,
    input  logic [15:0] addr,   // byte address
    input  logic        req,
    output logic [63:0] rdata,
    output logic        ack
);

// 8K x 64-bit = 64 KB
logic [63:0] rom [8192];

// Default: AUIPC x1, 0 + JALR x0, 0x7FFFF(x1) to jump to 0x8000_0000
// from address 0x0000_0000:
//   auipc x1, 0x80000  -> x1 = 0 + 0x80000000 = 0x80000000
//   jalr  x0, 0(x1)    -> PC = 0x80000000
// auipc x1, 0x80000 = 0x800000B7 (imm[31:12]=0x80000, rd=x1, op=AUIPC)
// jalr x0, 0(x1)    = 0x00008067 (imm=0, rs1=x1, rd=x0, f3=0, op=JALR)
initial begin
    for (int i = 0; i < 8192; i++) rom[i] = 64'h0000_8067_8000_00B7;
    //                                             jalr x0,0(x1) | auipc x1,0x80000
    // Override with: $readmemh("opensbi.hex", rom);
end

// Task for testbench to write ROM content
task automatic write_word(input int unsigned byte_addr, input logic [31:0] v);
    automatic int unsigned widx = byte_addr >> 3;
    automatic int unsigned boff = byte_addr & 4;
    if (boff == 0) rom[widx][31:0]  = v;
    else           rom[widx][63:32] = v;
endtask

always_ff @(posedge clk) begin
    ack   <= req;
    rdata <= rom[addr[15:3]];
end

endmodule
`default_nettype wire