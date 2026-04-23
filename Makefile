################################################################################
# Axion Common - Makefile
#
# Build and test VHDL modules using GHDL
#
# Targets:
#   make all      - Analyze all VHDL sources
#   make test     - Run all tests and generate report
#   make clean    - Remove build artifacts
#   make help     - Show available targets
#
# Copyright (c) 2024 Bugra Tufan
# MIT License
################################################################################

# Use bash so PIPESTATUS works in recipes
SHELL := /bin/bash

# Tools
GHDL := ghdl
GHDL_STD := --std=08

# Directories
ROOT_DIR := $(shell pwd)
SRC_DIR := $(ROOT_DIR)/src
TB_DIR := $(ROOT_DIR)/tb
BUILD_DIR := $(ROOT_DIR)/build
WORK_DIR := $(BUILD_DIR)/work
REPORT_DIR := $(BUILD_DIR)/reports
SCRIPT_DIR := $(ROOT_DIR)/scripts

# GHDL flags
GHDL_FLAGS := $(GHDL_STD) --workdir=$(WORK_DIR) -P$(WORK_DIR)
GHDL_ELAB_FLAGS := $(GHDL_STD) --workdir=$(WORK_DIR) -P$(WORK_DIR)
GHDL_RUN_FLAGS := --stop-time=100ms

# Source files
PKG_SRC := $(SRC_DIR)/axion_common_pkg.vhd
BRIDGE_SRC := $(SRC_DIR)/axion_axi_lite_bridge.vhd
BRIDGE_TB := $(TB_DIR)/axion_axi_lite_bridge_tb.vhd

# All source files
SRCS := $(PKG_SRC) $(BRIDGE_SRC)
TBS := $(BRIDGE_TB)

# Output files
TEST_OUTPUT := $(BUILD_DIR)/test_output.log
REPORT_FILE := $(REPORT_DIR)/requirement_verification.md
WAVE_FILE := $(BUILD_DIR)/waves.ghw

