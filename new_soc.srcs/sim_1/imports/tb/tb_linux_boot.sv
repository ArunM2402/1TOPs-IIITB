// ============================================================
//  tb_linux_boot.sv  -  Linux boot simulation testbench
//
//  Loads three images into DRAM:
//    opensbi.hex  → DRAM[0]       (phys 0x8000_0000)
//    kernel.hex   → DRAM[0x4000]  (phys 0x8020_0000)
//    fdt.hex      → DRAM[0x40000] (phys 0x8200_0000)
//
//  Boot ROM already sets: a0=0 (HARTID), a1=0x8200_0000 (FDT)
//  then jumps to 0x8000_0000 (OpenSBI entry).
//
//  BUILD INSTRUCTIONS (on Linux host):
//  ──────────────────────────────────
//  1. OpenSBI:
//     git clone https://github.com/riscv-software-src/opensbi && cd opensbi
//     make PLATFORM=generic CROSS_COMPILE=riscv64-unknown-elf- \
//          FW_JUMP=y FW_JUMP_ADDR=0x80200000 FW_JUMP_FDT_ADDR=0x82000000
//     riscv64-unknown-elf-objcopy -O verilog \
//         build/platform/generic/firmware/fw_jump.elf opensbi.hex
//
//  2. Linux kernel (via buildroot):
//     git clone https://github.com/buildroot/buildroot && cd buildroot
//     make qemu_riscv64_virt_defconfig
//     # In menuconfig: set initramfs as rootfs
//     make -j$(nproc)
//     riscv64-unknown-elf-objcopy -O verilog output/images/Image kernel.hex
//
//  3. FDT (from soc.dts provided):
//     dtc -I dts -O dtb -o soc.dtb soc.dts
//     python3 dtb_to_hex.py soc.dtb fdt.hex
//
//  All three .hex files must be in the Vivado simulation working dir.
// ============================================================
`timescale 1ns/1ps
`default_nettype none

module tb_linux_boot;

// ============================================================
//  Clock / Reset
// ============================================================
localparam CLK_HALF = 5;    // 10ns = 100MHz
localparam RTC_DIV  = 100;  // RTC at 1MHz

logic clk = 0, rst_n;
always #CLK_HALF clk = ~clk;

int rtc_cnt = 0; logic rtc_tick = 0;
always_ff @(posedge clk) begin
    if (rtc_cnt==RTC_DIV-1) begin rtc_cnt<=0; rtc_tick<=1; end
    else                     begin rtc_cnt<=rtc_cnt+1; rtc_tick<=0; end
end

// ============================================================
//  DUT
// ============================================================
logic uart_tx, uart_rx;
logic [63:0] debug_pc;
wire  [31:0] gpio_pins;

assign uart_rx = 1'b1;

soc_top #(.DRAM_SIZE(32'h0400_0000)) dut (
    .clk(clk), .rst_n(rst_n), .rtc_tick(rtc_tick),
    .uart_rx(uart_rx), .uart_tx(uart_tx),
    .spi_sck(), .spi_mosi(), .spi_miso(1'b1), .spi_csn(),
    .gpio_pins(gpio_pins),
    .debug_pc(debug_pc)
);

// ============================================================
//  UART monitor - 115200 baud at 100MHz = 868 clocks/bit
// ============================================================
// ============================================================
//  UART monitor - TX FIFO direct (baud-rate independent)
// ============================================================
int   uart_cap_cnt = 0;
logic login_seen   = 1'b0;
logic [7:0] uart_buf [0:65535];
logic uart_prev_busy;

initial begin : uart_monitor
    logic [7:0] cur_byte;
    uart_prev_busy = 1'b0;
    @(posedge rst_n);
    repeat(10) @(posedge clk);
    forever begin
        @(posedge clk);
        if (dut.u_uart.tx_busy && !uart_prev_busy) begin
            cur_byte = dut.u_uart.tx_shift[8:1]; // bits[8:1] = data, [0]=start, [9]=stop
            $write("%c", cur_byte);
            uart_buf[uart_cap_cnt] = cur_byte;
            uart_cap_cnt = uart_cap_cnt + 1;
            if (uart_cap_cnt >= 6) begin
                if (uart_buf[uart_cap_cnt-6]=="l" &&
                    uart_buf[uart_cap_cnt-5]=="o" &&
                    uart_buf[uart_cap_cnt-4]=="g" &&
                    uart_buf[uart_cap_cnt-3]=="i" &&
                    uart_buf[uart_cap_cnt-2]=="n" &&
                    uart_buf[uart_cap_cnt-1]==":") begin
                    $display("\n╔══════════════════════════════════╗");
                    $display(  "║  LINUX BOOT SUCCESSFUL           ║");
                    $display(  "╚══════════════════════════════════╝");
                    login_seen = 1'b1;
                    #10000 $finish;
                end
            end
        end
        uart_prev_busy = dut.u_uart.tx_busy;
    end
