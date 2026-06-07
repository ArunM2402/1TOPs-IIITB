source ./scripts_user/config_script.tcl

set DATE [clock format [clock seconds] -format "%b%d-%T"] 

set_db hdl_unconnected_value 1 
#set_db timing_report_unconstrained true

# Directory to search for .lib (Library) files
set_db init_lib_search_path ./pdks/$tech_node/lib/

# Directory to search RTL files
set_db init_hdl_search_path ./rtl/$hdl_file/

# unflatten: individual optimization
set_db auto_ungroup none

# Verbose info level 0-9 (Recommended-6, Max-9)
set_db information_level 7

# Write log file for each run
set_db stdout_log ./genus/logs/${hdl_file}_log.txt

# Stop genus from executing when it encounters error
set_db fail_on_error_mesg true

# This attribute enables Genus to keep track of filenames, line numbers, and column numbers
# for all instances before optimization. Genus also uses this information in subsequent error
# and warning messages.
set_db hdl_track_filename_row_col true



# This is for timing optimization read genus legacy UI documentation if results are worst
#set_db tns_opto true /

# Choose the lib cell type
set_db library $cell_types 


# Naming style used in rtl
set_db hdl_parameter_naming_style _%s%d 

# Automatically partition the design and run fast in genus
set_db auto_partition true

# Check DRC & force Genus to fix DRCs, even at the expense of timing, with the drc_first attribute.
set_db drc_first true 

#Solve maximum memory address range issue
set_db hdl_max_memory_address_range inf
# Read verilog file ( if it is sv just replace the extension)
#read_hdl -mixvlog ./rtl/$hdl_file/$hdl_file.sv
read_hdl -language sv ./rtl/$hdl_file/$hdl_file.sv
#for vhdl files
#read_hdl -vhdl ./rtl/$hdl_file/$hdl_file.vhdl
set top_module $hdl_file
#set top_module hdc_top

# Elaborate the design
elaborate

# Check for unresolved refernces # Technology independent
check_design -unresolved > ./genus/reports/$hdl_file/$tech_node/design_check.rpt
#set_dont_touch hdc_unit

# Read the constraint file # Technology Independent
read_sdc ./constraints/$hdl_file/$hdl_file.sdc


