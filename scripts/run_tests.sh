#!/bin/bash
################################################################################
# Axion Common - Test Runner Script
#
# Runs VHDL tests using GHDL and generates requirement verification report
#
# Usage: ./run_tests.sh [options]
#   Options:
#     -v, --verbose    Show detailed output
#     -c, --clean      Clean build artifacts before running
#     -h, --help       Show this help message
#
# Copyright (c) 2024 Bugra Tufan
# MIT License
################################################################################

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# Build directories
BUILD_DIR="$ROOT_DIR/build"
WORK_DIR="$BUILD_DIR/work"
REPORT_DIR="$BUILD_DIR/reports"

# Source directories
SRC_DIR="$ROOT_DIR/src"
TB_DIR="$ROOT_DIR/tb"

# GHDL settings
GHDL_FLAGS="--std=08 --workdir=$WORK_DIR -P$WORK_DIR"
GHDL_ELAB_FLAGS="--std=08 --workdir=$WORK_DIR -P$WORK_DIR"
GHDL_RUN_FLAGS="--stop-time=100ms"

# Test output file
TEST_OUTPUT="$BUILD_DIR/test_output.log"
REPORT_FILE="$REPORT_DIR/requirement_verification.md"

# Options
VERBOSE=0
CLEAN=0

################################################################################
# Functions
################################################################################

print_header() {
    echo ""
    echo -e "${BLUE}================================================================================${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}================================================================================${NC}"
    echo ""
}