end

// ============================================================
//  PC milestone monitor
// ============================================================
// Minimal trace - just show PC every 100M cycles
initial begin : pc_trace
    @(posedge rst_n);
    forever begin
        repeat(100_000_000) @(posedge clk);
        $display("[PC_100M] t=%0t pc=%h bytes=%0d", $time, debug_pc, uart_cap_cnt);
        if (uart_cap_cnt > 0 || login_seen) disable pc_trace;
    end
end
logic [63:0] prev_pc = 64'hFFFF_FFFF_FFFF_FFFF;
always_ff @(posedge clk) begin
    if (debug_pc !== prev_pc) begin
        // Detect trap: PC drops from high (0x8000_xxxx) to low memory
        if (prev_pc[31] == 1'b1 && debug_pc[31] == 1'b0 && debug_pc < 64'h1000_0000)
            $display("[TRAP] PC 0x%h -> 0x%h at t=%0t", prev_pc, debug_pc, $time);
        prev_pc <= debug_pc;
        case (debug_pc)
            64'h8000_0000: $display("[PC] 0x8000_0000 - OpenSBI entry");
            64'h8020_0000: $display("[PC] 0x8020_0000 - Linux kernel entry");
            64'h8020_0080: $display("[PC] 0x8020_0080 - kernel decompressed");
        endcase
    end
end

// ============================================================
//  Main
// ============================================================
initial begin
    $display("╔══════════════════════════════════════════════╗");
    $display("║  IIITB 1TOPs SoC - Linux Boot Testbench     ║");
    $display("╚══════════════════════════════════════════════╝");

    rst_n = 0;
    repeat(20) @(posedge clk);

    // Load firmware images
    $display("[LOAD] Loading opensbi.hex  → DRAM[0x0000_0000] (phys 0x8000_0000)");
    $readmemh("/home/arunp24/1tops/iiitb_riscv_soc/opensbi_correct.hex", dut.u_dram.mem, 0);

    $display("[LOAD] Loading kernel.hex   → DRAM[0x0004_0000] (phys 0x8020_0000)");
    $readmemh("/home/arunp24/1tops/iiitb_riscv_soc/kernel.hex", dut.u_dram.mem, 'h4000);
    // NOTE: kernel.hex must be pre-patched (first word = AUIPC+JALR to 0x8040_0000)
    // Use kernel_patched.hex generated by fix_kernel_entry.py

    $display("[LOAD] Loading fdt.hex      → DRAM[0x0040_0000] (phys 0x8200_0000)");
    $readmemh("/home/arunp24/1tops/iiitb_riscv_soc/riscv_core/scripts/fdt.hex", dut.u_dram.mem, 'h40000);

    $display("[BOOT] Releasing reset - CPU starting at BootROM (0x0000_0000)");
    $display("[BOOT] BootROM: a0=0 (HARTID), a1=0x8200_0000 (FDT) → 0x8000_0000");
    $display("[BOOT] Waiting for UART output...\n");

    rst_n = 1;

    // 10M cycles just to see OpenSBI init (~100ms sim time)
    // Full Linux boot needs ~500M-2B cycles at 100MHz
    // Run in chunks to avoid XSIM integer overflow (max 2^31)
    repeat(100_000_000) @(posedge clk);
    repeat(100_000_000) @(posedge clk);
    repeat(100_000_000) @(posedge clk);
    repeat(100_000_000) @(posedge clk);
    repeat(100_000_000) @(posedge clk);

    if (!login_seen) begin
        $display("\n[RESULT] Timeout. Bytes received: %0d, Last PC: 0x%h",
                 uart_cap_cnt, debug_pc);
        if (uart_cap_cnt == 0)
            $display("[DEBUG] No UART output - check opensbi.hex loaded correctly");
        else
            $display("[DEBUG] Got %0d bytes but no login: prompt", uart_cap_cnt);
    end
    $finish;
end

// UART TX monitor - print level every 10M cycles to detect activity
initial begin : uart_activity_mon
    int prev_count;
    prev_count = 0;
    forever begin
        repeat(10_000_000) @(posedge clk);
        if (uart_cap_cnt != prev_count) begin
            $display("[UART] %0d bytes received so far", uart_cap_cnt);
            prev_count = uart_cap_cnt;
        end else begin
            $display("[UART] uart_tx=%b  bytes_so_far=%0d  pc=%h",
                uart_tx, uart_cap_cnt, debug_pc);
        end
    end
end

// Hard watchdog - 60 seconds
initial begin
    repeat(30) #2_000_000_000;
    $display("[WATCHDOG] Hard timeout after 60s");
    $finish;
end

endmodule
`default_nettype wire