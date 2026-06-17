// ============================================================
//  dram_model.sv  -  Behavioural DRAM for simulation
//  Single-cycle latency, full byte-enable writes
//  Supports $readmemh loading for firmware images
// ============================================================


module dram_model #(
    parameter int unsigned SIZE = 32'h1000_0000  // 256 MB default
)(
    input  logic        clk,
    input  logic [27:0] addr,     // byte address (28-bit = 256MB)
    input  logic [63:0] wdata,
    input  logic [7:0]  strb,
    input  logic        req,
    input  logic        we,
    output logic [63:0] rdata,
    output logic        ack
);

localparam int unsigned WORDS = SIZE / 8;

logic [63:0] mem [WORDS];

initial begin
    for (int i = 0; i < WORDS; i++) mem[i] = 64'h0;
end

// Task: load a hex file at a given word offset (call from testbench)
task automatic load_hex(input string filename, input int unsigned base_word);
    $readmemh(filename, mem, base_word);
    $display("[DRAM] loaded %s at word offset 0x%0h", filename, base_word);
endtask

// Task: write raw bytes (for testbench inline loading)
task automatic write_byte(input int unsigned byte_addr, input logic [7:0] data);
    automatic int unsigned word = byte_addr >> 3;
    automatic int unsigned boff = byte_addr & 7;
    mem[word][boff*8 +: 8] = data;
endtask

// Task: write 32-bit word (little-endian)
task automatic write_word32(input int unsigned byte_addr, input logic [31:0] data);
    automatic int unsigned word = byte_addr >> 3;
    automatic int unsigned boff = (byte_addr >> 0) & 4;
    if (boff == 0) mem[word][31:0]  = data;
    else           mem[word][63:32] = data;
endtask

// Task: write 64-bit doubleword
task automatic write_word64(input int unsigned byte_addr, input logic [63:0] data);
    mem[byte_addr >> 3] = data;
endtask

// Read 32-bit word for testbench checks
function automatic [31:0] read_word32(input int unsigned byte_addr);
    automatic int unsigned word = byte_addr >> 3;
    automatic int unsigned boff = (byte_addr >> 0) & 4;
    read_word32 = (boff == 0) ? mem[word][31:0] : mem[word][63:32];
endfunction

always_ff @(posedge clk) begin
    ack   <= 1'b0;
    rdata <= 64'h0;
    if (req) begin
        ack <= 1'b1;
        if (we) begin
            for (int b = 0; b < 8; b++)
                if (strb[b]) mem[addr[27:3]][b*8 +: 8] <= wdata[b*8 +: 8];
        end else begin
            rdata <= mem[addr[27:3]];
        end
    end
end

endmodule
`default_nettype wire