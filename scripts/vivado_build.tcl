# SPDX-License-Identifier: Apache-2.0
# vivado_build.tcl - non-project Vivado flow for qm_top on Kasli 2.0.
# Run from build/vivado:  vivado -mode batch -source ../../scripts/vivado_build.tcl
# Tested with: NOT YET RUN (Vivado was not available when this was written).
# Intended for Vivado ML Standard (free) 2023.2 or later, which supports XC7A100T.

set root  [file normalize [file join [file dirname [info script]] ..]]
set part  xc7a100tfgg484-3
set top   qm_top

set srcs {}
foreach f [split [string trim [read [open $root/scripts/rtl_files.f]]] "\n"] {
    lappend srcs $root/$f
}
lappend srcs $root/rtl/vendor/xilinx7/qm_xilinx7_io.sv $root/rtl/qm_top.sv

read_verilog -sv $srcs
read_xdc $root/constr/kasli_v2_0.xdc

synth_design -top $top -part $part -flatten_hierarchy rebuilt
report_utilization    -file post_synth_util.rpt

opt_design
place_design
phys_opt_design
route_design

report_timing_summary -max_paths 20 -report_unconstrained -file timing_summary.rpt
report_utilization    -file util.rpt
report_clock_interaction -file clock_interaction.rpt
report_cdc            -details -file cdc.rpt
report_methodology    -file methodology.rpt
report_drc            -file drc.rpt
report_datasheet      -file datasheet.rpt

# Path A: herald pad -> kill/fwd output pads, both corners, min and max
report_timing -from [get_ports herald_p] \
              -to   [get_ports {pump_p repump_p source_p fwd_p}] \
              -delay_type min_max -max_paths 8 -nworst 1 -file path_a.rpt

# Show where the herald latch landed relative to the I/O
report_property [get_cells -hier -filter {NAME =~ *u_latch/*q_reg*}] -file latch_cells.rpt

if {[get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]] < 0} {
    puts "ERROR: setup timing not met, see timing_summary.rpt"
}
if {[get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]] < 0} {
    puts "ERROR: hold timing not met, see timing_summary.rpt"
}

write_checkpoint -force ${top}_routed.dcp
write_bitstream  -force ${top}.bit
# SPI x2 flash image for Kasli's configuration flash (see docs/03 for writing it)
write_cfgmem -force -format bin -interface SPIx2 -size 16 \
             -loadbit "up 0x0 ${top}.bit" -file ${top}.bin
