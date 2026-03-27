################################################################################
# Axion Common - GHDL + cocotb Docker Image
#
# Provides a reproducible build environment with:
#   - GHDL 4.1.0 LLVM (for VHDL simulation)
#   - Python 3 + cocotb (for Python-based testbenches)
#   - Make, bash, and standard tools
#
# Based on official ghdl/ghdl:llvm Docker image for complete GHDL support
#
# Usage:
#   docker build -t ghcr.io/bugratufan/axion-common:latest .
#   docker run --rm -v $(pwd):/workspace axion-common make test
#
################################################################################

FROM ghdl/ghdl:llvm

LABEL maintainer="Bugra Tufan <bugra@example.com>"
LABEL description="GHDL 4.1.0 LLVM + cocotb environment for Axion Common"

# Set non-interactive mode
ENV DEBIAN_FRONTEND=noninteractive

# Install additional tools and Python
RUN apt-get update && apt-get install -y \
    # Build tools
    build-essential \
    git \
    make \
    # Python dev headers (required for cocotb)
    python3-dev \
    # Python and cocotb (if not already in base image)
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

# Upgrade pip, setuptools, wheel first (fixes many build issues)
RUN pip3 install --upgrade pip setuptools wheel

# Install Python packages globally (for simulations in the container)
RUN pip3 install --no-cache-dir \
    cocotb \
    cocotb-bus

# Set working directory
WORKDIR /workspace

# Default command: run bash
CMD ["/bin/bash"]
