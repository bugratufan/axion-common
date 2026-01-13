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
# Targets
################################################################################

.PHONY: all analyze test clean help dirs check-ghdl report

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

# Run tests
test: elaborate
	@echo ""
	@echo "$(BLUE)================================================================================$(NC)"
	@echo "$(BLUE)  Axion Common - Running Tests$(NC)"
	@echo "$(BLUE)================================================================================$(NC)"
	@echo ""
	@mkdir -p $(BUILD_DIR)
	@mkdir -p $(REPORT_DIR)
	@$(GHDL) -r $(GHDL_ELAB_FLAGS) axion_axi_lite_bridge_tb $(GHDL_RUN_FLAGS) --wave=$(WAVE_FILE) 2>&1 | tee $(TEST_OUTPUT)
	@echo ""
	@echo "$(GREEN)✓ Waveform generated: $(WAVE_FILE)$(NC)"
	@$(MAKE) -s report

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
	@echo "  $(YELLOW)make test$(NC)       - Run all tests and generate report"
	@echo "  $(YELLOW)make wave$(NC)       - Open waveform in GTKWave"
	@echo "  $(YELLOW)make test-wave$(NC)  - Run tests and generate waveform (.ghw)"
	@echo "  $(YELLOW)make view-wave$(NC)  - Run tests and open waveform in GTKWave"
	@echo "  $(YELLOW)make report$(NC)     - Generate requirement verification report"
	@echo "  $(YELLOW)make clean$(NC)      - Remove build artifacts"
	@echo "  $(YELLOW)make help$(NC)       - Show this help message"
	@echo ""
	@echo "Output locations:"
	@echo "  Build directory:  $(BUILD_DIR)"
	@echo "  Test output:      $(TEST_OUTPUT)"
	@echo "  Report:           $(REPORT_FILE)"
	@echo ""
