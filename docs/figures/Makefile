# SPDX-License-Identifier: Apache-2.0
# docs/figures/Makefile - LuaLaTeX/TikZ sources -> vector SVG for the README.
#
#   make            build every SVG whose .tex or styles.tex changed
#   make pdf        also keep the PDF versions in pdf/
#   make check      rebuild into a temporary directory and compare with the
#                   committed SVGs (byte for byte)
#   make clean      remove intermediates (build/, pdf/); committed SVGs stay
#
# Toolchain: LuaLaTeX (TeX Live 2026) + pdftocairo (Poppler 26.10). The SVGs
# contain glyph outlines, not fonts, so GitHub renders them without any fonts
# installed. Byte-identical output is expected for identical tool versions.

FIGURES  := experiment artiq-feedback herald-architecture timing
SVGS     := $(FIGURES:%=%.svg)
BUILD    := build
LUALATEX ?= lualatex
PDFTOCAIRO ?= pdftocairo

# Reproducible PDFs: fixed dates; styles.tex suppresses the PDF ID.
export SOURCE_DATE_EPOCH := 1767225600
export FORCE_SOURCE_DATE := 1

.PHONY: all pdf check clean
all: $(SVGS)

# The SVG is the only target; the PDF is an intermediate in build/, so
# `make clean` does not force a rebuild of up-to-date SVGs.
%.svg: %.tex styles.tex normalize_svg.py
	@mkdir -p $(BUILD)
	$(LUALATEX) -interaction=nonstopmode -halt-on-error -file-line-error \
	  -output-directory=$(BUILD) $< > $(BUILD)/$*.stdout || \
	  { grep -E '^[^:]+:[0-9]+:|^!' $(BUILD)/$*.log; exit 1; }
	@! grep -E 'Overfull|Underfull|Missing character|undefined' $(BUILD)/$*.log \
	  || { echo "$*: warnings above (see $(BUILD)/$*.log)"; exit 1; }
	$(PDFTOCAIRO) -svg $(BUILD)/$*.pdf $(BUILD)/$*.raw.svg
	./normalize_svg.py $(BUILD)/$*.raw.svg $@

pdf: $(SVGS)
	@mkdir -p pdf
	cp $(FIGURES:%=$(BUILD)/%.pdf) pdf/

check:
	@rm -rf $(BUILD)/check && mkdir -p $(BUILD)/check
	@for f in $(FIGURES); do \
	  $(LUALATEX) -interaction=nonstopmode -halt-on-error \
	    -output-directory=$(BUILD)/check $$f.tex > /dev/null || { echo "FAIL $$f: LaTeX error"; exit 1; }; \
	  $(PDFTOCAIRO) -svg $(BUILD)/check/$$f.pdf $(BUILD)/check/$$f.raw.svg; \
	  ./normalize_svg.py $(BUILD)/check/$$f.raw.svg $(BUILD)/check/$$f.svg; \
	  if cmp -s $(BUILD)/check/$$f.svg $$f.svg; then echo "ok   $$f.svg reproduces"; \
	  else echo "FAIL $$f.svg differs from its source build"; status=1; fi; \
	done; exit $${status:-0}

clean:
	rm -rf $(BUILD) pdf
