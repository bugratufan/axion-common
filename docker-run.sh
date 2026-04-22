#!/bin/bash
################################################################################
# Axion Common - Docker Test Runner
#
# Builds (or pulls) the Docker image and runs the requested command inside it.
# By default runs 'make test' which executes ALL tests:
#   - VHDL simulation tests (GHDL)
#   - SystemVerilog package cocotb tests (Verilator)
#
# Usage:
#   ./docker-run.sh [command] [args...]
#
# Commands:
#   make [target]      Run a Make target (default: test)
#   bash               Open interactive shell in container
#   sh script.sh       Run arbitrary script/command
#
# Examples:
#   ./docker-run.sh                    # Run ALL tests (default)
#   ./docker-run.sh make test          # Run ALL tests (explicit)
#   ./docker-run.sh make cocotb-test   # Run VHDL cocotb tests only
#   ./docker-run.sh bash               # Interactive shell
#
# Copyright (c) 2024 Bugra Tufan
# MIT License
################################################################################

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Get repository info
REPO_OWNER=$(git -C "$SCRIPT_DIR" config --get remote.origin.url | grep -oP '(?<=/)[^/]+(?=/[^/]+\.git)' || echo "bugratufan")
IMAGE_NAME="axion-common:latest"
REGISTRY_IMAGE="ghcr.io/$REPO_OWNER/axion-common:latest"

# Check if Docker is installed
if ! command -v docker &> /dev/null; then
    echo -e "${RED}✗ Docker not found. Please install Docker first.${NC}"
    echo "  https://docs.docker.com/get-docker/"
    exit 1
fi

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

# Check if Docker image exists locally
check_image() {
    if docker image inspect "$IMAGE_NAME" &>/dev/null; then
        return 0
    else
        return 1
    fi
}

# Try to pull from registry, fall back to building
setup_image() {
    print_step "Setting up Docker image..."

    if check_image; then
        print_success "Docker image already exists: $IMAGE_NAME"
        return 0
    fi

    # Try to pull from registry
    if docker pull "$REGISTRY_IMAGE" 2>/dev/null; then
        print_success "Pulled image from registry: $REGISTRY_IMAGE"
        docker tag "$REGISTRY_IMAGE" "$IMAGE_NAME"
        return 0
    fi

    # Build locally
    print_step "Building Docker image locally..."
    docker build --network=host -t "$IMAGE_NAME" "$SCRIPT_DIR"
    print_success "Docker image built: $IMAGE_NAME"
}

# Show help
show_help() {
    cat << 'HELP'
Axion Common - Docker Test Runner

Usage: docker-run.sh [command] [args...]

Commands:
  make [target]      Run a Make target (default: test)
  bash               Open interactive shell in container
  sh [script]        Run arbitrary script/command

Make targets:
  make test              Run ALL tests: VHDL + SV package (default)
  make cocotb-test       Run VHDL cocotb tests (GHDL)
  make cocotb-sv-pkg-test Run SV package tests (Verilator)
  make all               Analyze VHDL sources
  make clean             Clean build artifacts
  make help              Show Makefile help

Examples:
  ./docker-run.sh                    # Run ALL tests (default)
  ./docker-run.sh make test          # Run ALL tests (explicit)
  ./docker-run.sh make cocotb-test   # Run VHDL cocotb tests only
  ./docker-run.sh bash               # Interactive shell

Environment:
  DOCKER_OPTS        Additional Docker options (e.g., '-e DEBUG=1')

HELP
}

# Main execution
print_header "Axion Common - Docker Test Runner"

# Parse arguments
if [ $# -eq 0 ]; then
    # Default: run make test
    CMD="make test"
else
    case "$1" in
        -h|--help)
            show_help
            exit 0
            ;;
        bash)
            CMD="/bin/bash"
            ;;
        sh)
            shift
            CMD="sh $@"
            ;;
        make)
            shift
            CMD="make $@"
            ;;
        *)
            CMD="$@"
            ;;
    esac
fi

# Setup image
setup_image

# Run tests in Docker
print_step "Running: $CMD"
echo ""

docker run --rm \
    -v "$SCRIPT_DIR:/workspace" \
    -w "/workspace" \
    ${DOCKER_OPTS} \
    "$IMAGE_NAME" \
    bash -c "$CMD"

EXIT_CODE=$?
if [ $EXIT_CODE -ne 0 ]; then
    echo ""
    echo -e "${RED}✗ Command FAILED with exit code: $EXIT_CODE${NC}"
    exit $EXIT_CODE
fi

print_success "Command completed successfully"
