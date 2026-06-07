source ./scripts_user/config_script.tcl

setMultiCpuUsage -localCpu max
set ::TimeLib::tsgMarkCellLatchConstructFlag 1
set conf_qxconf_file {NULL}
set conf_qxlib_file {NULL}
set dbgDualViewAwareXTree 1
set defHierChar {/}
set distributed_client_message_echo {1}
set distributed_mmmc_disable_reports_auto_redirection {0}
set enable_ilm_dual_view_gui_and_attribute 1
set enc_enable_print_mode_command_reset_options 1

set init_design_netlisttype verilog
#set init_verilog "./genus/synthesis/$hdl_file/$tech_node/opt/${hdl_file}_syn_opt.v"
set init_verilog "/home/arun_ms2024004/Downloads/syn_opt.v"
set init_design_settop 0

set pegDefaultResScaleFactor 1
set pegDetailResScaleFactor 1
set pegEnableDualViewForTQuantus 1
set report_inactive_arcs_format {from to when arc_type sense reason}
set spgUnflattenIlmInCheckPlace 2
set init_verilog_tolerate_port_mismatch 0
set load_netlist_ignore_undefined_cell 1

set init_pwr_net {VDD}
set init_gnd_net {VSS}
set latch_time_borrow_mode max_borrow
set init_lef_file "./pdks/$tech_node/lef/*tech.lef ./pdks/$tech_node/lef/*macro.lef"
set python_script "./scripts_user/script_run.py"
set hpwl_python_script "./scripts_user/hpwl_extract.py"
set label_extract_script "./scripts_user/dataset_gen_with_label.py"
set dataset_gen_script   "./scripts_user/gen_dataset.py"

create_rc_corner -name rc_corner -cap_table "./pdks/$tech_node/captable/cln28hpl_1p10m+alrdl_5x2yu2yz_typical.capTbl" -preRoute_res {1.0} -preRoute_cap {1.0} -preRoute_clkres {0.0} -preRoute_clkcap {0.0} -postRoute_res {1.0} -postRoute_cap {1.0} -postRoute_xcap {1.0} -postRoute_clkres {0.0} -postRoute_clkcap {0.0} -qx_tech_file "./pdks/$tech_node/qrc/${qrc_file}.tch"
#create_rc_corner -name rc_corner -preRoute_res {1.0} -preRoute_cap {1.0} -preRoute_clkres {0.0} -preRoute_clkcap {0.0} -postRoute_res {1.0} -postRoute_cap {1.0} -postRoute_xcap {1.0} -postRoute_clkres {0.0} -postRoute_clkcap {0.0} -qx_tech_file "./pdks/$tech_node/qrc/qrcTechFile_typ03_unscaledV02"
#changed here
create_library_set -name fast -timing "./pdks/$tech_node/lib/$fast_cell_type"
create_library_set -name slow -timing "./pdks/$tech_node/lib/$slow_cell_type"
#create_constraint_mode -name constraints -sdc_files "./genus/synthesis/$hdl_file/$tech_node/opt/${hdl_file}_syn_opt.sdc"
create_constraint_mode -name constraints -sdc_files "/home/arun_ms2024004/Downloads/syn_opt.sdc"
create_delay_corner -name fast_delay -library_set {fast} -rc_corner {rc_corner}
create_delay_corner -name slow_delay -library_set {slow} -rc_corner {rc_corner}
create_analysis_view -name setup_analysis -constraint_mode {constraints} -delay_corner {slow_delay}
create_analysis_view -name hold_analysis -constraint_mode {constraints} -delay_corner {fast_delay}

init_design -setup {setup_analysis} -hold {hold_analysis}
set_analysis_view -setup {setup_analysis} -hold {hold_analysis}

globalNetConnect VDD -type pgpin -pin VDD -override -verbose -netlistOverride
globalNetConnect VSS -type pgpin -pin VSS -override -verbose -netlistOverride


