# SPDX-License-Identifier: Apache-2.0
## kasli_v2_0.xdc - Sinara Kasli 2.0 (XC7A100T-3FGG484) + DIO-MCX (2238) on EEM0/EEM1
##
## Pin numbers are taken from the Kasli v2.0 platform description in
## m-labs/migen (migen/build/platforms/sinara/kasli.py, _io_v2_0 and
## _connectors_eem). EEM channel i of a DIO card maps to EEM pair d<i>,
## as in artiq/gateware/eem.py (class DIO).
## CHECK BEFORE FIRST POWER-UP against the Kasli 2.0 and DIO-MCX schematics:
##   - LVDS p/n polarity on every used DIO-MCX channel (some Sinara cards swap pairs)
##   - whether DIO-MCX already terminates its LVDS receivers (then drop DIFF_TERM on outputs' far end;
##     inputs below use the FPGA's internal 100 ohm termination)
##   - board revision: v2.1 adds EEM power enable (U21) that must be driven high

## ---------------------------------------------------------------- clocks
## 125 MHz GTP reference clock (Si549 main DCXO). The DCXO must output 125 MHz
## at power-up; this is the frequency ARTIQ's Kasli bootstrap relies on.
set_property PACKAGE_PIN F10 [get_ports clk125_p]
set_property PACKAGE_PIN E10 [get_ports clk125_n]
create_clock -name clk125 -period 8.000 [get_ports clk125_p]

## ----------------------------------------------------------------- EEM0
## d0 (clock-capable pair): HERALD input, DIO-MCX ch0 (bank 0 = INPUT)
set_property -dict {PACKAGE_PIN R4  IOSTANDARD LVDS_25 DIFF_TERM TRUE} [get_ports herald_p]
set_property -dict {PACKAGE_PIN T4  IOSTANDARD LVDS_25 DIFF_TERM TRUE} [get_ports herald_n]
## d4..d7: Path A outputs, DIO-MCX ch4..7 (bank 1 = OUTPUT)
set_property -dict {PACKAGE_PIN W1  IOSTANDARD LVDS_25} [get_ports pump_p]
set_property -dict {PACKAGE_PIN Y1  IOSTANDARD LVDS_25} [get_ports pump_n]
set_property -dict {PACKAGE_PIN W2  IOSTANDARD LVDS_25} [get_ports repump_p]
set_property -dict {PACKAGE_PIN Y2  IOSTANDARD LVDS_25} [get_ports repump_n]
set_property -dict {PACKAGE_PIN AA1 IOSTANDARD LVDS_25} [get_ports source_p]
set_property -dict {PACKAGE_PIN AB1 IOSTANDARD LVDS_25} [get_ports source_n]
set_property -dict {PACKAGE_PIN Y4  IOSTANDARD LVDS_25} [get_ports fwd_p]
set_property -dict {PACKAGE_PIN AA4 IOSTANDARD LVDS_25} [get_ports fwd_n]

## ----------------------------------------------------------------- EEM1
## d0..d3: timed outputs, DIO-MCX ch8..11 (bank 2 = OUTPUT)
set_property -dict {PACKAGE_PIN T5  IOSTANDARD LVDS_25} [get_ports ctrl_a_p]
set_property -dict {PACKAGE_PIN U5  IOSTANDARD LVDS_25} [get_ports ctrl_a_n]
set_property -dict {PACKAGE_PIN V7  IOSTANDARD LVDS_25} [get_ports ctrl_b_p]
set_property -dict {PACKAGE_PIN W7  IOSTANDARD LVDS_25} [get_ports ctrl_b_n]
set_property -dict {PACKAGE_PIN U3  IOSTANDARD LVDS_25} [get_ports armed_p]
set_property -dict {PACKAGE_PIN V3  IOSTANDARD LVDS_25} [get_ports armed_n]
set_property -dict {PACKAGE_PIN V9  IOSTANDARD LVDS_25} [get_ports active_p]
set_property -dict {PACKAGE_PIN V8  IOSTANDARD LVDS_25} [get_ports active_n]

## ------------------------------------------------------ host UART, LEDs
set_property -dict {PACKAGE_PIN P16 IOSTANDARD LVCMOS25} [get_ports uart_rx]
set_property -dict {PACKAGE_PIN P17 IOSTANDARD LVCMOS25} [get_ports uart_tx]
set_property -dict {PACKAGE_PIN P14 IOSTANDARD LVCMOS25} [get_ports {user_led[0]}]
set_property -dict {PACKAGE_PIN R19 IOSTANDARD LVCMOS25} [get_ports {user_led[1]}]
set_property -dict {PACKAGE_PIN R16 IOSTANDARD LVCMOS25} [get_ports {user_led[2]}]
set_property -dict {PACKAGE_PIN F15 IOSTANDARD LVCMOS25} [get_ports error_led]

## -------------------------------------------------- configuration (as ARTIQ)
set_property CFGBVS VCCO                       [current_design]
set_property CONFIG_VOLTAGE 2.5                [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE   [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 33    [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 2   [current_design]
set_property BITSTREAM.CONFIG.OVERTEMPPOWERDOWN ENABLE [current_design]
set_property INTERNAL_VREF 0.750 [get_iobanks 35]

## ================================================================ timing
## Herald as a clock. Its period is the minimum spacing of herald edges the
## latch must handle; the SPAD dead time is >= 22 ns (SPCM-AQRH -1x).
create_clock -name herald -period 20.000 [get_ports herald_p]

## The herald is asynchronous to the system clock. Crossings are bounded by
## explicit datapath-only max delays instead of being left unconstrained.
set_clock_groups -asynchronous \
    -group [get_clocks herald] \
    -group [get_clocks -include_generated_clocks clk125]

## clk_sys -> herald domain: arm (CE) and clr_* (CLR) of the herald latches.
## Kept short so the moment the latch becomes armed is well defined.
set_max_delay -datapath_only 4.000 \
    -from [get_clocks -include_generated_clocks clk125] -to [get_clocks herald]

## herald domain -> clk_sys synchronizers (kill/fired state, Gray counter)
set_max_delay -datapath_only 6.000 \
    -from [get_clocks herald] -to [get_clocks -include_generated_clocks clk125]
set_bus_skew -from [get_cells -hier -filter {NAME =~ *u_latch/raw_gray_reg*}] \
             -to   [get_cells -hier -filter {NAME =~ *u_sync_raw/s_reg[0]*}] 4.000

## Path A pad-to-pad. Referencing the outputs to the herald clock makes
## Vivado time  herald pad -> IBUFDS -> ISERDES.O -> FDCE.C -> Q -> LUT -> OBUFDS -> pad
## across the slow and fast corners. Requirement: <= 20 - 10 = 10 ns.
## This is a static-timing BOUND, not a measurement (docs/03).
set_output_delay -clock herald -max 10.000 [get_ports {pump_p repump_p source_p fwd_p}]
set_output_delay -clock herald -min  0.000 [get_ports {pump_p repump_p source_p fwd_p}]

## Serdes outputs: the OSERDESE2 -> OBUFDS path is a dedicated route whose
## delay is fixed by the silicon; it is calibrated, not constrained.
set_false_path -to [get_ports {ctrl_a_p ctrl_b_p}]

## Slow diagnostics and host I/O
set_false_path -to   [get_ports {armed_p active_p uart_tx user_led[*] error_led}]
set_false_path -from [get_ports uart_rx]
