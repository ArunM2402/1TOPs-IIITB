// ============================================================
//  csr_file.sv  –  Machine + Supervisor + User CSRs
// ============================================================
`timescale 1ns/1ps


module csr_file #(
    parameter logic [63:0] MISA_VAL = 64'h8000_0000_0014_112D

)(
    input  logic        clk,
    input  logic        rst_n,
    input  logic [63:0] hartid,


    input  logic [11:0] csr_addr,
    input  logic [63:0] csr_wdata,
    input  logic [1:0]  csr_op,
    output logic [63:0] csr_rdata,
    output logic        csr_illegal,


    input  logic        irq_m_ext,
    input  logic        irq_m_timer,
    input  logic        irq_m_sw,
    input  logic        irq_s_ext,


    input  logic        trap_valid,
    input  logic [63:0] trap_cause,
    input  logic [63:0] trap_pc,
    input  logic [63:0] trap_tval,
    output logic [63:0] trap_vector,


    input  logic        mret,
    input  logic        sret,
    output logic [63:0] eret_target,

    output logic [1:0]  priv_mode,
    output logic        mstatus_sum,
    output logic        mstatus_mxr,
    output logic [63:0] satp,
 
    output logic        irq_pending,
    output logic [63:0] irq_cause
);



// ============================================================
//  CSR Registers
// ============================================================

// Machine info
logic [63:0] misa;
logic [63:0] mvendorid, marchid, mimpid, mhartid;

// Machine trap setup
logic [63:0] mstatus, mtvec, medeleg, mideleg, mie, mcounteren;

// Machine trap handling
logic [63:0] mscratch, mepc, mcause, mtval, mip;

// Supervisor trap setup
logic [63:0] sstatus, stvec, sedeleg, sideleg, sie, scounteren;

// Supervisor trap handling
logic [63:0] sscratch, sepc, scause, stval, sip;

// Supervisor page table
logic [63:0] satp_r;

// Performance counters (stub)
logic [63:0] cycle_cnt, instret_cnt;

// Privilege mode register
logic [1:0]  priv;


assign misa       = MISA_VAL;
assign mvendorid  = 64'h0;
assign marchid    = 64'h0;
assign mimpid     = 64'h0;
assign mhartid    = hartid;


assign satp       = satp_r;
assign priv_mode  = priv;
assign mstatus_sum= mstatus[18];   
assign mstatus_mxr= mstatus[19];   

always_comb begin
    mip = 64'h0;
    mip[11] = irq_m_ext;    // MEIP
    mip[9]  = irq_s_ext;    // SEIP (delegated)
    mip[7]  = irq_m_timer;  // MTIP
    mip[3]  = irq_m_sw;     // MSIP
    sip     = mip & mideleg;
end


logic [63:0] m_irq_pending, s_irq_pending;
always_comb begin
    
    m_irq_pending = mip & mie & ~mideleg;
    
    s_irq_pending = mip & mideleg & sie;

    irq_pending = 1'b0;
    irq_cause   = 64'h0;

   
    if (priv == PRIV_M && mstatus[3]) begin
       
        if      (m_irq_pending[11]) begin irq_pending=1'b1; irq_cause={1'b1,63'd11}; end // MEI
        else if (m_irq_pending[7])  begin irq_pending=1'b1; irq_cause={1'b1,63'd7};  end // MTI
        else if (m_irq_pending[3])  begin irq_pending=1'b1; irq_cause={1'b1,63'd3};  end // MSI
        else if (m_irq_pending[9])  begin irq_pending=1'b1; irq_cause={1'b1,63'd9};  end // SEI
    end else if (priv == PRIV_S) begin
        if      (m_irq_pending[11]) begin irq_pending=1'b1; irq_cause={1'b1,63'd11}; end
        else if (m_irq_pending[7])  begin irq_pending=1'b1; irq_cause={1'b1,63'd7};  end
        else if (m_irq_pending[3])  begin irq_pending=1'b1; irq_cause={1'b1,63'd3};  end
        else if (sstatus[1] && s_irq_pending[9])  begin irq_pending=1'b1; irq_cause={1'b1,63'd9};  end
        else if (sstatus[1] && s_irq_pending[5])  begin irq_pending=1'b1; irq_cause={1'b1,63'd5};  end
        else if (sstatus[1] && s_irq_pending[1])  begin irq_pending=1'b1; irq_cause={1'b1,63'd1};  end
    end else if (priv == PRIV_U) begin
        if      (m_irq_pending[11]) begin irq_pending=1'b1; irq_cause={1'b1,63'd11}; end
        else if (m_irq_pending[7])  begin irq_pending=1'b1; irq_cause={1'b1,63'd7};  end
        else if (m_irq_pending[3])  begin irq_pending=1'b1; irq_cause={1'b1,63'd3};  end
        else if (s_irq_pending[9])  begin irq_pending=1'b1; irq_cause={1'b1,63'd9};  end
        else if (s_irq_pending[5])  begin irq_pending=1'b1; irq_cause={1'b1,63'd5};  end
        else if (s_irq_pending[1])  begin irq_pending=1'b1; irq_cause={1'b1,63'd1};  end
    end
end


always_comb begin
   
    if (trap_cause[63]) begin
        
        if (priv == PRIV_S && mideleg[trap_cause[5:0]]) begin
            trap_vector = (stvec[1:0] == 2'b01) ?
                          {stvec[63:2], 2'b00} + (trap_cause[5:0] << 2) :
                          {stvec[63:2], 2'b00};
        end else begin
            trap_vector = (mtvec[1:0] == 2'b01) ?
                          {mtvec[63:2], 2'b00} + (trap_cause[5:0] << 2) :
                          {mtvec[63:2], 2'b00};
        end
    end else begin
        
        if (priv <= PRIV_S && medeleg[trap_cause[5:0]]) begin
            trap_vector = {stvec[63:2], 2'b00};
        end else begin
            trap_vector = {mtvec[63:2], 2'b00};
        end
    end
end


always_comb begin
    eret_target = mret ? mepc : sepc;
end


always_comb begin
    csr_rdata   = 64'h0;
    csr_illegal = 1'b0;

    case (csr_addr)
      
        12'hF11: csr_rdata = mvendorid;
        12'hF12: csr_rdata = marchid;
        12'hF13: csr_rdata = mimpid;
        12'hF14: csr_rdata = mhartid;

        
        12'h300: csr_rdata = mstatus;
        12'h301: csr_rdata = misa;
        12'h302: csr_rdata = medeleg;
        12'h303: csr_rdata = mideleg;
        12'h304: csr_rdata = mie;
        12'h305: csr_rdata = mtvec;
        12'h306: csr_rdata = mcounteren;

        
        12'h340: csr_rdata = mscratch;
        12'h341: csr_rdata = mepc;
        12'h342: csr_rdata = mcause;
        12'h343: csr_rdata = mtval;
        12'h344: csr_rdata = mip;

        
        12'h100: begin
            if (priv < PRIV_S) csr_illegal = 1'b1;
            else csr_rdata = sstatus;
        end
        12'h102: begin
            if (priv < PRIV_S) csr_illegal = 1'b1;
            else csr_rdata = sedeleg;
        end
        12'h103: begin
            if (priv < PRIV_S) csr_illegal = 1'b1;
            else csr_rdata = sideleg;
        end
        12'h104: begin
            if (priv < PRIV_S) csr_illegal = 1'b1;
            else csr_rdata = sie;
        end
        12'h105: begin
            if (priv < PRIV_S) csr_illegal = 1'b1;
            else csr_rdata = stvec;
        end
        12'h106: begin
            if (priv < PRIV_S) csr_illegal = 1'b1;
            else csr_rdata = scounteren;
        end

        
        12'h140: begin
            if (priv < PRIV_S) csr_illegal = 1'b1;
            else csr_rdata = sscratch;
        end
        12'h141: begin
            if (priv < PRIV_S) csr_illegal = 1'b1;
            else csr_rdata = sepc;
        end
        12'h142: begin
            if (priv < PRIV_S) csr_illegal = 1'b1;
            else csr_rdata = scause;
        end
        12'h143: begin
            if (priv < PRIV_S) csr_illegal = 1'b1;
            else csr_rdata = stval;
        end
        12'h144: begin
            if (priv < PRIV_S) csr_illegal = 1'b1;
            else csr_rdata = sip;
        end

        
        12'h180: begin
            if (priv < PRIV_S) csr_illegal = 1'b1;
            else csr_rdata = satp_r;
        end

        
        12'hC00: csr_rdata = cycle_cnt;
        12'hC02: csr_rdata = instret_cnt;
        12'hB00: csr_rdata = cycle_cnt;
        12'hB02: csr_rdata = instret_cnt;

        default: begin
            csr_illegal = 1'b1;
        end
    endcase

    
    if (csr_addr[9:8] > priv)
        csr_illegal = 1'b1;

    
    if (csr_addr[11:10] == 2'b11 && csr_op != CSR_NOP)
        csr_illegal = 1'b1;
end


function automatic [63:0] csr_modify(
    input [63:0] old_val,
    input [63:0] wdata,
    input [1:0]  op
);
    case (op)
        CSR_RW: csr_modify = wdata;
        CSR_RS: csr_modify = old_val | wdata;
        CSR_RC: csr_modify = old_val & ~wdata;
        default: csr_modify = old_val;
    endcase
endfunction


logic [63:0] new_mstatus;
assign new_mstatus = csr_modify(mstatus, csr_wdata,
                                (csr_addr == 12'h300) ? csr_op : CSR_NOP);


always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        priv        <= PRIV_M;
        mstatus     <= 64'h0000_0000_0000_0000;
        mtvec       <= 64'h0;
        medeleg     <= 64'h0;
        mideleg     <= 64'h0;
        mie         <= 64'h0;
        mcounteren  <= 64'h0;
        mscratch    <= 64'h0;
        mepc        <= 64'h0;
        mcause      <= 64'h0;
        mtval       <= 64'h0;
        sstatus     <= 64'h0;
        stvec       <= 64'h0;
        sedeleg     <= 64'h0;
        sideleg     <= 64'h0;
        sie         <= 64'h0;
        scounteren  <= 64'h0;
        sscratch    <= 64'h0;
        sepc        <= 64'h0;
        scause      <= 64'h0;
        stval       <= 64'h0;
        satp_r      <= 64'h0;
        cycle_cnt   <= 64'h0;
        instret_cnt <= 64'h0;
    end else begin
       
        cycle_cnt   <= cycle_cnt + 64'h1;

        
        if (trap_valid || irq_pending) begin
            automatic logic [63:0] t_cause = irq_pending ? irq_cause : trap_cause;
            if (priv <= PRIV_S && medeleg[t_cause[5:0]] && !t_cause[63]) begin
                
                scause <= t_cause;
                sepc   <= trap_pc;
                stval  <= trap_tval;
                
                sstatus[5]  <= sstatus[1];   
                sstatus[1]  <= 1'b0;          
                sstatus[8]  <= priv[0];     
                priv        <= PRIV_S;
            end else begin
                
                mcause <= t_cause;
                mepc   <= trap_pc;
                mtval  <= trap_tval;
               
                mstatus[7]   <= mstatus[3];  
                mstatus[3]   <= 1'b0;         
                mstatus[12:11] <= priv;       
                priv         <= PRIV_M;
            end
        end

      
        if (mret) begin
            priv          <= mstatus[12:11];   
            mstatus[3]    <= mstatus[7];        
            mstatus[7]    <= 1'b1;              
            mstatus[12:11]<= PRIV_U;           
        end

    
        if (sret) begin
            priv          <= {1'b0, sstatus[8]}; 
            sstatus[1]    <= sstatus[5];          
            sstatus[5]    <= 1'b1;                
            sstatus[8]    <= 1'b0;               
        end

        
        if (!trap_valid && !mret && !sret && csr_op != CSR_NOP) begin
            case (csr_addr)
                12'h300: mstatus    <= csr_modify(mstatus,    csr_wdata, csr_op) & 64'h8000_0003_007F_FFFF;
                12'h302: medeleg    <= csr_modify(medeleg,    csr_wdata, csr_op);
                12'h303: mideleg    <= csr_modify(mideleg,    csr_wdata, csr_op);
                12'h304: mie        <= csr_modify(mie,        csr_wdata, csr_op);
                12'h305: mtvec      <= csr_modify(mtvec,      csr_wdata, csr_op);
                12'h306: mcounteren <= csr_modify(mcounteren, csr_wdata, csr_op);
                12'h340: mscratch   <= csr_modify(mscratch,   csr_wdata, csr_op);
                12'h341: mepc       <= csr_modify(mepc,       csr_wdata, csr_op) & ~64'h1;
                12'h342: mcause     <= csr_modify(mcause,     csr_wdata, csr_op);
                12'h343: mtval      <= csr_modify(mtval,      csr_wdata, csr_op);

                12'h100: sstatus    <= csr_modify(sstatus,    csr_wdata, csr_op) & 64'h8000_0003_000D_E133;
                12'h104: sie        <= csr_modify(sie,        csr_wdata, csr_op);
                12'h105: stvec      <= csr_modify(stvec,      csr_wdata, csr_op);
                12'h106: scounteren <= csr_modify(scounteren, csr_wdata, csr_op);
                12'h140: sscratch   <= csr_modify(sscratch,   csr_wdata, csr_op);
                12'h141: sepc       <= csr_modify(sepc,       csr_wdata, csr_op) & ~64'h1;
                12'h142: scause     <= csr_modify(scause,     csr_wdata, csr_op);
                12'h143: stval      <= csr_modify(stval,      csr_wdata, csr_op);
                12'h180: satp_r     <= csr_modify(satp_r,     csr_wdata, csr_op);
                default: ;
            endcase
        end
    end
end

endmodule