# Colors
RED := \033[0;31m
GREEN := \033[0;32m
YELLOW := \033[1;33m
BLUE := \033[0;34m
NC := \033[0m

################################################################################
# cocotb settings
################################################################################

# Python binary - prefer venv if it exists next to repo root
VENV_PYTHON := $(shell cd $(ROOT_DIR) && git rev-parse --show-toplevel 2>/dev/null)/venv/bin/python3
PYTHON := $(shell if [ -x "$(VENV_PYTHON)" ]; then echo "$(VENV_PYTHON)"; else echo "python3"; fi)

# Venv that contains cocotb + Verilator bindings for SV package tests.
# Defaults to the repo-local ./venv; override AXION_HDL_VENV via make or environment
# if your cocotb/Verilator venv lives elsewhere.
AXION_HDL_VENV ?= $(ROOT_DIR)/venv

# Python for SV package tests: use venv if available, otherwise system python3
# In Docker the venv does not exist so this naturally falls back to system python3
PYTHON_FOR_SV := $(shell if [ -x "$(AXION_HDL_VENV)/bin/python3" ]; then echo "$(AXION_HDL_VENV)/bin/python3"; else echo "python3"; fi)

# Find cocotb VPI library at runtime from whichever python3 is active
COCOTB_VPI = $(shell $(PYTHON) -c \
	"import os, cocotb; print(os.path.join(os.path.dirname(cocotb.__file__), 'libs', 'libcocotbvpi_ghdl.so'))" \
	2>/dev/null)

# cocotb build dirs
COCOTB_BUILD_DIR := $(BUILD_DIR)/cocotb_sim
WRAP_SRC := $(TB_DIR)/axion_axi_lite_bridge_wrap.vhd
COCOTB_TB := tb_axion_axi_lite_bridge_cocotb

# GHDL generic overrides for the cocotb wrapper.
# G_TIMEOUT_WIDTH=8 → 256-cycle bridge timeout, matching the cocotb test assumptions.
COCOTB_GHDL_GENERICS := -gG_TIMEOUT_WIDTH=8

# Docker image tag used by CI (ci.yml).  Must match the tags: field in the workflow.
CI_IMAGE := axion-common:ci

################################################################################
# Targets
################################################################################

.PHONY: all analyze test cocotb-test cocotb-analyze cocotb-sv-pkg-test docker-test local-ci-test clean help dirs check-ghdl report

# Default target
all: analyze

# Create necessary directories
dirs:
	@mkdir -p $(WORK_DIR)
	@mkdir -p $(REPORT_DIR)

# Check GHDL installation
check-ghdl:
	@which $(GHDL) > /dev/null 2>&1 || \
		(echo "$(RED)Error: GHDL not found. Please install GHDL first.$(NC)" && exit 1)
	@echo "$(GREEN)✓ GHDL found: $$($(GHDL) --version | head -n1)$(NC)"

# Analyze all VHDL sources
analyze: dirs check-ghdl
	@echo "$(YELLOW)>>> Analyzing VHDL sources...$(NC)"
	@$(GHDL) -a $(GHDL_FLAGS) --work=axion_common $(PKG_SRC)
	@echo "  ✓ axion_common_pkg.vhd"
	@$(GHDL) -a $(GHDL_FLAGS) --work=axion_common $(BRIDGE_SRC)
	@echo "  ✓ axion_axi_lite_bridge.vhd"
	@$(GHDL) -a $(GHDL_FLAGS) $(BRIDGE_TB)
	@echo "  ✓ axion_axi_lite_bridge_tb.vhd"
	@echo "$(GREEN)✓ All sources analyzed successfully$(NC)"

# Elaborate testbench
elaborate: analyze
	@echo "$(YELLOW)>>> Elaborating testbench...$(NC)"
	@$(GHDL) -e $(GHDL_ELAB_FLAGS) axion_axi_lite_bridge_tb
	@echo "$(GREEN)✓ Testbench elaborated successfully$(NC)"

# Run ALL tests: VHDL suite then SV package suite
test: elaborate
	@echo ""
	@echo "$(BLUE)================================================================================$(NC)"
	@echo "$(BLUE)  Axion Common - Running All Tests$(NC)"
	@echo "$(BLUE)================================================================================$(NC)"
	@echo ""
	@mkdir -p $(BUILD_DIR)
	@mkdir -p $(REPORT_DIR)
	@echo "$(YELLOW)>>> [1/2] VHDL tests (GHDL)...$(NC)"
	@$(GHDL) -r $(GHDL_ELAB_FLAGS) axion_axi_lite_bridge_tb $(GHDL_RUN_FLAGS) --wave=$(WAVE_FILE) 2>&1 | tee $(TEST_OUTPUT); \
	GHDL_EXIT=$${PIPESTATUS[0]}; \
	if [ $$GHDL_EXIT -ne 0 ]; then \
		echo ""; \
		echo "$(RED)✗ VHDL tests FAILED$(NC)"; \
		echo "$(BLUE)Log: $(TEST_OUTPUT)$(NC)"; \
		exit 1; \
	fi
	@echo ""
	@echo "$(GREEN)✓ Waveform generated: $(WAVE_FILE)$(NC)"
	@$(MAKE) -s report
	@echo ""
	@echo "$(YELLOW)>>> [2/2] SV package cocotb tests (Verilator)...$(NC)"
	@$(PYTHON_FOR_SV) $(TB_DIR)/run_sv_pkg_tests.py \
		> $(BUILD_DIR)/sv_pkg_cocotb_output.log 2>&1; \
	SV_EXIT=$$?; \
	cat $(BUILD_DIR)/sv_pkg_cocotb_output.log; \
	if [ $$SV_EXIT -ne 0 ]; then \
		echo ""; \
		echo "$(RED)✗ SV Package cocotb tests FAILED$(NC)"; \
		echo "$(BLUE)Log: $(BUILD_DIR)/sv_pkg_cocotb_output.log$(NC)"; \
		exit 1; \
	fi
	@echo "$(GREEN)✓ SV Package cocotb tests passed$(NC)"
	@echo "$(BLUE)Log: $(BUILD_DIR)/sv_pkg_cocotb_output.log$(NC)"

# Generate requirement verification report
report:
	@echo "$(YELLOW)>>> Generating requirement verification report...$(NC)"
	@echo "# Requirement Verification Report" > $(REPORT_FILE)
	@echo "" >> $(REPORT_FILE)
	@echo "| Field | Value |" >> $(REPORT_FILE)
	@echo "|-------|-------|" >> $(REPORT_FILE)
	@echo "| Date | $$(date +%Y-%m-%d) |" >> $(REPORT_FILE)
	@echo "| Time | $$(date +%H:%M:%S) |" >> $(REPORT_FILE)
	@echo "| Tool | GHDL |" >> $(REPORT_FILE)
	@echo "" >> $(REPORT_FILE)
	@echo "## Test Results" >> $(REPORT_FILE)
	@echo "" >> $(REPORT_FILE)
	@echo "| Requirement ID | Status |" >> $(REPORT_FILE)
	@echo "|----------------|--------|" >> $(REPORT_FILE)
	@for req in AXI-LITE-001 AXI-LITE-002 AXI-LITE-003 AXI-LITE-004 AXI-LITE-005 \
		AXI-LITE-006 AXI-LITE-007 AXI-LITE-008 \
		AXION-COMMON-001 AXION-COMMON-002 AXION-COMMON-003 AXION-COMMON-004 \
		AXION-COMMON-005 AXION-COMMON-006 AXION-COMMON-007 AXION-COMMON-008 \
		AXION-COMMON-009 AXION-COMMON-010 AXION-COMMON-011 AXION-COMMON-012; do \
		if grep -q "\[PASS\] $$req" $(TEST_OUTPUT) 2>/dev/null; then \
			echo "| $$req | ✅ PASS |" >> $(REPORT_FILE); \
		elif grep -q "\[FAIL\] $$req" $(TEST_OUTPUT) 2>/dev/null; then \
			echo "| $$req | ❌ FAIL |" >> $(REPORT_FILE); \
		else \
			echo "| $$req | ⚠️ NOT RUN |" >> $(REPORT_FILE); \
		fi \
	done
	@echo "" >> $(REPORT_FILE)
	@PASSED=$$(grep -c "\[PASS\]" $(TEST_OUTPUT) 2>/dev/null || true); \
	PASSED=$${PASSED:-0}; \
	FAILED=$$(grep -c "\[FAIL\]" $(TEST_OUTPUT) 2>/dev/null || true); \
	FAILED=$${FAILED:-0}; \
	TOTAL=$$((PASSED + FAILED)); \
	echo "## Summary" >> $(REPORT_FILE); \
	echo "" >> $(REPORT_FILE); \
	echo "| Metric | Count |" >> $(REPORT_FILE); \
	echo "|--------|-------|" >> $(REPORT_FILE); \
	echo "| Total Tests | $$TOTAL |" >> $(REPORT_FILE); \
	echo "| Passed | $$PASSED |" >> $(REPORT_FILE); \
	echo "| Failed | $$FAILED |" >> $(REPORT_FILE); \
	echo "" >> $(REPORT_FILE); \
	if [ "$$FAILED" -eq 0 ] && [ "$$TOTAL" -gt 0 ]; then \
		echo "## Result: ✅ ALL REQUIREMENTS VERIFIED" >> $(REPORT_FILE); \
		echo "$(GREEN)✓ Report generated: $(REPORT_FILE)$(NC)"; \
	else \
		echo "## Result: ❌ SOME REQUIREMENTS FAILED" >> $(REPORT_FILE); \
		echo "$(YELLOW)⚠ Report generated: $(REPORT_FILE)$(NC)"; \
	fi
	@echo ""
	@echo "$(BLUE)================================================================================$(NC)"
	@echo "$(BLUE)  Report: $(REPORT_FILE)$(NC)"
	@echo "$(BLUE)================================================================================$(NC)"

# Analyze wrapper for cocotb (depends on axion_common lib being built first)
cocotb-analyze: analyze
	@echo "$(YELLOW)>>> Analyzing cocotb wrapper...$(NC)"
	@mkdir -p $(COCOTB_BUILD_DIR)
	$(GHDL) -a $(GHDL_STD) --workdir=$(COCOTB_BUILD_DIR) -P$(WORK_DIR) $(WRAP_SRC) || \
		(echo "$(RED)✗ Failed to analyze wrapper$(NC)" && exit 1)
	@echo "  ✓ axion_axi_lite_bridge_wrap.vhd"
	$(GHDL) -e $(GHDL_STD) --workdir=$(COCOTB_BUILD_DIR) -P$(WORK_DIR) -P$(COCOTB_BUILD_DIR) $(COCOTB_GHDL_GENERICS) axion_axi_lite_bridge_wrap || \
		(echo "$(RED)✗ Failed to elaborate wrapper$(NC)" && exit 1)
	@echo "$(GREEN)✓ Wrapper elaborated successfully$(NC)"

# Run cocotb tests
cocotb-test: cocotb-analyze
	@echo ""
	@echo "$(BLUE)================================================================================$(NC)"
	@echo "$(BLUE)  Axion Common - Running cocotb Tests$(NC)"
	@echo "$(BLUE)================================================================================$(NC)"
	@echo ""
	@if [ ! -f "$(COCOTB_VPI)" ]; then \
		echo "$(RED)Error: cocotb VPI library not found at $(COCOTB_VPI)$(NC)"; \
		echo "  Make sure the venv is activated and cocotb is installed."; \
		exit 1; \
	fi
	@echo "$(YELLOW)>>> Running cocotb simulation...$(NC)"
	@cd $(TB_DIR) && COCOTB_TEST_MODULES=$(COCOTB_TB) \
		PYTHONPATH=$(TB_DIR) \
		PYGPI_PYTHON_BIN=$(PYTHON) \
		$(GHDL) -r $(GHDL_STD) --workdir=$(COCOTB_BUILD_DIR) -P$(WORK_DIR) -P$(COCOTB_BUILD_DIR) \
		$(COCOTB_GHDL_GENERICS) \
		axion_axi_lite_bridge_wrap \
		--vpi=$(COCOTB_VPI) \
		--stop-time=1ms 2>&1 | tee $(BUILD_DIR)/cocotb_output.log; \
	GHDL_EXIT=$${PIPESTATUS[0]}; \
	if [ $$GHDL_EXIT -ne 0 ]; then \
		echo ""; \
		echo "$(RED)✗ cocotb tests FAILED (exit code: $$GHDL_EXIT)$(NC)"; \
		echo "$(BLUE)Log: $(BUILD_DIR)/cocotb_output.log$(NC)"; \
		exit $$GHDL_EXIT; \
	fi; \
	FAIL_COUNT=$$(grep -oP 'FAIL=\K[0-9]+' $(BUILD_DIR)/cocotb_output.log | tail -1); \
	if [ -n "$$FAIL_COUNT" ] && [ "$$FAIL_COUNT" -gt 0 ]; then \
		echo ""; \
		echo "$(RED)✗ cocotb tests FAILED ($$FAIL_COUNT test(s) failed)$(NC)"; \
		echo "$(BLUE)Log: $(BUILD_DIR)/cocotb_output.log$(NC)"; \
		exit 1; \
	fi
	@echo ""
	@echo "$(GREEN)✓ cocotb tests completed successfully$(NC)"
	@echo "$(BLUE)Log: $(BUILD_DIR)/cocotb_output.log$(NC)"

# Reproduce the exact CI environment locally.
# Builds the image with the CI tag first, then runs both test jobs as CI does.
# Run this before pushing to catch failures without waiting for GitHub Actions.
local-ci-test:
	@echo ""
	@echo "$(BLUE)================================================================================$(NC)"
	@echo "$(BLUE)  Local CI Simulation (axion-common:ci image)$(NC)"
	@echo "$(BLUE)================================================================================$(NC)"
	@echo "$(YELLOW)>>> Building $(CI_IMAGE) image...$(NC)"
	docker build -t $(CI_IMAGE) $(ROOT_DIR)
	@echo ""
	@echo "$(YELLOW)>>> Running VHDL tests (mirrors CI 'test' job)...$(NC)"
	docker run --rm -v $(ROOT_DIR):/workspace $(CI_IMAGE) make test
	@echo ""
	@echo "$(YELLOW)>>> Running cocotb tests (mirrors CI 'cocotb-test' job)...$(NC)"
	docker run --rm -v $(ROOT_DIR):/workspace $(CI_IMAGE) make cocotb-test
	@echo ""
	@echo "$(GREEN)✓ All local CI checks passed$(NC)"

# Run all tests inside Docker (builds image if not present)
docker-test:
	@echo ""
	@echo "$(BLUE)================================================================================$(NC)"
	@echo "$(BLUE)  Axion Common - Running Tests in Docker$(NC)"
	@echo "$(BLUE)================================================================================$(NC)"
	@echo ""
	@$(ROOT_DIR)/docker-run.sh make test

# Run SystemVerilog package cocotb tests via Verilator (Python runner)
cocotb-sv-pkg-test:
	@echo ""
	@echo "$(BLUE)================================================================================$(NC)"
	@echo "$(BLUE)  Axion Common - Running SV Package cocotb Tests (Verilator)$(NC)"
	@echo "$(BLUE)================================================================================$(NC)"
	@echo ""
	@if [ ! -f "$(AXION_HDL_VENV)/bin/python3" ]; then \
		echo "$(RED)Error: cocotb venv not found at $(AXION_HDL_VENV)$(NC)"; \
		echo "  Ensure the axion-hdl venv is present and cocotb is installed."; \
		exit 1; \
	fi
	@$(AXION_HDL_VENV)/bin/python3 $(TB_DIR)/run_sv_pkg_tests.py \
		> $(BUILD_DIR)/sv_pkg_cocotb_output.log 2>&1; \
	SV_EXIT=$$?; \
	cat $(BUILD_DIR)/sv_pkg_cocotb_output.log; \
	if [ $$SV_EXIT -ne 0 ]; then \
		echo ""; \
		echo "$(RED)✗ SV Package cocotb tests FAILED$(NC)"; \
		echo "$(BLUE)Log: $(BUILD_DIR)/sv_pkg_cocotb_output.log$(NC)"; \
		exit 1; \
	fi
	@echo ""
	@echo "$(GREEN)✓ SV Package cocotb tests completed successfully$(NC)"
	@echo "$(BLUE)Log: $(BUILD_DIR)/sv_pkg_cocotb_output.log$(NC)"

# Run tests using script (alternative)
test-script:
	@$(SCRIPT_DIR)/run_tests.sh

# Run tests and generate waveform
test-wave: elaborate
	@echo ""
	@echo "$(BLUE)================================================================================$(NC)"
	@echo "$(BLUE)  Axion Common - Running Tests with Waveform$(NC)"
	@echo "$(BLUE)================================================================================$(NC)"
	@echo ""
	@mkdir -p $(BUILD_DIR)
	@$(GHDL) -r $(GHDL_ELAB_FLAGS) axion_axi_lite_bridge_tb $(GHDL_RUN_FLAGS) --wave=$(WAVE_FILE)
	@echo ""
	@echo "$(GREEN)✓ Waveform generated: $(WAVE_FILE)$(NC)"
	@echo "$(YELLOW)To view: gtkwave $(WAVE_FILE)$(NC)"

# Run tests and open waveform in GTKWave
view-wave: test-wave
	@echo "$(YELLOW)>>> Opening GTKWave...$(NC)"
	@gtkwave $(WAVE_FILE) &

# Open existing waveform in GTKWave
wave:
	@if [ -f $(WAVE_FILE) ]; then \
		echo "$(YELLOW)>>> Opening GTKWave...$(NC)"; \
		gtkwave $(WAVE_FILE) & \
	else \
		echo "$(RED)Error: Waveform file not found. Run 'make test' first.$(NC)"; \
	fi

# Clean build artifacts
clean:
	@echo "$(YELLOW)>>> Cleaning build artifacts...$(NC)"
	@rm -rf $(BUILD_DIR)
	@rm -f *.cf
	@rm -f axion_axi_lite_bridge_tb
	@rm -f axion_axi_lite_bridge_wrap
	@rm -f e~*.o
	@echo "$(GREEN)✓ Clean complete$(NC)"

# Show help
help:
	@echo ""
	@echo "$(BLUE)Axion Common - Makefile$(NC)"
	@echo ""
	@echo "Available targets:"
	@echo "  $(YELLOW)make all$(NC)        - Analyze all VHDL sources (default)"
	@echo "  $(YELLOW)make analyze$(NC)    - Analyze VHDL sources"
	@echo "  $(YELLOW)make elaborate$(NC)  - Elaborate testbench"
	@echo "  $(YELLOW)make test$(NC)               - Run ALL tests: VHDL + SV package (default CI target)"
	@echo "  $(YELLOW)make docker-test$(NC)        - Run all tests inside Docker container"
	@echo "  $(YELLOW)make cocotb-test$(NC)        - Run VHDL cocotb tests only (GHDL)"
	@echo "  $(YELLOW)make cocotb-sv-pkg-test$(NC) - Run SV package cocotb tests only (Verilator)"
	@echo "  $(YELLOW)make wave$(NC)               - Open waveform in GTKWave"
	@echo "  $(YELLOW)make test-wave$(NC)      - Run tests and generate waveform (.ghw)"
	@echo "  $(YELLOW)make view-wave$(NC)      - Run tests and open waveform in GTKWave"
	@echo "  $(YELLOW)make report$(NC)         - Generate requirement verification report"
	@echo "  $(YELLOW)make clean$(NC)          - Remove build artifacts"
	@echo "  $(YELLOW)make help$(NC)           - Show this help message"
	@echo ""
	@echo "Output locations:"
	@echo "  Build directory:  $(BUILD_DIR)"
	@echo "  Test output:      $(TEST_OUTPUT)"
	@echo "  Report:           $(REPORT_FILE)"
	@echo ""