# Floorplan
setFPlanMode -initAllCompatibleCoreSiteRows true
floorPlan -coreMarginsBy io -site CoreSite -r "$aspect_ratio_core" "$utilization" "$lmargin" "$bmargin" "$rmargin" "$tmargin"
defOut -floorplan -netlist -unplaced "./innovus/$hdl_file/$tech_node/def/floorplan.def"

# Power Planning
setAddRingMode -stacked_via_top_layer M11 -stacked_via_bottom_layer M1 
addRing -nets {VDD VSS} -type core_rings -around user_defined -center 0 -spacing 0.5 -width 0.5 -offset 0.5 -threshold auto -layer {top M11 bottom M11 right M10 left M10}
addStripe -nets {VDD VSS} -layer M10 -width 0.5 -spacing 1 -number_of_sets 3 -start_from left
sroute -connect {blockPin padPin padRing corePin floatingStripe } -allowJogging true -allowLayerChange true -blockPin useLef -targetviaLayerRange {M1 M11}

# Placement
setPlaceMode -place_design_floorplan_mode true
setPlaceMode -place_global_timing_effort high -place_global_cong_effort high -place_global_reorder_scan true 
place_opt_design -out_dir "./innovus/$hdl_file/$tech_node/optimization_reports/placement/"
place_design

# pre-CTS 
setDelayCalMode -SIAWare true
optDesign -preCTS -outDir "./innovus/$hdl_file/$tech_node/optimization_reports/preCTS/"
timeDesign -preCTS -outDir "./innovus/$hdl_file/$tech_node/timing/prects/"
defOut -floorplan -netlist "./innovus/$hdl_file/$tech_node/def/placement.def"



# Function to extract the pins
set all_ports       [dbGet top.terms.name -v *clk*]

set num_ports       [llength $all_ports]
set quarter_ports_idx [expr $num_ports / 4]

# Split pins into four groups (top, bottom, left, right)
set pins_top        [lrange $all_ports 0               $quarter_ports_idx-1]
set pins_bottom     [lrange $all_ports $quarter_ports_idx  [expr $quarter_ports_idx * 2 - 1]]
set pins_left       [lrange $all_ports [expr $quarter_ports_idx * 2] [expr $quarter_ports_idx * 3 - 1]]
set pins_right      [lrange $all_ports [expr $quarter_ports_idx * 3] [expr $num_ports - 1]]

# Take all clock ports and distribute them among the four sides
set clock_ports     [dbGet top.terms.name *clk*]
set half_left_idx   [expr [llength $pins_left] / 2]
set half_right_idx  [expr [llength $pins_right] / 2]

if { $clock_ports != 0 } {
  # Distribute clock ports across all four sides
 foreach port $clock_ports {
    # Alternate between sides
  	lappend pins_top    [lindex $clock_ports 0]
 	lappend pins_bottom [lindex $clock_ports 1]
	lappend pins_left   [lindex $clock_ports 2]
	lappend pins_right  [lindex $clock_ports 3]
}
}

# Spread the pins evenly across the four sides of the chip
set ports_layer M5

# Place pins on all four sides (top, bottom, left, right)
editPin -layer $ports_layer -pin $pins_top    -side TOP    -spreadType SIDE
editPin -layer $ports_layer -pin $pins_bottom -side BOTTOM -spreadType SIDE
editPin -layer $ports_layer -pin $pins_left   -side LEFT   -spreadType SIDE
editPin -layer $ports_layer -pin $pins_right  -side RIGHT  -spreadType SIDE

defOut -floorplan -netlist "./innovus/$hdl_file/$tech_node/def/pin_placement.def"
puts "Pin Placement Done"
file mkdir ./innovus/$hdl_file/$tech_node/timing_reports
set_table_style -name report_timing -max_widths {50,50,250} 
report_timing -from [all_registers] -to [all_registers] -max_paths 1000000000 -format {arc cell instance} > "./innovus/$hdl_file/$tech_node/timing_reports/req_timing.txt"

# python starts
#python3 $python_script


