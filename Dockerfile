################################################################################
# Axion Common - GHDL + cocotb Docker Image
#
# Provides a reproducible build environment with:
#   - GHDL 4.1.0 (for VHDL simulation)
#   - Python 3 + cocotb (for Python-based testbenches)
#   - Make, bash, and standard tools
#
# Usage:
#   docker build -t ghcr.io/bugratufan/axion-common:latest .
#   docker run --rm -v $(pwd):/workspace axion-common make test
#
################################################################################

FROM ubuntu:22.04

LABEL maintainer="Bugra Tufan <bugra@example.com>"
LABEL description="GHDL 4.1.0 + cocotb environment for Axion Common"

# Set non-interactive mode
ENV DEBIAN_FRONTEND=noninteractive

# Install dependencies
RUN apt-get update && apt-get install -y \
    # Build tools
    build-essential \
    git \
    make \
    # GHDL dependencies
    ghdl \
    ghdl-llvm \
    # Python and cocotb
    python3 \
    python3-pip \
    python3-venv \
    # Utilities
    curl \
    wget \
    # For waveform viewing (optional)
    gtkwave \
    && rm -rf /var/lib/apt/lists/*

# Verify GHDL version
RUN ghdl --version

# Install Python packages globally (for simulations in the container)
RUN pip3 install --no-cache-dir \
    cocotb==1.8.1 \
    cocotb-bus==0.3.1

# Set working directory
WORKDIR /workspace

# Default command: run bash
CMD ["/bin/bash"]