# LEF file
#uncomment them
read_physical -lefs [glob -nocomplain ./pdks/$tech_node/lef/*tech.lef]
read_physical -add_lefs [glob -nocomplain ./pdks/$tech_node/lef/*macro.lef]

#QRC file
#uncomment
read_qrc ./pdks/$tech_node/qrc/gpdk045.tch
#read_qrc /home/arun_ms2024004/physical_design/pdks/sky130/qrc/qrcTechFile

# Define cost groups (clk-clk, clk-output, input-clk, input-output)
#define_cost_group -name I2C -design $hdl_file
#define_cost_group -name C2O -design $hdl_file
#define_cost_group -name C2C -design $hdl_file
#define_cost_group -name I2O -design $hdl_file

#path_group -from [all_registers] -to [all_registers] -group C2C -name C2C
#path_group -from [all_registers] -to [all_outputs] -group C2O -name C2O
#path_group -from [all_inputs] -to [all_registers] -group I2C -name I2C
#path_group -from [all_inputs] -to [all_outputs] -group I2O -name I2O

#set file_rpt "./genus/reports/$hdl_file/$tech_node/presynth/${hdl_file}_presynth.rpt"
#set file_gtd "./genus/reports/$hdl_file/$tech_node/presynth/${hdl_file}_presynth.gtd"

#if {[file exists $file_rpt]} {
#	file delete $file_rpt
#}

#if {[file exists $file_gtd]} {
#	file delete $file_gtd
#}

#foreach cg [vfind / -cost_group *] {
#	report_timing -group [list $cg] -output_format gtd >> ./genus/reports/$hdl_file/$tech_node/presynth/${hdl_file}_presynth.gtd
#	report_timing -group [list $cg] >> "./genus/reports/$hdl_file/$tech_node/presynth/${hdl_file}_presynth.rpt"
#}


# Set the top module name in hierarchical design if the modules are not in same rtl file
#set top_module sigmoid_float_0_1


# Analytical optimization identifies connected, cross-hierarchy regions of the datapath logic, and
# selects the best architecture for each region within the context of the full design. This optimization
# explores multiple architectures for each region by applying a range of constraints

# The best area results are obtained, at the possible expense of timing.
#set_db dp_analytical_opt extreme

# To turn off carry-save transformations
#set_db dp_csa none


# If the user_sub_arch attribute is specified on a multiplier, it will take precedence over the
# apply_booth_encoding setting.

# Booth encoding options {nonbooth | auto_bitwidth | auto_togglerate | manual | inherited}
#set_db apply_booth_encoding auto_togglerate

# Report Datapath Operators
#report_dp -all -print_inferred > ./genus/reports/$hdl_file/$tech_node/post_elaboration/syn_generic_datapath_report.rpt


# Generic Synthesis
set_db syn_generic_effort $generic_effort
syn_generic 
write_hdl > ./genus/synthesis/$hdl_file/$tech_node/generic/${hdl_file}_syn_generic.v
write_sdc > ./genus/synthesis/$hdl_file/$tech_node/generic/${hdl_file}_syn_generic.sdc
report_power > ./genus/reports/$hdl_file/$tech_node/generic/${hdl_file}_syn_generic_power.rpt
write_snapshot -outdir ./genus/reports/$hdl_file/$tech_node/generic/ -tag ${hdl_file}_syn_generic
report_power > ./genus/reports/$hdl_file/$tech_node/generic/${hdl_file}_syn_generic_power.rpt

# Mapping 
set_db syn_map_effort $map_effort
syn_map
time_info MAPPED
write_hdl > ./genus/synthesis/$hdl_file/$tech_node/mapped/${hdl_file}_syn_map.v
write_sdc > ./genus/synthesis/$hdl_file/$tech_node/mapped/${hdl_file}_syn_map.sdc
report_power > ./genus/reports/$hdl_file/$tech_node/mapped/${hdl_file}_syn_map_power.rpt
write_snapshot -outdir ./genus/reports/$hdl_file/$tech_node/mapped/ -tag ${hdl_file}_syn_map
report_power > ./genus/reports/$hdl_file/$tech_node/mapped/${hdl_file}_syn_map_power.rpt
# step 1 LEC do file generation
write_hdl -lec > ./genus/lec/$hdl_file/$tech_node/${hdl_file}_lec_pre_opt.v
write_do_lec -golden_design rtl -revised_design ./genus/lec/$hdl_file/$tech_node/${hdl_file}_lec_pre_opt.v > ./genus/lec/$hdl_file/$tech_node/${hdl_file}_lec_pre_opt.do


# Incremental performs area and power optimization

# Optimized
set_db syn_opt_effort $opt_effort
syn_opt -incr
time_info OPT
write_hdl > ./genus/synthesis/$hdl_file/$tech_node/opt/${hdl_file}_syn_opt.v
write_sdc > ./genus/synthesis/$hdl_file/$tech_node/opt/${hdl_file}_syn_opt.sdc
report_power > ./genus/reports/$hdl_file/$tech_node/opt/${hdl_file}_syn_opt_power.rpt
write_snapshot -outdir ./genus/reports/$hdl_file/$tech_node/opt/ -tag ${hdl_file}_syn_opt
report_summary -directory ./genus/reports/$hdl_file/$tech_node/
report_timing -unconstrained  > ./genus/reports/$hdl_file/$tech_node/opt/${hdl_file}_syn_opt_timing_path.rpt
report_power > ./genus/reports/$hdl_file/$tech_node/opt/${hdl_file}_syn_opt_power.rpt
# step 2 LEC do file generation for synthesized netlist
write_hdl -lec > ./genus/lec/$hdl_file/$tech_node/${hdl_file}_lec_opt.v
write_do_lec -golden_design ./genus/lec/$hdl_file/$tech_node/${hdl_file}_lec_pre_opt.v -revised_design ./genus/lec/$hdl_file/$tech_node/${hdl_file}_lec_opt.v > ./genus/lec/$hdl_file/$tech_node/${hdl_file}_lec_opt.do

# Report design rules
#uncomment
#report_design_rules > ./genus/reports/$hdl_file/$tech_node/des-Rules.rpt

#set file_rpt "./genus/reports/$hdl_file/$tech_node/postsynth/${hdl_file}_post_opt.rpt"
#set file_gtd "./genus/reports/$hdl_file/$tech_node/postsynth/${hdl_file}_post_opt.gtd"

#if {[file exists $file_rpt]} {
#	file delete $file_rpt
#}

#if {[file exists $file_gtd]} {
#	file delete $file_gtd
#}

#foreach cg [vfind / -cost_group *] {
#	puts [list $cg]
#	report_timing -group [list $cg] >> ./genus/reports/$hdl_file/$tech_node/postsynth/${hdl_file}_post_opt.rpt
#	report_timing -group [list $cg] -output_format gtd >> ./genus/reports/$hdl_file/$tech_node/postsynth/${hdl_file}_post_opt.gtd
#}



# Display in gui window
#gui_show

