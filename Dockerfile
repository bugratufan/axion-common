################################################################################
# Axion Common - GHDL + cocotb + Verilator Docker Image
#
# Provides a reproducible build environment with:
#   - GHDL 4.1.0+ (for VHDL simulation)
#   - Verilator (for SystemVerilog simulation)
#   - Python 3 + cocotb + cocotb-tools (for Python-based testbenches)
#   - Make, bash, and standard tools
#
# Usage:
#   docker build -t axion-common:latest .
#   docker run --rm -v $(pwd):/workspace axion-common:latest make test
#
################################################################################

FROM ubuntu:24.04

LABEL maintainer="Bugra Tufan <bugra@example.com>"
LABEL description="GHDL + Verilator + cocotb environment for Axion Common"

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
    # Python and pip
    python3 \
    python3-pip \
    python3-venv \
    # VHDL simulator
    ghdl \
    # Verilator build dependencies (we build from source; apt ships 5.020 which is too old for cocotb 2.0)
    autoconf \
    flex \
    bison \
    libfl-dev \
    perl \
    # Utilities
    curl \
    wget \
    && rm -rf /var/lib/apt/lists/*

# Build and install Verilator 5.032 from source
# Ubuntu 24.04 ships 5.020 which lacks VerilatedVpi::evalNeeded() needed by cocotb 2.0
RUN git clone --depth=1 --branch v5.032 \
        https://github.com/verilator/verilator.git /tmp/verilator \
    && cd /tmp/verilator \
    && autoconf \
    && ./configure --prefix=/usr/local \
    && make -j$(nproc) \
    && make install \
    && rm -rf /tmp/verilator

# Verify tool versions
RUN ghdl --version && echo "✓ GHDL installed" && \
    verilator --version && echo "✓ Verilator installed"

# Install Python packages globally
# cocotb 2.0 pulls in cocotb-tools automatically; add it explicitly for clarity
RUN pip3 install --no-cache-dir --break-system-packages \
    cocotb \
    cocotb-tools \
    cocotb-bus

# Verify cocotb is importable and cocotb_tools runner is available
RUN python3 -c "import cocotb; print('cocotb', cocotb.__version__)" && \
    python3 -c "from cocotb_tools.runner import get_runner; print('✓ cocotb_tools.runner OK')"

# Set working directory
WORKDIR /workspace

# Default command: run all tests
CMD ["make", "test"]
