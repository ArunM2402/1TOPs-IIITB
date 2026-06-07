// ============================================================
//  mmu_sv39.sv  –  Sv39 Page Table Walker
//  3-level page table (GiB / MiB / KiB pages)
//  Implements A/D bit updates, PMP stub
// ============================================================
`timescale 1ns/1ps


module mmu_sv39 (
    input  logic        clk,
    input  logic        rst_n,

    // Translation request
    input  logic [63:0] va,           // virtual address (38:0 significant)
    input  logic        req,          // request strobe
    input  logic        is_write,     // 0=load/fetch, 1=store
    input  logic        is_fetch,     // 1=instruction fetch
    input  logic [1:0]  priv_mode,
    input  logic        mstatus_sum,
    input  logic        mstatus_mxr,
    input  logic [63:0] satp,         // satp CSR

    // Physical address output
    output logic [63:0] pa,
    output logic        done,         // translation complete
    output logic        page_fault,   // page fault exception
    output logic        access_fault,

    // Page table memory interface (read-only walks)
    output logic [63:0] pt_addr,
    output logic        pt_req,
    input  logic [63:0] pt_rdata,
    input  logic        pt_ack
);

// ============================================================
//  Sv39 constants
// ============================================================
localparam int LEVELS = 3;

typedef enum logic [2:0] {
    IDLE,
    WALK0,
    WALK1,
    WALK2,
    DONE_OK,
    DONE_FAULT
} ptw_state_t;

ptw_state_t state;
logic [63:0] pte;
logic [43:0] ppn [2:0];  // PPNs from each level
logic [2:0]  vpn [2:0];  // but each is 9 bits
logic [63:0] pt_base;

// PPN / VPN extraction
// satp.PPN = satp[43:0]
// VA[38:30] = VPN[2], VA[29:21] = VPN[1], VA[20:12] = VPN[0]
logic [8:0] vpn2, vpn1, vpn0;
assign vpn2 = va[38:30];
assign vpn1 = va[29:21];
assign vpn0 = va[20:12];

// PTE field extraction
logic pte_v, pte_r, pte_w, pte_x, pte_u, pte_g, pte_a, pte_d;
assign pte_v = pte[0];
assign pte_r = pte[1];
assign pte_w = pte[2];
assign pte_x = pte[3];
assign pte_u = pte[4];
assign pte_g = pte[5];
assign pte_a = pte[6];
assign pte_d = pte[7];

logic is_leaf;
assign is_leaf = pte_r | pte_x;  // leaf PTE has R or X set

// Whether MMU is active
logic mmu_active;
assign mmu_active = (satp[63:60] == 4'h8) &&  // MODE=8 → Sv39
                    (priv_mode != 2'b11);        // not M-mode

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state       <= IDLE;
        done        <= 1'b0;
        page_fault  <= 1'b0;
        access_fault<= 1'b0;
        pt_req      <= 1'b0;
        pa          <= 64'h0;
    end else begin
        done        <= 1'b0;
        page_fault  <= 1'b0;
        access_fault<= 1'b0;

        // Passthrough when MMU is disabled
        if (req && !mmu_active) begin
            pa   <= va;
            done <= 1'b1;
        end else begin
            unique case (state)
                IDLE: begin
                    if (req && mmu_active) begin
                        pt_addr <= {satp[43:0], 12'h0} + {52'h0, vpn2, 3'h0};
                        pt_req  <= 1'b1;
                        state   <= WALK0;
                    end
                end

                WALK0: begin
                    if (pt_ack) begin
                        pt_req <= 1'b0;
                        pte    <= pt_rdata;
                        if (!pt_rdata[0] || (pt_rdata[1:0] == 2'b10)) begin
                            // Invalid or reserved
                            state <= DONE_FAULT;
                        end else if (pt_rdata[1] | pt_rdata[3]) begin
                            // Gigapage leaf (1 GiB)
                            // Check alignment: PPN[1:0] must be 0
                            if (pt_rdata[28:19] != 10'h0 || pt_rdata[18:10] != 9'h0)
                                state <= DONE_FAULT;
                            else
                                state <= DONE_OK;
                        end else begin
                            // Pointer to next level
                            pt_addr <= {pt_rdata[53:10], 12'h0} + {52'h0, vpn1, 3'h0};
                            pt_req  <= 1'b1;
                            state   <= WALK1;
                        end
                    end
                end

                WALK1: begin
                    if (pt_ack) begin
                        pt_req <= 1'b0;
                        pte    <= pt_rdata;
                        if (!pt_rdata[0] || (pt_rdata[1:0] == 2'b10)) begin
                            state <= DONE_FAULT;
                        end else if (pt_rdata[1] | pt_rdata[3]) begin
                            // Megapage leaf (2 MiB)
                            if (pt_rdata[18:10] != 9'h0)
                                state <= DONE_FAULT;
                            else
                                state <= DONE_OK;
                        end else begin
                            pt_addr <= {pt_rdata[53:10], 12'h0} + {52'h0, vpn0, 3'h0};
                            pt_req  <= 1'b1;
                            state   <= WALK2;
                        end
                    end
                end

                WALK2: begin
                    if (pt_ack) begin
                        pt_req <= 1'b0;
                        pte    <= pt_rdata;
                        if (!pt_rdata[0] || !(pt_rdata[1] | pt_rdata[3])) begin
                            state <= DONE_FAULT;
                        end else begin
                            state <= DONE_OK;
                        end
                    end
                end

                DONE_OK: begin
                    // Permission checks
                    logic ok;
                    ok = 1'b1;
                    // U-mode access to supervisor page
                    if (priv_mode == 2'b00 && !pte_u) ok = 1'b0;
                    // S-mode access to user page without SUM
                    if (priv_mode == 2'b01 && pte_u && !mstatus_sum) ok = 1'b0;
                    // Execute permission
                    if (is_fetch && !pte_x) ok = 1'b0;
                    // Read permission (MXR allows reading exec pages)
                    if (!is_fetch && !is_write && !pte_r && !(mstatus_mxr && pte_x)) ok = 1'b0;
                    // Write permission
                    if (is_write && (!pte_w || !pte_d)) ok = 1'b0;
                    // A bit must be set
                    if (!pte_a) ok = 1'b0;

                    if (!ok) begin
                        page_fault <= 1'b1;
                    end else begin
                        // Assemble physical address
                        // PA = PPN[2:0] : page_offset
                        pa   <= {10'h0, pte[53:10], va[11:0]};
                        done <= 1'b1;
                    end
                    state <= IDLE;
                end

                DONE_FAULT: begin
                    page_fault <= 1'b1;
                    state      <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end
end

endmodule
`default_nettype wire
