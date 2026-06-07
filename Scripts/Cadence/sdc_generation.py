import re
DESIGN_NAME = "ibex_top"

def parse_verilog_module(verilog_code):
    # Regex patterns to identify input/output ports
    input_pattern = r"input\s+(reg\s+)?([^\s]+)\s+([^\[]+)\[([0-9]+)\:([0-9]+)\]?"
    output_pattern = r"output\s+(reg\s+)?([^\s]+)\s+([^\[]+)\[([0-9]+)\:([0-9]+)\]?"
    generic_input_pattern = r"input\s+(reg\s+)?([^\s]+)\s+([^\[]+)"
    generic_output_pattern = r"output\s+(reg\s+)?([^\s]+)\s+([^\[]+)"

    # Extracting all input and output ports
    inputs = []
    outputs = []
    
    # Searching for input and output ports
    for line in verilog_code.splitlines():
        line = line.strip()
        input_match = re.match(input_pattern, line)
        if input_match:
            inputs.append({
                'name': input_match.group(3),
                'array_size': int(input_match.group(4)) - int(input_match.group(5)) + 1
            })
            continue
        
        output_match = re.match(output_pattern, line)
        if output_match:
            outputs.append({
                'name': output_match.group(3),
                'array_size': int(output_match.group(4)) - int(output_match.group(5)) + 1
            })
            continue
        
        generic_input_match = re.match(generic_input_pattern, line)
        if generic_input_match:
            inputs.append({
                'name': generic_input_match.group(3),
                'array_size': 1  # Single element, no array
            })
            continue
        
        generic_output_match = re.match(generic_output_pattern, line)
        if generic_output_match:
            outputs.append({
                'name': generic_output_match.group(3),
                'array_size': 1  # Single element, no array
            })
            continue
    
    return inputs, outputs

def generate_sdc(inputs, outputs, clk_name="clk_i"):
    sdc_lines = []
    
    # Generate input delay constraints for input ports
    for port in inputs:
        for i in range(port['array_size']):
            port_name = f"{port['name']}[{i}]" if port['array_size'] > 1 else port['name']
            sdc_lines.append(f"set_input_delay -clock [get_clocks \"{clk_name}\"] -max 0.1 [get_ports {port_name}]")
            sdc_lines.append(f"set_input_delay -clock [get_clocks \"{clk_name}\"] -min 0.1 [get_ports {port_name}]")
    
    # Generate output delay constraints for output ports
    for port in outputs:
        for i in range(port['array_size']):
            port_name = f"{port['name']}[{i}]" if port['array_size'] > 1 else port['name']
            sdc_lines.append(f"set_output_delay -clock [get_clocks \"{clk_name}\"] -max 0.1 [get_ports {port_name}]")
            sdc_lines.append(f"set_output_delay -clock [get_clocks \"{clk_name}\"] -min 0.1 [get_ports {port_name}]")
    
    return "\n".join(sdc_lines)

def main(verilog_code):
    # Parse the verilog code to get inputs and outputs
    inputs, outputs = parse_verilog_module(verilog_code)
    
    # Generate the SDC file content
    sdc_content = generate_sdc(inputs, outputs)
    
    # Write the SDC content to a file
    with open(f"../constraints/{DESIGN_NAME}/{DESIGN_NAME}.sdc", "w") as sdc_file:
        sdc_file.write(sdc_content)

