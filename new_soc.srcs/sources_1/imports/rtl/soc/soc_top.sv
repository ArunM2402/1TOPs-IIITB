// ============================================================
//  soc_top.sv  -  IIITB 1TOPs SoC  (RV64IMAC)
//
//  Matches block diagram (Figure 1) from SoC Development Plan:
//  Core → AXI-Lite crossbar → {I-SRAM, D-SRAM, MMU, Cache}
//  Peripheral Bus (APB) → {PLIC, BootROM, SPI, GPIO, Timer, UART}
//
//  Memory map (QEMU virt-compatible for OpenSBI/Linux):
//  0x0000_0000 - 0x0000_0FFF  BootROM    (4KB,  read-only)
//  0x0001_0000 - 0x0001_00FF  SPI master (APB)
//  0x0002_0000 - 0x0002_00FF  GPIO       (APB)
//  0x0002_0100 - 0x0002_01FF  Timer      (APB, uses CLINT mtime)
//  0x0200_0000 - 0x0200_FFFF  CLINT      (mtime/mtimecmp/msip)
//  0x0C00_0000 - 0x0FFF_FFFF  PLIC
//  0x1000_0000 - 0x1000_00FF  UART 16550
//  0x1000_0000 - 0x1FFF_FFFF  (peripheral APB space)
//  0x8000_0000 - 0x8000_FFFF  I-SRAM     (64KB, instruction)
//  0x8010_0000 - 0x8010_FFFF  D-SRAM     (64KB, data)
//  0x8000_0000+               DRAM       (64MB, covers OpenSBI+kernel+FDT)
//
//  Reset vector: 0x8000_0000  (OpenSBI FW_JUMP loads here)
//  FDT expected: 0x8200_0000
// ============================================================
`timescale 1ns/1ps


module soc_top #(
    parameter int unsigned DRAM_SIZE  = 32'h0400_0000, // 64 MB (sim, fits OpenSBI+kernel+FDT)
    parameter int unsigned ISRAM_SIZE = 32'h0001_0000, // 64 KB
    parameter int unsigned DSRAM_SIZE = 32'h0001_0000  // 64 KB
)(
    input  logic        clk,
    input  logic        rst_n,
    input  logic        rtc_tick,    // RTC for CLINT mtime (e.g. 1 MHz)

    // UART
    input  logic        uart_rx,
    output logic        uart_tx,

    // SPI (for BootROM/flash)
    output logic        spi_sck,
    output logic        spi_mosi,
    input  logic        spi_miso,
    output logic        spi_csn,

    // GPIO
    inout  wire  [31:0] gpio_pins,

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
logic        gpio_irq;
logic [0:0]  clint_mtip, clint_msip;

assign irq_m_timer = clint_mtip[0];
assign irq_m_sw    = clint_msip[0];

// ============================================================
//  CPU Core
// ============================================================
riscv_core #(
    .RESET_ADDR(64'h8000_0000),
    .HARTID    (64'h0)
) u_core (
    .clk(clk), .rst_n(rst_n),
    .imem_addr(imem_addr), .imem_req(imem_req),
    .imem_rdata(imem_rdata), .imem_ack(imem_ack), .imem_err(imem_err),
    .dmem_addr(dmem_addr), .dmem_wdata(dmem_wdata), .dmem_strb(dmem_strb),
    .dmem_req(dmem_req), .dmem_we(dmem_we),
    .dmem_rdata(dmem_rdata), .dmem_ack(dmem_ack), .dmem_err(dmem_err),
    .ptw_addr(ptw_addr), .ptw_req(ptw_req),
    .ptw_rdata(ptw_rdata), .ptw_ack(ptw_ack),
    .irq_m_external(irq_m_ext), .irq_m_timer(irq_m_timer),
    .irq_m_software(irq_m_sw),  .irq_s_external(1'b0),
    .debug_pc(debug_pc),
    .fence_i(core_fence_i),
    .fence_d(core_fence_d)
);

logic core_fence_i, core_fence_d;

// ============================================================
//  Address decode helper
// ============================================================
function automatic logic addr_in(input [63:0] a, [63:0] base, [63:0] top);
    addr_in = (a >= base) && (a <= top);
endfunction

// IMEM selects
logic isel_isram, isel_dram;
// Use [31:0] to handle sign-extended addresses (e.g. LUI+JALR gives 0xFFFF_FFFF_8000_0000)
assign isel_isram = addr_in({32'h0, imem_addr[31:0]}, 64'h8000_0000, 64'h8000_FFFF);
assign isel_dram  = addr_in({32'h0, imem_addr[31:0]}, 64'h8000_0000, 64'h8000_0000 + DRAM_SIZE - 1);

// DMEM selects
logic dsel_boot, dsel_isram, dsel_dsram, dsel_dram;
logic dsel_clint, dsel_plic, dsel_uart, dsel_spi, dsel_gpio;
assign dsel_boot  = addr_in(dmem_addr, 64'h0000_0000, 64'h0000_0FFF);
assign dsel_isram = addr_in(dmem_addr, 64'h8000_0000, 64'h8000_FFFF);
assign dsel_dsram = addr_in(dmem_addr, 64'h8010_0000, 64'h8010_FFFF);
assign dsel_dram  = addr_in(dmem_addr, 64'h8000_0000, 64'h8000_0000 + DRAM_SIZE - 1);
assign dsel_clint = addr_in(dmem_addr, 64'h0200_0000, 64'h0200_FFFF);
assign dsel_plic  = addr_in(dmem_addr, 64'h0C00_0000, 64'h0FFF_FFFF);
assign dsel_uart  = addr_in(dmem_addr, 64'h1000_0000, 64'h1000_00FF);
assign dsel_spi   = addr_in(dmem_addr, 64'h0001_0000, 64'h0001_00FF);
assign dsel_gpio  = addr_in(dmem_addr, 64'h0002_0000, 64'h0002_00FF);

// PTW always from DRAM
logic psel_dram;
assign psel_dram = addr_in({32'h0, ptw_addr[31:0]}, 64'h8000_0000, 64'h8000_0000 + DRAM_SIZE - 1);

// ============================================================
//  I-SRAM (64KB) - backing store for I-cache
// ============================================================
logic [63:0] isram [ISRAM_SIZE/8];
logic [63:0] isram_rdata_d;  // for CPU data-side reads (bypasses I-cache)

initial begin
    for (int i=0;i<ISRAM_SIZE/8;i++) isram[i]=64'h0000_0013_0000_0013; // NOPs
end

// I-cache mem side: line refill from I-SRAM
logic [63:0] ic_mem_addr;
logic        ic_mem_req;
logic [63:0] ic_mem_rdata;
logic        ic_mem_ack;

// Single-cycle I-SRAM read for I-cache refill (word-by-word)
always_ff @(posedge clk) begin
    ic_mem_ack   <= ic_mem_req;
    ic_mem_rdata <= isram[(ic_mem_addr - 64'h8000_0000) >> 3];
end

// CPU data-side access to I-SRAM (bypass cache - for loads/stores to code region)
always_ff @(posedge clk) begin
    if (dsel_isram && dmem_req && !dmem_we)
        isram_rdata_d <= isram[(dmem_addr - 64'h8000_0000) >> 3];
    if (dsel_isram && dmem_req && dmem_we) begin
        automatic int widx = (dmem_addr - 64'h8000_0000) >> 3;
        for (int b=0;b<8;b++)
            if (dmem_strb[b]) isram[widx][b*8+:8] <= dmem_wdata[b*8+:8];
    end
end

// I-cache instantiation
logic [31:0] ic_cpu_rdata;
logic        ic_cpu_ack;

icache #(.SETS(256)) u_icache (
    .clk      (clk),
    .rst_n    (rst_n),
    .cpu_addr (imem_addr),
    .cpu_req  (imem_req & isel_isram),
    .flush    (core_fence_i),
    .cpu_rdata(ic_cpu_rdata),
    .cpu_ack  (ic_cpu_ack),
    .mem_addr (ic_mem_addr),
    .mem_req  (ic_mem_req),
    .mem_rdata(ic_mem_rdata),
    .mem_ack  (ic_mem_ack)
);

// ============================================================
//  D-SRAM (64KB) - backing store for D-cache
// ============================================================
logic [63:0] dsram [DSRAM_SIZE/8];

initial begin
    for (int i=0;i<DSRAM_SIZE/8;i++) dsram[i]=64'h0;
end

// D-cache mem side
logic [63:0] dc_mem_addr;
logic [63:0] dc_mem_wdata;
logic [7:0]  dc_mem_strb;
logic        dc_mem_req;
logic        dc_mem_we;
logic [63:0] dc_mem_rdata;
logic        dc_mem_ack;

// Single-cycle D-SRAM (1-cycle read + write)
always_ff @(posedge clk) begin
    dc_mem_ack    <= dc_mem_req;
    dc_mem_rdata  <= dsram[(dc_mem_addr - 64'h8010_0000) >> 3];
    if (dc_mem_req && dc_mem_we) begin
        automatic int widx = (dc_mem_addr - 64'h8010_0000) >> 3;
        for (int b=0;b<8;b++)
            if (dc_mem_strb[b]) dsram[widx][b*8+:8] <= dc_mem_wdata[b*8+:8];
    end
end

// D-cache: only covers D-SRAM region. Peripherals + DRAM bypass.
// AMO: bypass via cpu_amo flag (dcache passes through to SRAM directly)
logic [63:0] dc_cpu_rdata;
logic        dc_cpu_ack;
logic        dc_cpu_err;

dcache #(.SETS(256)) u_dcache (
    .clk      (clk),
    .rst_n    (rst_n),
    .cpu_addr (dmem_addr),
    .cpu_wdata(dmem_wdata),
    .cpu_strb (dmem_strb),
    .cpu_req  (dmem_req & dsel_dsram),
    .cpu_we   (dmem_we),
    .cpu_amo  (1'b0),   // AMO bypasses to DRAM not D-SRAM; D-SRAM AMOs treated normal
    .cpu_rdata(dc_cpu_rdata),
    .cpu_ack  (dc_cpu_ack),
    .cpu_err  (dc_cpu_err),
    .mem_addr (dc_mem_addr),
    .mem_wdata(dc_mem_wdata),
    .mem_strb (dc_mem_strb),
    .mem_req  (dc_mem_req),
    .mem_we   (dc_mem_we),
    .mem_rdata(dc_mem_rdata),
    .mem_ack  (dc_mem_ack),
    .flush    (core_fence_d)
);

// ============================================================
//  BootROM (4KB, read-only) - jumps to 0x8000_0000
// ============================================================
logic [63:0] boot_rdata;
logic        boot_ack;

boot_rom u_boot (
    .clk(clk),
    .addr(dmem_addr[11:0]),
    .req(dsel_boot & dmem_req),
    .rdata(boot_rdata),
    .ack(boot_ack)
);

// ============================================================
//  DRAM (simulation only - $readmemh to load OpenSBI/Linux)
// ============================================================
logic [63:0] dram_rdata;
logic        dram_ack;
logic        dram_req_i, dram_req_d, dram_req_p;
assign dram_req_i = imem_req & isel_dram;
assign dram_req_d = dmem_req & dsel_dram;
assign dram_req_p = ptw_req  & psel_dram;

// Cross-word fetch support: read next 8-byte word for PC%8=6 case
logic [63:0] dram_rdata_next;
logic [27:0] dram_next_idx;
assign dram_next_idx = dram_addr_mux[27:0] + 28'd8;

// Intermediate wire required - XSIM forbids bit-slicing arithmetic expressions directly
logic [63:0] dram_addr_mux;
// Use [31:0] to handle sign-extended addresses from LUI/JALR
logic [63:0] dram_sel_addr;
assign dram_sel_addr = dram_req_p ? {32'h0, ptw_addr[31:0]}  :
                       dram_req_i ? {32'h0, imem_addr[31:0]} :
                                    {32'h0, dmem_addr[31:0]};
assign dram_addr_mux = dram_sel_addr - 64'h8000_0000;

dram_model #(.SIZE(DRAM_SIZE)) u_dram (
    .clk(clk),
    .addr(dram_addr_mux[27:0]),
    .wdata(dmem_wdata), .strb(dmem_strb),
    .req(dram_req_i | dram_req_d | dram_req_p),
    .we(dram_req_d & dmem_we),
    .rdata(dram_rdata),
    .ack(dram_ack)
);

assign ptw_rdata = dram_rdata;
assign ptw_ack   = dram_ack & dram_req_p;

// Read next DRAM word combinationally for cross-word fetch (PC%8=6)
assign dram_rdata_next = u_dram.mem[dram_next_idx >> 3];

// ============================================================
//  CLINT
// ============================================================
logic [63:0] clint_rdata;
logic        clint_ack;

clint #(.HARTS(1)) u_clint (
    .clk(clk), .rst_n(rst_n), .rtc_tick(rtc_tick),
    .addr(dmem_addr), .wdata(dmem_wdata), .strb(dmem_strb),
    .req(dsel_clint & dmem_req), .we(dmem_we),
    .rdata(clint_rdata), .ack(clint_ack),
    .msip(clint_msip), .mtip(clint_mtip)
);

// ============================================================
//  PLIC
// ============================================================
logic [31:0] plic_rdata;
logic        plic_ack;
logic [1:0]  plic_eip;

plic #(.NSOURCES(32), .NCONTEXTS(2)) u_plic (
    .clk(clk), .rst_n(rst_n),
    .irq_sources({31'h0, gpio_irq}),
    .addr(dmem_addr[27:0]), .wdata(dmem_wdata[31:0]),
    .req(dsel_plic & dmem_req), .we(dmem_we),
    .rdata(plic_rdata), .ack(plic_ack),
    .eip(plic_eip)
);
assign irq_m_ext = plic_eip[0];

// ============================================================
//  UART 16550
// ============================================================
logic [7:0] uart_rdata;
logic       uart_ack;

uart_16550 u_uart (
    .clk(clk), .rst_n(rst_n),
    .addr(dmem_addr[2:0]), .wdata(dmem_wdata[7:0]),
    .req(dsel_uart & dmem_req), .we(dmem_we),
    .rdata(uart_rdata), .ack(uart_ack),
    .tx(uart_tx), .rx(uart_rx)
);

// ============================================================
//  SPI master (APB)
// ============================================================
logic [31:0] spi_rdata;
logic        spi_ready;

spi_master u_spi (
    .clk(clk), .rst_n(rst_n),
    .paddr(dmem_addr[3:0]), .pwdata(dmem_wdata[31:0]),
    .psel(dsel_spi & dmem_req), .penable(dsel_spi & dmem_req),
    .pwrite(dmem_we),
    .prdata(spi_rdata), .pready(spi_ready),
    .spi_sck(spi_sck), .spi_mosi(spi_mosi),
    .spi_miso(spi_miso), .spi_csn(spi_csn)
);

// ============================================================
//  GPIO (APB)
// ============================================================
logic [31:0] gpio_rdata;
logic        gpio_ready;

gpio u_gpio (
    .clk(clk), .rst_n(rst_n),
    .paddr(dmem_addr[3:0]), .pwdata(dmem_wdata[31:0]),
    .psel(dsel_gpio & dmem_req), .penable(dsel_gpio & dmem_req),
    .pwrite(dmem_we),
    .prdata(gpio_rdata), .pready(gpio_ready),
    .gpio_pins(gpio_pins),
    .gpio_irq(gpio_irq)
);

// ============================================================
//  IMEM response mux
// ============================================================
//  IMEM response mux - I-SRAM path goes through I-cache
always_comb begin
    imem_rdata = 32'h0000_0013;
    imem_ack   = 1'b0;
    imem_err   = 1'b0;
    if (isel_isram) begin
        // I-cache response (hit=combinational, miss=multi-cycle refill)
        imem_rdata = ic_cpu_rdata;
        imem_ack   = ic_cpu_ack;
    end else if (isel_dram) begin
        // Select correct 32-bit slice based on PC[2:1] alignment
        // PC%8=0 (PC[2:1]=00): word[31:0]
        // PC%8=2 (PC[2:1]=01): word[47:16]  (mid-word, no cross needed)
        // PC%8=4 (PC[2:1]=10): word[63:32]
        // PC%8=6 (PC[2:1]=11): {dram_rdata_next[15:0], word[63:48]} (cross-word)
        case (imem_addr[2:1])
            2'b00: imem_rdata = dram_rdata[31:0];
            2'b01: imem_rdata = dram_rdata[47:16];
            2'b10: imem_rdata = dram_rdata[63:32];
            2'b11: imem_rdata = {dram_rdata_next[15:0], dram_rdata[63:48]};
        endcase
        imem_ack   = dram_ack & dram_req_i;
    end else if (imem_req) begin
        imem_err = 1'b1;
        imem_ack = 1'b1;
    end
end

// ============================================================
//  DMEM response mux  (priority: CLINT > UART > PLIC > SPI > GPIO > SRAM > DRAM > Boot)
// ============================================================
always_comb begin
    dmem_rdata = 64'h0;
    dmem_ack   = 1'b0;
    dmem_err   = 1'b0;
    if      (dsel_clint) begin dmem_rdata=clint_rdata;              dmem_ack=clint_ack;         end
    else if (dsel_uart)  begin dmem_rdata={56'h0,uart_rdata};       dmem_ack=uart_ack;          end
    else if (dsel_plic)  begin dmem_rdata={32'h0,plic_rdata};       dmem_ack=plic_ack;          end
    else if (dsel_spi)   begin dmem_rdata={32'h0,spi_rdata};        dmem_ack=spi_ready;         end
    else if (dsel_gpio)  begin dmem_rdata={32'h0,gpio_rdata};       dmem_ack=gpio_ready;        end
    else if (dsel_isram) begin dmem_rdata=isram_rdata_d;            dmem_ack=dmem_req;          end
    else if (dsel_dsram) begin dmem_rdata=dc_cpu_rdata;             dmem_ack=dc_cpu_ack;        end
    else if (dsel_dram)  begin dmem_rdata=dram_rdata;               dmem_ack=dram_ack&dram_req_d; end
    else if (dsel_boot)  begin dmem_rdata=boot_rdata;               dmem_ack=boot_ack;          end
    else if (dmem_req)   begin dmem_err=1'b1; dmem_ack=1'b1;                                    end
end

endmodule
`default_nettype wire