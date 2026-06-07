# Technode parameters
set tech_node "cadence_45nm"

# Cell Type
set fast_cell_type "fast_vdd1v0_basicCells.lib"
set slow_cell_type "slow_vdd1v0_basicCells.lib"

set typical_cell_type "fast_vdd1v0_basicCells.lib"
set cell_types $fast_cell_type


# HDL file
set hdl_file "ibex_hdc" 

set qrc_file "gpdk045"

# Synthesis efforts
set generic_effort "high"
set map_effort "high"
set opt_effort "high"

# Physical Design
set aspect_ratio_core 1
set utilization 0.7
set lmargin 10
set rmargin 10
set tmargin 10
set bmargin 10


