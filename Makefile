# SPDX-License-Identifier: Apache-2.0
# Reproducible simulation / lint / synthesis-check entry points.
#   make lint     Verilator -Wall lint of the synthesizable RTL (with I/O models)
#   make sim      self-checking top-level testbench (Verilator, --timing)
#   make yosys    technology-mapped synthesis check for XC7 (no place & route)
#   make vivado   full Vivado non-project flow (requires Vivado on PATH)
#
# Implementation back ends (docs/04_build_environments.md):
#   make openxc7-setup   build the open-source Artix-7 toolchain into $(OPENXC7)
#   make openxc7         Yosys + nextpnr-xilinx + prjxray: P&R + bitstream + Path A review
#   make bitstream-check independent decode / round trip of the open-flow bitstream
#   make vivado-docker   Vivado in the qm-vivado x86-64 container (local Docker/Colima)
#   make vivado-remote   Vivado on an x86-64 Linux host over SSH (REMOTE=user@host)
#   make impl-test       check the results of whichever back end ran
#
# Documentation figures (docs/figures, LuaLaTeX + TikZ -> SVG):
#   make figures         rebuild SVGs whose TeX source or shared style changed
#   make figures-check   verify the committed SVGs reproduce from their sources
#   make figures-clean   remove figure intermediates (committed SVGs are kept)
#   make figures-pdf     additionally export PDF versions to docs/figures/pdf

RTL      := $(shell cat scripts/rtl_files.f)
MODELS   := sim/models/qm_io_models.sv
VENDOR   := rtl/vendor/xilinx7/qm_xilinx7_io.sv
BUILD    := build
# IMPORTSTAR: qm_pkg is imported in $$unit scope because Yosys does not
# accept imports in module headers or bodies.
VFLAGS   := --timing --timescale 1ps/1ps -Wall -Wno-DECLFILENAME -Wno-IMPORTSTAR

.PHONY: all lint sim yosys vivado vivado-docker vivado-remote openxc7 openxc7-setup bitstream-check impl-test \
        figures figures-check figures-clean figures-pdf clean
all: lint sim

lint:
	verilator --lint-only $(VFLAGS) $(RTL) $(MODELS) rtl/qm_top.sv --top-module qm_top

$(BUILD)/tb_qm_top/Vtb_qm_top: $(RTL) $(MODELS) rtl/qm_top.sv tb/tb_qm_top.sv
	mkdir -p $(dir $@)
	verilator --binary $(VFLAGS) -Wno-fatal -Wno-UNUSEDSIGNAL -Wno-PROCASSINIT --assert -O2 \
	  --Mdir $(BUILD)/tb_qm_top --top-module tb_qm_top \
	  $(RTL) $(MODELS) rtl/qm_top.sv tb/tb_qm_top.sv -o Vtb_qm_top

sim: $(BUILD)/tb_qm_top/Vtb_qm_top
	$< | tee $(BUILD)/sim_qm_top.log
	@grep -q "TEST PASSED" $(BUILD)/sim_qm_top.log

yosys:
	mkdir -p $(BUILD)
	yosys -q -l $(BUILD)/yosys.log scripts/yosys_synth.ys

VIVADO  ?= vivado
OPENXC7 ?= $(HOME)/opt/openxc7
export OPENXC7

vivado:
	mkdir -p $(BUILD)/vivado
	cd $(BUILD)/vivado && $(VIVADO) -mode batch -nojournal -log vivado.log \
	  -source ../../scripts/vivado_build.tcl
	scripts/check_vivado.sh $(BUILD)/vivado

vivado-docker:
	scripts/vivado_docker.sh

vivado-remote:
	scripts/vivado_remote.sh

openxc7-setup:
	scripts/setup_openxc7.sh

openxc7:
	scripts/openxc7_build.sh
	scripts/check_openxc7.sh $(BUILD)/openxc7
	$(OPENXC7)/venv/bin/python scripts/analyze_herald_path.py $(BUILD)/openxc7/qm_top_routed.json
	$(OPENXC7)/venv/bin/python scripts/path_a_estimate.py $(BUILD)/openxc7/qm_top.sdf $(BUILD)/openxc7/qm_top_routed.json

# Independent decode of the open-flow bitstream (docs/05 §6). The missing
# configuration CRC is a known toolchain limitation and reported, not fatal.
bitstream-check:
	-scripts/bitstream_roundtrip.sh $(BUILD)/openxc7

impl-test:
	@if [ -f $(BUILD)/vivado/timing_summary.rpt ]; then scripts/check_vivado.sh $(BUILD)/vivado; fi
	@if [ -f $(BUILD)/openxc7/nextpnr.log ];      then scripts/check_openxc7.sh $(BUILD)/openxc7; fi

figures:
	$(MAKE) -C docs/figures

figures-check:
	$(MAKE) -C docs/figures check

figures-clean:
	$(MAKE) -C docs/figures clean

figures-pdf:
	$(MAKE) -C docs/figures pdf

clean:
	rm -rf $(BUILD)