# Function to calculate Manhattan distance
proc manhattan_distance {driver_pin load_pin c_distance} {
    set Ax [get_property [get_pins $driver_pin] x_coordinate]
    set Ay [get_property [get_pins $driver_pin] y_coordinate]

    set Bx [get_property [get_pins $load_pin] x_coordinate]
    set By [get_property [get_pins $load_pin] y_coordinate]

    set distance [expr {abs($Ax - $Bx) + abs($Ay - $By)}]
    set c_distance [expr {$c_distance + $distance}]

    return [list $distance $c_distance]
}

# Procedure to read files from a folder and compute distances
proc process_files {length_input_dir length_output_dir} {
    # Get list of files in the folder
    set file_list [glob -nocomplain "$length_input_dir/*.txt"]

    # Ensure the output directory exists (create if needed)
    #set output_dir [file join $folder_path "out"]
    if {![file exists $length_output_dir]} {
        file mkdir $length_output_dir
    }
    
    set counter 1
    # Loop through each file
    foreach file $file_list {
        # Construct the output file path
        set output_file [file join $length_output_dir "hpwl_path${counter}.txt"]
        set output_fp [open $output_file "w"]
        set c_distance 0
        # Open the current file and read its content
        set fp [open $file "r"]
        while {![eof $fp]} {
            set line [gets $fp]
            if {[string length $line] > 0} {
                # Split the line to get the driver_pin and load_pin
                set pins [split $line " "]
                set driver_pin [lindex $pins 0]
                set load_pin [lindex $pins 1]

                # Compute the Manhattan distance
                set result [manhattan_distance $driver_pin $load_pin $c_distance]
                set distance [lindex $result 0]
                set c_distance [lindex $result 1]
                # Write the result to the output file
                puts $output_fp "$driver_pin $load_pin $distance $c_distance"
                
            }
        }

        # Close the file pointers
        close $fp
        close $output_fp
        incr counter
    }
}

# Call the process_files procedure with the path to the folder containing the .txt files
# Change the path as necessary

file mkdir ./innovus/$hdl_file/$tech_node/timing_reports/paths
file mkdir ./innovus/$hdl_file/$tech_node/timing_reports/out


set length_input_dir "./innovus/$hdl_file/$tech_node/timing_reports/paths"
set length_output_dir "./innovus/$hdl_file/$tech_node/timing_reports/out"
process_files $length_input_dir $length_output_dir


puts "HWPL DONE"

#python3 $hpwl_python_script

puts "final hpwl output done"
set_table_style -name report_timing -max_widths {250,50,50,50,50,50,50} 
#report_timing -from [all_registers] -to [all_registers] -max_paths 1000000000 -format {instance cell delay fanout slew pin_load wire_load} > "./innovus/$hdl_file/$tech_node/timing_reports/dataset_timing.txt"

#python3 $dataset_gen_script

puts "Feature Dataset generated"

# CTS
# Function to get CLKBUF cells
set clkbuf_cells {}
# Open the .lib file for reading
set file [open "./pdks/$tech_node/lib/$cell_types" r]

# Read the file line by line
while {[gets $file line] != -1} {
    # Check if "CLKBUF" is present in the line
    if {[string match "*CLKBUF*" $line]} {
        # Extract the text inside parentheses
        if {[regexp {^\s*cell\s*\(\s*([^\)]+)\s*\)} $line match cell_name]} {
            # Add cell_name to the list if not already present
            if {[lsearch -exact $clkbuf_cells $cell_name] == -1} {
                lappend clkbuf_cells $cell_name
            }
        }
    }
}

close $file 

#setCTSMode -engine ccopt
setCheckMode -all true
setOptMode -fixCap true -fixTran true -fixFanoutLoad false
set_ccopt_property buffer_cells $clkbuf_cells

# Use if error is thrown for max transition tooo low
set_ccopt_property target_max_trans 0.1 
#clock_opt_design -out_dir "./innovus/$hdl_file/$tech_node/optimization_reports/ccopt_CTS/"
optDesign -postCTS -outDir "./innovus/$hdl_file/$tech_node/optimization_reports/postCTS/"
timeDesign -postCTS -outDir "./innovus/$hdl_file/$tech_node/timing/postCTS/"
defOut -floorplan -netlist "./innovus/$hdl_file/$tech_node/def/cts.def"