print_step() {
    echo -e "${YELLOW}>>> $1${NC}"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

show_help() {
    echo "Axion Common - Test Runner Script"
    echo ""
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  -v, --verbose    Show detailed output"
    echo "  -c, --clean      Clean build artifacts before running"
    echo "  -h, --help       Show this help message"
    echo ""
}

clean_build() {
    print_step "Cleaning build directory..."
    rm -rf "$BUILD_DIR"
    print_success "Build directory cleaned"
}

setup_directories() {
    print_step "Setting up directories..."
    mkdir -p "$WORK_DIR"
    mkdir -p "$REPORT_DIR"
    print_success "Directories created"
}

check_ghdl() {
    print_step "Checking GHDL installation..."
    if ! command -v ghdl &> /dev/null; then
        print_error "GHDL not found. Please install GHDL first."
        echo "  Ubuntu/Debian: sudo apt install ghdl"
        echo "  Fedora: sudo dnf install ghdl"
        echo "  macOS: brew install ghdl"
        exit 1
    fi
    GHDL_VERSION=$(ghdl --version | head -n1)
    print_success "GHDL found: $GHDL_VERSION"
}

analyze_sources() {
    print_step "Analyzing VHDL sources..."
    
    # Analyze package first
    echo "  Analyzing axion_common_pkg.vhd..."
    ghdl -a $GHDL_FLAGS --work=axion_common "$SRC_DIR/axion_common_pkg.vhd"
    
    # Analyze bridge module
    echo "  Analyzing axion_axi_lite_bridge.vhd..."
    ghdl -a $GHDL_FLAGS --work=axion_common "$SRC_DIR/axion_axi_lite_bridge.vhd"
    
    # Analyze testbench
    echo "  Analyzing axion_axi_lite_bridge_tb.vhd..."
    ghdl -a $GHDL_FLAGS "$TB_DIR/axion_axi_lite_bridge_tb.vhd"
    
    print_success "All sources analyzed successfully"
}

elaborate_testbench() {
    print_step "Elaborating testbench..."
    ghdl -e $GHDL_ELAB_FLAGS axion_axi_lite_bridge_tb
    print_success "Testbench elaborated successfully"
}

run_tests() {
    print_step "Running tests..."
    
    # Run simulation and capture output
    ghdl -r $GHDL_ELAB_FLAGS axion_axi_lite_bridge_tb $GHDL_RUN_FLAGS 2>&1 | tee "$TEST_OUTPUT"
    
    print_success "Tests completed"
}

generate_report() {
    print_step "Generating requirement verification report..."
    
    # Parse test output and generate report
    cat > "$REPORT_FILE" << 'REPORT_HEADER'
# Requirement Verification Report

| Field | Value |
|-------|-------|
| Date | $(date +%Y-%m-%d) |
| Time | $(date +%H:%M:%S) |
| Tool | GHDL |

## Test Results

| Requirement ID | Test Case | Status |
|----------------|-----------|--------|
REPORT_HEADER

    # Update date in report
    sed -i "s/\$(date +%Y-%m-%d)/$(date +%Y-%m-%d)/g" "$REPORT_FILE"
    sed -i "s/\$(date +%H:%M:%S)/$(date +%H:%M:%S)/g" "$REPORT_FILE"

    # Requirements to check
    REQUIREMENTS=(
        "AXI-LITE-001:Write Address Channel Handshake:TC_AXI_WRITE_ADDR_HANDSHAKE"
        "AXI-LITE-002:Write Data Channel Handshake:TC_AXI_WRITE_DATA_HANDSHAKE"
        "AXI-LITE-003:Write Response Channel Handshake:TC_AXI_WRITE_RESP_HANDSHAKE"
        "AXI-LITE-004:Read Address Channel Handshake:TC_AXI_READ_ADDR_HANDSHAKE"
        "AXI-LITE-005:Read Data Channel Handshake:TC_AXI_READ_DATA_HANDSHAKE"
        "AXI-LITE-006:OKAY Response Code:TC_AXI_OKAY_RESPONSE"
        "AXI-LITE-007:SLVERR Response Code:TC_AXI_SLVERR_RESPONSE"
        "AXI-LITE-008:Reset Behavior:TC_AXI_RESET_BEHAVIOR"
        "AXION-COMMON-001:Request Broadcast:TC_BRIDGE_REQUEST_BROADCAST"
        "AXION-COMMON-002:First OKAY Response:TC_BRIDGE_FIRST_OKAY"
        "AXION-COMMON-003:All Error Response:TC_BRIDGE_ALL_ERROR"
        "AXION-COMMON-004:Timeout Mechanism:TC_BRIDGE_TIMEOUT"
        "AXION-COMMON-005:Generic Slave Count:TC_BRIDGE_SLAVE_COUNT"
        "AXION-COMMON-006:Write Transaction Sequence:TC_BRIDGE_WRITE_SEQUENCE"
        "AXION-COMMON-007:Read Transaction Sequence:TC_BRIDGE_READ_SEQUENCE"
        "AXION-COMMON-008:Back-to-Back Transactions:TC_BRIDGE_BACK_TO_BACK"
        "AXION-COMMON-009:Partial Slave Response:TC_BRIDGE_PARTIAL_RESPONSE"
        "AXION-COMMON-010:Address Transparency:TC_BRIDGE_ADDR_TRANSPARENCY"
        "AXION-COMMON-011:Data Integrity:TC_BRIDGE_DATA_INTEGRITY"
        "AXION-COMMON-012:Reset Recovery:TC_BRIDGE_RESET_RECOVERY"
    )

    PASSED=0
    FAILED=0
    
    for req in "${REQUIREMENTS[@]}"; do
        IFS=':' read -r REQ_ID REQ_NAME TC_NAME <<< "$req"
        
        # Check if requirement passed in test output
        if grep -q "\[PASS\] $REQ_ID" "$TEST_OUTPUT"; then
            STATUS="✅ PASS"
            ((PASSED++))
        elif grep -q "\[FAIL\] $REQ_ID" "$TEST_OUTPUT"; then
            STATUS="❌ FAIL"
            ((FAILED++))
        else
            STATUS="⚠️ NOT RUN"
        fi
        
        echo "| $REQ_ID | $TC_NAME | $STATUS |" >> "$REPORT_FILE"
    done
    
    # Add summary
    cat >> "$REPORT_FILE" << SUMMARY

## Summary

| Metric | Count |
|--------|-------|
| Total Requirements | $((PASSED + FAILED)) |
| Passed | $PASSED |
| Failed | $FAILED |
| Pass Rate | $(echo "scale=1; $PASSED * 100 / ($PASSED + $FAILED)" | bc)% |

SUMMARY

    if [ $FAILED -eq 0 ]; then
        echo "## Result: ✅ ALL REQUIREMENTS VERIFIED" >> "$REPORT_FILE"
    else
        echo "## Result: ❌ SOME REQUIREMENTS FAILED" >> "$REPORT_FILE"
    fi
    
    print_success "Report generated: $REPORT_FILE"
    
    # Return counts for exit code
    echo "$PASSED:$FAILED"
}

print_summary() {
    local results=$1
    IFS=':' read -r PASSED FAILED <<< "$results"
    
    print_header "TEST SUMMARY"
    
    echo "  Total Requirements: $((PASSED + FAILED))"
    echo "  Passed:            $PASSED"
    echo "  Failed:            $FAILED"
    echo ""
    
    if [ "$FAILED" -eq 0 ]; then
        print_success "ALL TESTS PASSED"
        return 0
    else
        print_error "SOME TESTS FAILED"
        return 1
    fi
}

################################################################################
# Main
################################################################################

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -v|--verbose)
            VERBOSE=1
            shift
            ;;
        -c|--clean)
            CLEAN=1
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# Main execution
print_header "Axion Common - Test Runner"

if [ $CLEAN -eq 1 ]; then
    clean_build
fi

check_ghdl
setup_directories
analyze_sources
elaborate_testbench
run_tests
RESULTS=$(generate_report)

print_summary "$RESULTS"
EXIT_CODE=$?

echo ""
echo "Report available at: $REPORT_FILE"
echo "Test output at: $TEST_OUTPUT"
echo ""

exit $EXIT_CODE
