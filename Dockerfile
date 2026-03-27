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
    # Python dev headers (required for cocotb)
    python3-dev \
    # Python and cocotb
    python3 \
    python3-pip \
    python3-venv \
    # Utilities
    curl \
    wget \
    xz-utils \
    # For waveform viewing (optional)
    gtkwave \
    && rm -rf /var/lib/apt/lists/*

# Install GHDL 4.1.0 from GitHub release (NOT from apt which only has 1.0.0)
RUN cd /tmp && \
    wget -q https://github.com/ghdl/ghdl/releases/download/v4.1.0/ghdl-gha-ubuntu-22.04-llvm.tgz && \
    tar xzf ghdl-gha-ubuntu-22.04-llvm.tgz && \
    cp bin/ghdl /usr/local/bin/ && \
    chmod +x /usr/local/bin/ghdl && \
    rm -rf /tmp/ghdl-gha-* /tmp/bin

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