# Routing
#globalDetailRoute
setNanoRouteMode -quiet -timingEngine {}
setNanoRouteMode -quiet -routeWithTimingDriven 1
setNanoRouteMode -quiet -routeWithSiDriven 1
setNanoRouteMode -quiet -routeWithSiPostRouteFix 0
setNanoRouteMode -quiet -drouteStartIteration default
setNanoRouteMode -quiet -routeTopRoutingLayer default
setNanoRouteMode -quiet -routeBottomRoutingLayer default
setNanoRouteMode -quiet -drouteEndIteration default
setNanoRouteMode -quiet -routeWithTimingDriven true
setNanoRouteMode -quiet -routeWithSiDriven true
routeDesign -globalDetail


setEndCapMode -reset
setEndCapMode -boundary_tap false
setNanoRouteMode -quiet -routeAntennaCellName {}
setUsefulSkewMode -maxSkew false -noBoundary false -useCells {dl04d1 bufbd7 buffd2 dl03d1 bufbdf buffda dl02d2 dl03d4 dl04d2 dl02d1 dl01d4 buffd3 bufbda bufbdk buffd4 dl04d4 dl02d4 bufbd4 dl01d2 bufbd3 bufbd1 dl01d1 buffd7 bufbd2 buffd1 dl03d2 inv0d2 invbda inv0da invbdk inv0d1 inv0d7 invbd4 invbd2 inv0d0 invbd7 invbdf inv0d4} -maxAllowedDelay 1
setNanoRouteMode -quiet -routeAntennaCellName adiode
setNanoRouteMode -quiet -routeTdrEffort 5
setNanoRouteMode -quiet -routeTopRoutingLayer default
setNanoRouteMode -quiet -routeBottomRoutingLayer default
setNanoRouteMode -quiet -drouteEndIteration default
setNanoRouteMode -quiet -routeWithTimingDriven true
setNanoRouteMode -quiet -routeWithSiDriven true
routeDesign -globalDetail -viaOpt -wireOpt


# Post Routing timing analysis
setAnalysisMode -analysisType onChipVariation
optDesign -postRoute -hold -outDir "./innovus/$hdl_file/$tech_node/optimization_reports/postroute/"
timeDesign -postRoute -outDir "./innovus/$hdl_file/$tech_node/timing/postroute/"

# Add Filler Cells
set fillercells [list FILL1 FILL2 FILL4 FILL8 FILL16 FILL32 FILL64]
setFillerMode -corePrefix ${hdl_file}_FILL -core ${fillercells}
addFiller -cell $fillercells -prefix ${hdl_file}_FILL -markFixed 


# Verify DRC
verify_drc -check_only all -report "./innovus/$hdl_file/$tech_node/${hdl_file}_drc.rpt"
verifyConnectivity -type all -report "./innovus/$hdl_file/$tech_node/${hdl_file}_connectivity.rpt"

defOut -routing -netlist "./innovus/$hdl_file/$tech_node/def/floorplan.def"

# Extraction of parasitics
extractRC -outfile "./innovus/$hdl_file/$tech_node/parasitics/${hdl_file}.cap"
rcOut -spef "./innovus/$hdl_file/$tech_node/parasitics/${hdl_file}.spef"
write_sdf "./innovus/$hdl_file/$tech_node/parasitics/${hdl_file}.sdf"

puts "entire process done"


#extraction of labels
set report_dir "./innovus/$hdl_file/$tech_node/timing_reports/route_reports"

# Check if the directory exists, and create it if necessary
if {![file exists $report_dir]} {
    file mkdir $report_dir
}

file mkdir ./innovus/$hdl_file/$tech_node/timing_reports/route_reports
set_table_style -name report_timing -max_widths {250,50,50,50,50,50} 
report_timing -late -from [all_registers] -to [all_registers] -max_paths 1000000000 -max_slack  0 > "./innovus/$hdl_file/$tech_node/timing_reports/route_reports/timing_route.txt"

#python3 $label_extract_script

puts "label extraction done"
#exit