# Example Verilog code (replace this with actual code read from a file)
verilog_code = """
module ibex_core import ibex_pkg::*; #(
  parameter bit                     PMPEnable        = 1'b0,
  parameter int unsigned            PMPGranularity   = 0,
  parameter int unsigned            PMPNumRegions    = 4,
  parameter ibex_pkg::pmp_cfg_t     PMPRstCfg[16]    = ibex_pkg::PmpCfgRst,
  parameter logic [33:0]            PMPRstAddr[16]   = ibex_pkg::PmpAddrRst,
  parameter ibex_pkg::pmp_mseccfg_t PMPRstMsecCfg    = ibex_pkg::PmpMseccfgRst,
  parameter int unsigned            MHPMCounterNum   = 0,
  parameter int unsigned            MHPMCounterWidth = 40,
  parameter bit                     RV32E            = 1'b0,
  parameter rv32m_e                 RV32M            = RV32MFast,
  parameter rv32b_e                 RV32B            = RV32BNone,
  parameter bit                     BranchTargetALU  = 1'b0,
  parameter bit                     WritebackStage   = 1'b0,
  parameter bit                     ICache           = 1'b0,
  parameter bit                     ICacheECC        = 1'b0,
  parameter int unsigned            BusSizeECC       = BUS_SIZE,
  parameter int unsigned            TagSizeECC       = IC_TAG_SIZE,
  parameter int unsigned            LineSizeECC      = IC_LINE_SIZE,
  parameter bit                     BranchPredictor  = 1'b0,
  parameter bit                     DbgTriggerEn     = 1'b0,
  parameter int unsigned            DbgHwBreakNum    = 1,
  parameter bit                     ResetAll         = 1'b0,
  parameter lfsr_seed_t             RndCnstLfsrSeed  = RndCnstLfsrSeedDefault,
  parameter lfsr_perm_t             RndCnstLfsrPerm  = RndCnstLfsrPermDefault,
  parameter bit                     SecureIbex       = 1'b0,
  parameter bit                     DummyInstructions= 1'b0,
  parameter bit                     RegFileECC       = 1'b0,
  parameter int unsigned            RegFileDataWidth = 32,
  parameter bit                     MemECC           = 1'b0,
  parameter int unsigned            MemDataWidth     = MemECC ? 32 + 7 : 32,
  parameter int unsigned            DmBaseAddr       = 32'h1A110000,
  parameter int unsigned            DmAddrMask       = 32'h00000FFF,
  parameter int unsigned            DmHaltAddr       = 32'h1A110800,
  parameter int unsigned            DmExceptionAddr  = 32'h1A110808,
  // mvendorid: encoding of manufacturer/provider
  parameter logic [31:0]            CsrMvendorId     = 32'b0,
  // marchid: encoding of base microarchitecture
  parameter logic [31:0]            CsrMimpId        = 32'b0
) (
  // Clock and Reset
  input  logic                         clk_i,
  input  logic                         rst_ni,

  input  logic [31:0]                  hart_id_i,
  input  logic [31:0]                  boot_addr_i,

  // Instruction memory interface
  output logic                         instr_req_o,
  input  logic                         instr_gnt_i,
  input  logic                         instr_rvalid_i,
  output logic [31:0]                  instr_addr_o,
  input  logic [MemDataWidth-1:0]      instr_rdata_i,
  input  logic                         instr_err_i,

  // Data memory interface
  output logic                         data_req_o,
  input  logic                         data_gnt_i,
  input  logic                         data_rvalid_i,
  output logic                         data_we_o,
  output logic [3:0]                   data_be_o,
  output logic [31:0]                  data_addr_o,
  output logic [MemDataWidth-1:0]      data_wdata_o,
  input  logic [MemDataWidth-1:0]      data_rdata_i,
  input  logic                         data_err_i,

  // Register file interface
  output logic                         dummy_instr_id_o,
  output logic                         dummy_instr_wb_o,
  output logic [4:0]                   rf_raddr_a_o,
  output logic [4:0]                   rf_raddr_b_o,
  output logic [4:0]                   rf_waddr_wb_o,
  output logic                         rf_we_wb_o,
  output logic [RegFileDataWidth-1:0]  rf_wdata_wb_ecc_o,
  input  logic [RegFileDataWidth-1:0]  rf_rdata_a_ecc_i,
  input  logic [RegFileDataWidth-1:0]  rf_rdata_b_ecc_i,

  // RAMs interface
  output logic [IC_NUM_WAYS-1:0]       ic_tag_req_o,
  output logic                         ic_tag_write_o,
  output logic [IC_INDEX_W-1:0]        ic_tag_addr_o,
  output logic [TagSizeECC-1:0]        ic_tag_wdata_o,
  input  logic [TagSizeECC-1:0]        ic_tag_rdata_i [IC_NUM_WAYS],
  output logic [IC_NUM_WAYS-1:0]       ic_data_req_o,
  output logic                         ic_data_write_o,
  output logic [IC_INDEX_W-1:0]        ic_data_addr_o,
  output logic [LineSizeECC-1:0]       ic_data_wdata_o,
  input  logic [LineSizeECC-1:0]       ic_data_rdata_i [IC_NUM_WAYS],
  input  logic                         ic_scr_key_valid_i,
  output logic                         ic_scr_key_req_o,

  // Interrupt inputs
  input  logic                         irq_software_i,
  input  logic                         irq_timer_i,
  input  logic                         irq_external_i,
  input  logic [14:0]                  irq_fast_i,
  input  logic                         irq_nm_i,       // non-maskable interrupt
  output logic                         irq_pending_o,

  // Debug Interface
  input  logic                         debug_req_i,
  output crash_dump_t                  crash_dump_o,
  // SEC_CM: EXCEPTION.CTRL_FLOW.LOCAL_ESC
  // SEC_CM: EXCEPTION.CTRL_FLOW.GLOBAL_ESC
  output logic                         double_fault_seen_o,
  
  output logic [3:0]                    hdc_predicted_class,
  output logic                          SC_done,
  output logic                          hdc_predicted_class_hdc,
  output [12:0]                         feature_vector_pointer,
  output [5:0]                          level_index,
  output [9:0]                          x_data_pointer,
  input  [31:0]                         dina,
  output [5:0]                          class_vector_pointer,
  input  [99:0]                         class_vector,
  input  [31:0]                         value,
  input  [99:0]                         level_vector,
  input  [99:0]                         feature_vector,

  // RISC-V Formal Interface
  // Does not comply with the coding standards of _i/_o suffixes, but follows
  // the convention of RISC-V Formal Interface Specification.
`ifdef RVFI
  output logic                         rvfi_valid,
  output logic [63:0]                  rvfi_order,
  output logic [31:0]                  rvfi_insn,
  output logic                         rvfi_trap,
  output logic                         rvfi_halt,
  output logic                         rvfi_intr,
  output logic [ 1:0]                  rvfi_mode,
  output logic [ 1:0]                  rvfi_ixl,
  output logic [ 4:0]                  rvfi_rs1_addr,
  output logic [ 4:0]                  rvfi_rs2_addr,
  output logic [ 4:0]                  rvfi_rs3_addr,
  output logic [31:0]                  rvfi_rs1_rdata,
  output logic [31:0]                  rvfi_rs2_rdata,
  output logic [31:0]                  rvfi_rs3_rdata,
  output logic [ 4:0]                  rvfi_rd_addr,
  output logic [31:0]                  rvfi_rd_wdata,
  output logic [31:0]                  rvfi_pc_rdata,
  output logic [31:0]                  rvfi_pc_wdata,
  output logic [31:0]                  rvfi_mem_addr,
  output logic [ 3:0]                  rvfi_mem_rmask,
  output logic [ 3:0]                  rvfi_mem_wmask,
  output logic [31:0]                  rvfi_mem_rdata,
  output logic [31:0]                  rvfi_mem_wdata,
  output logic [31:0]                  rvfi_ext_pre_mip,
  output logic [31:0]                  rvfi_ext_post_mip,
  output logic                         rvfi_ext_nmi,
  output logic                         rvfi_ext_nmi_int,
  output logic                         rvfi_ext_debug_req,
  output logic                         rvfi_ext_debug_mode,
  output logic                         rvfi_ext_rf_wr_suppress,
  output logic [63:0]                  rvfi_ext_mcycle,
  output logic [31:0]                  rvfi_ext_mhpmcounters [10],
  output logic [31:0]                  rvfi_ext_mhpmcountersh [10],
  output logic                         rvfi_ext_ic_scr_key_valid,
  output logic                         rvfi_ext_irq_valid,
  `endif

  // CPU Control Signals
  // SEC_CM: FETCH.CTRL.LC_GATED
  input  ibex_mubi_t                   fetch_enable_i,
  output logic                         alert_minor_o,
  output logic                         alert_major_internal_o,
  output logic                         alert_major_bus_o,
  output ibex_mubi_t                   core_busy_o
);
"""
# Run the script
main(verilog_code)

