// ============================================================
//  soc_top.sv  -  Linux-capable SoC  (QEMU virt-compatible)
//
//  Memory map:
//  0x0000_0000 - 0x0000_FFFF  Boot ROM  (64 KB, reset vector)
//  0x0200_0000 - 0x0200_FFFF  CLINT
//  0x0C00_0000 - 0x0FFF_FFFF  PLIC
//  0x1000_0000 - 0x1000_00FF  UART 16550
//  0x8000_0000 - 0x8FFF_FFFF  DRAM (256 MB)
//
//  Reset address: 0x8000_0000  (OpenSBI entry point)
//  Fixes vs old version:
//  - typedef enum moved to package to avoid XSIM issues
//  - dmem_rdata/ack mux uses unique priority (no multiple drivers)
//  - imem_err driven correctly (single driver)
//  - Boot ROM uses separate imem/dmem rdata ports
//  - DRAM arbiter handles all three requestors cleanly
// ============================================================
`timescale 1ns/1ps


module soc_top #(
    parameter int unsigned DRAM_SIZE = 32'h1000_0000,  // 256 MB
    parameter int unsigned BOOT_SIZE = 32'h0001_0000   // 64 KB
)(
    input  logic        clk,
    input  logic        rst_n,
    input  logic        rtc_tick,   // slow RTC tick for CLINT mtime

    // UART serial
    input  logic        uart_rx,
    output logic        uart_tx,

    // Debug
    output logic [63:0] debug_pc
);

// ============================================================
//  Core wires
// ============================================================
logic [63:0] imem_addr, dmem_addr, ptw_addr;
logic        imem_req,  dmem_req,  ptw_req;
logic [31:0] imem_rdata;
logic [63:0] dmem_rdata, ptw_rdata;
logic        imem_ack,  dmem_ack,  ptw_ack;
logic        imem_err,  dmem_err;
logic [63:0] dmem_wdata;
logic [7:0]  dmem_strb;
logic        dmem_we;
logic        irq_m_ext, irq_m_timer, irq_m_sw;
logic [0:0]  clint_msip, clint_mtip;

assign irq_m_timer = clint_mtip[0];
assign irq_m_sw    = clint_msip[0];

// ============================================================
//  RISC-V Core
// ============================================================
riscv_core #(
    .RESET_ADDR(64'h8000_0000),
    .HARTID    (64'h0)
) u_core (
    .clk            (clk),
    .rst_n          (rst_n),
    .imem_addr      (imem_addr),
    .imem_req       (imem_req),
    .imem_rdata     (imem_rdata),
    .imem_ack       (imem_ack),
    .imem_err       (imem_err),
    .dmem_addr      (dmem_addr),
    .dmem_wdata     (dmem_wdata),
    .dmem_strb      (dmem_strb),
    .dmem_req       (dmem_req),
    .dmem_we        (dmem_we),
    .dmem_rdata     (dmem_rdata),
    .dmem_ack       (dmem_ack),
    .dmem_err       (dmem_err),
    .ptw_addr       (ptw_addr),
    .ptw_req        (ptw_req),
    .ptw_rdata      (ptw_rdata),
    .ptw_ack        (ptw_ack),
    .irq_m_external (irq_m_ext),
    .irq_m_timer    (irq_m_timer),
    .irq_m_software (irq_m_sw),
    .irq_s_external (1'b0),
    .debug_pc       (debug_pc)
);

// ============================================================
//  Address decode
// ============================================================
localparam [63:0]
    BOOT_BASE  = 64'h0000_0000,
    BOOT_MASK  = 64'h0000_FFFF,
    CLINT_BASE = 64'h0200_0000,
    CLINT_MASK = 64'h0200_FFFF,
    PLIC_BASE  = 64'h0C00_0000,
    PLIC_MASK  = 64'h0FFF_FFFF,
    UART_BASE  = 64'h1000_0000,
    UART_MASK  = 64'h1000_00FF,
    DRAM_BASE  = 64'h8000_0000,
    DRAM_MASK  = 64'h8FFF_FFFF;

function automatic logic addr_hit(input [63:0] a, base, mask);
    addr_hit = ((a & ~(mask ^ base)) == base);
endfunction

// Instruction fetch decode
logic imem_sel_boot, imem_sel_dram;
assign imem_sel_boot = addr_hit(imem_addr, BOOT_BASE, BOOT_MASK);
assign imem_sel_dram = addr_hit(imem_addr, DRAM_BASE, DRAM_MASK);

// Data decode
logic dmem_sel_boot, dmem_sel_dram, dmem_sel_clint,
      dmem_sel_plic, dmem_sel_uart;
assign dmem_sel_boot  = addr_hit(dmem_addr, BOOT_BASE,  BOOT_MASK);
assign dmem_sel_dram  = addr_hit(dmem_addr, DRAM_BASE,  DRAM_MASK);
assign dmem_sel_clint = addr_hit(dmem_addr, CLINT_BASE, CLINT_MASK);
assign dmem_sel_plic  = addr_hit(dmem_addr, PLIC_BASE,  PLIC_MASK);
assign dmem_sel_uart  = addr_hit(dmem_addr, UART_BASE,  UART_MASK);

// PTW always goes to DRAM
logic ptw_sel_dram;
assign ptw_sel_dram = addr_hit(ptw_addr, DRAM_BASE, DRAM_MASK);

// ============================================================
//  DRAM + arbiter  (PTW > IMEM > DMEM priority)
//  Use plain localparam states - no typedef enum (XSIM safe)
// ============================================================
localparam [1:0] ARB_IDLE = 2'b00,
                 ARB_PTW  = 2'b01,
                 ARB_IMEM = 2'b10,
                 ARB_DMEM = 2'b11;

logic [1:0]  arb_st;
logic [63:0] dram_addr_in;
logic [63:0] dram_wdata_in;
logic [7:0]  dram_strb_in;
logic        dram_we_in, dram_req_in;
logic [63:0] dram_rdata_out;
logic        dram_ack_out;

dram_model #(.SIZE(DRAM_SIZE)) u_dram (
    .clk   (clk),
    .addr  (dram_addr_in[27:0]),
    .wdata (dram_wdata_in),
    .strb  (dram_strb_in),
    .req   (dram_req_in),
    .we    (dram_we_in),
    .rdata (dram_rdata_out),
    .ack   (dram_ack_out)
);

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) arb_st <= ARB_IDLE;
    else case (arb_st)
        ARB_IDLE: begin
            if      (ptw_req  && ptw_sel_dram)  arb_st <= ARB_PTW;
            else if (imem_req && imem_sel_dram)  arb_st <= ARB_IMEM;
            else if (dmem_req && dmem_sel_dram)  arb_st <= ARB_DMEM;
        end
        ARB_PTW:  if (dram_ack_out) arb_st <= ARB_IDLE;
        ARB_IMEM: if (dram_ack_out) arb_st <= ARB_IDLE;
        ARB_DMEM: if (dram_ack_out) arb_st <= ARB_IDLE;
        default:  arb_st <= ARB_IDLE;
    endcase
end

// DRAM mux
always_comb begin
    dram_addr_in  = 64'h0;
    dram_wdata_in = 64'h0;
    dram_strb_in  = 8'h0;
    dram_we_in    = 1'b0;
    dram_req_in   = 1'b0;
    case (arb_st)
        ARB_PTW: begin
            dram_addr_in = ptw_addr  - DRAM_BASE;
            dram_req_in  = 1'b1;
        end
        ARB_IMEM: begin
            dram_addr_in = imem_addr - DRAM_BASE;
            dram_req_in  = 1'b1;
        end
        ARB_DMEM: begin
            dram_addr_in  = dmem_addr - DRAM_BASE;
            dram_wdata_in = dmem_wdata;
            dram_strb_in  = dmem_strb;
            dram_we_in    = dmem_we;
            dram_req_in   = 1'b1;
        end
        default: begin
            // Combinational grant for first-cycle hits (no contention)
            if (ptw_req && ptw_sel_dram) begin
                dram_addr_in = ptw_addr  - DRAM_BASE;
                dram_req_in  = 1'b1;
            end else if (imem_req && imem_sel_dram) begin
                dram_addr_in = imem_addr - DRAM_BASE;
                dram_req_in  = 1'b1;
            end else if (dmem_req && dmem_sel_dram) begin
                dram_addr_in  = dmem_addr - DRAM_BASE;
                dram_wdata_in = dmem_wdata;
                dram_strb_in  = dmem_strb;
                dram_we_in    = dmem_we;
                dram_req_in   = 1'b1;
            end
        end
    endcase
end

// PTW response
assign ptw_rdata = dram_rdata_out;
assign ptw_ack   = (arb_st == ARB_PTW  || (arb_st == ARB_IDLE && ptw_req  && ptw_sel_dram))
                   && dram_ack_out;

// ============================================================
//  Boot ROM
// ============================================================
logic [63:0] boot_rdata_i, boot_rdata_d;
logic        boot_ack_i,   boot_ack_d;

boot_rom u_boot_rom_i (
    .clk   (clk),
    .addr  (imem_addr[15:0]),
    .req   (imem_req & imem_sel_boot),
    .rdata (boot_rdata_i),
    .ack   (boot_ack_i)
);

boot_rom u_boot_rom_d (
    .clk   (clk),
    .addr  (dmem_addr[15:0]),
    .req   (dmem_req & dmem_sel_boot & ~dmem_we),
    .rdata (boot_rdata_d),
    .ack   (boot_ack_d)
);

// ============================================================
//  CLINT
// ============================================================
logic [63:0] clint_rdata;
logic        clint_ack;

clint #(.HARTS(1)) u_clint (
    .clk      (clk),
    .rst_n    (rst_n),
    .rtc_tick (rtc_tick),
    .addr     (dmem_addr),
    .wdata    (dmem_wdata),
    .strb     (dmem_strb),
    .req      (dmem_req & dmem_sel_clint),
    .we       (dmem_we),
    .rdata    (clint_rdata),
    .ack      (clint_ack),
    .msip     (clint_msip),
    .mtip     (clint_mtip)
);

// ============================================================
//  PLIC
// ============================================================
logic [31:0] plic_rdata;
logic        plic_ack;
logic [1:0]  plic_eip;

plic #(.NSOURCES(32), .NCONTEXTS(2)) u_plic (
    .clk         (clk),
    .rst_n       (rst_n),
    .irq_sources (32'h0),
    .addr        (dmem_addr[27:0]),
    .wdata       (dmem_wdata[31:0]),
    .req         (dmem_req & dmem_sel_plic),
    .we          (dmem_we),
    .rdata       (plic_rdata),
    .ack         (plic_ack),
    .eip         (plic_eip)
);
assign irq_m_ext = plic_eip[0];

// ============================================================
//  UART
// ============================================================
logic [7:0] uart_rdata;
logic       uart_ack;

uart_16550 u_uart (
    .clk   (clk),
    .rst_n (rst_n),
    .addr  (dmem_addr[2:0]),
    .wdata (dmem_wdata[7:0]),
    .req   (dmem_req & dmem_sel_uart),
    .we    (dmem_we),
    .rdata (uart_rdata),
    .ack   (uart_ack),
    .tx    (uart_tx),
    .rx    (uart_rx)
);

// ============================================================
//  Response mux - single driver using priority
// ============================================================
always_comb begin
    // IMEM response
    imem_rdata = 32'h0000_0013; // NOP default
    imem_ack   = 1'b0;
    imem_err   = 1'b0;
    if (imem_sel_boot) begin
        imem_rdata = boot_rdata_i[31:0];
        imem_ack   = boot_ack_i;
    end else if (imem_sel_dram) begin
        imem_rdata = dram_rdata_out[31:0];
        imem_ack   = (arb_st == ARB_IMEM || (arb_st == ARB_IDLE && imem_req && imem_sel_dram))
                     && dram_ack_out;
    end else if (imem_req) begin
        imem_err = 1'b1;
        imem_ack = 1'b1;
    end
end

always_comb begin
    // DMEM response
    dmem_rdata = 64'h0;
    dmem_ack   = 1'b0;
    dmem_err   = 1'b0;
    if (dmem_sel_dram) begin
        dmem_rdata = dram_rdata_out;
        dmem_ack   = (arb_st == ARB_DMEM || (arb_st == ARB_IDLE && dmem_req && dmem_sel_dram))
                     && dram_ack_out;
    end else if (dmem_sel_boot) begin
        dmem_rdata = boot_rdata_d;
        dmem_ack   = boot_ack_d | (dmem_we & dmem_sel_boot); // writes to ROM ack but no-op
    end else if (dmem_sel_clint) begin
        dmem_rdata = clint_rdata;
        dmem_ack   = clint_ack;
    end else if (dmem_sel_plic) begin
        dmem_rdata = {32'h0, plic_rdata};
        dmem_ack   = plic_ack;
    end else if (dmem_sel_uart) begin
        dmem_rdata = {56'h0, uart_rdata};
        dmem_ack   = uart_ack;
    end else if (dmem_req) begin
        dmem_err = 1'b1;
        dmem_ack = 1'b1;
    end
end

endmodule
`default_nettype wire