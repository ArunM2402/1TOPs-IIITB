// ============================================================
//  boot_rom.sv  —  4KB Boot ROM  (IIITB 1TOPs SoC)
//
//  Default content (simulation):
//    LUI  a1, 0x82000   → a1 = 0x8200_0000  (FDT address)
//    ADDI a0, x0, 0     → a0 = 0             (HARTID = 0)
//    LUI  x1, 0x80000   → x1 = 0x8000_0000  (OpenSBI entry)
//    JALR x0, 0(x1)     → jump to OpenSBI
//
//  For real firmware: uncomment $readmemh line.
//  For FPGA: replace initial block with synthesis ROM or SPI flash.
//
//  a0/a1 must be set here because OpenSBI fw_jump reads them
//  from registers, not memory.
// ============================================================
`timescale 1ns/1ps
`default_nettype none

module boot_rom #(
    parameter ROM_WORDS = 512   // 512 × 64-bit = 4KB
)(
    input  logic        clk,
    input  logic [11:0] addr,   // byte address (12-bit = 4KB)
    input  logic        req,
    output logic [63:0] rdata,
    output logic        ack
);

logic [63:0] rom [ROM_WORDS];

initial begin
    // Fill with NOPs first
    for (int i = 0; i < ROM_WORDS; i++) rom[i] = 64'h0000_0013_0000_0013;

    // Boot sequence at offset 0:
    // Word 0: ADDI a0,x0,0 (upper) | LUI a1,0x82000 (lower)
    rom[0] = 64'h0000_0513_8200_05B7;
    // Word 1: JALR x0,0(x1) (upper) | LUI x1,0x80000 (lower)
    rom[1] = 64'h0000_8067_8000_00B7;

    // For real OpenSBI: override entire ROM with firmware hex
    // $readmemh("opensbi_boot.hex", rom);
    //
    // For Linux boot: load three images into DRAM from testbench:
    //   $readmemh("opensbi.hex", dram, 0);          // → phys 0x8000_0000
    //   $readmemh("kernel.hex",  dram, 'h4000);     // → phys 0x8020_0000
    //   $readmemh("fdt.hex",     dram, 'h40000);    // → phys 0x8200_0000
end

// Single-cycle ROM read
always_ff @(posedge clk) begin
    ack   <= req;
    rdata <= rom[addr[11:3]];  // 64-bit word addressed by bits [11:3]
end

endmodule
`default_nettype wire
