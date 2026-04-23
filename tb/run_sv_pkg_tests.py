#!/usr/bin/env python3
"""
run_sv_pkg_tests.py

Runs the axion_common_pkg SystemVerilog cocotb tests using the cocotb
Python runner API (cocotb 2.0+).  This approach invokes Verilator directly
without going through cocotb's Makefile.sim, so it is not subject to the
Makefile-level version gate.

Usage (from repo root or tb/ directory):
    python3 tb/run_sv_pkg_tests.py

Copyright (c) 2024 Bugra Tufan
MIT License
"""

import os
import sys
import shutil
import pathlib

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
THIS_DIR  = pathlib.Path(__file__).resolve().parent          # tb/
SRC_DIR   = THIS_DIR.parent / "src"
BUILD_DIR = THIS_DIR.parent / "build" / "sv_pkg_sim"

VERILOG_SOURCES = [
    SRC_DIR / "axion_common_pkg.sv",
    THIS_DIR / "tb_axion_common_pkg_wrap.sv",
]

TOPLEVEL    = "tb_axion_common_pkg_wrap"
TEST_MODULE = "tb_axion_common_pkg_cocotb"

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
def main():
    # Make sure the test module is importable
    sys.path.insert(0, str(THIS_DIR))

    try:
        from cocotb_tools.runner import get_runner
    except ImportError:
        print("ERROR: cocotb runner support not found.")
        print("Install 'cocotb' and 'cocotb-tools' in your active Python environment,")
        print("or activate the project's virtual environment before running this script.")
        print("If you use a custom interpreter/venv, run the script with that Python")
        print("or set the appropriate PYTHON/venv path override for your environment.")
        sys.exit(1)

    BUILD_DIR.mkdir(parents=True, exist_ok=True)

    # Clean stale build artifacts (Vtop.mk may contain hardcoded paths
    # from a different Python/cocotb installation)
    if BUILD_DIR.exists():
        shutil.rmtree(BUILD_DIR)
    BUILD_DIR.mkdir(parents=True, exist_ok=True)

    runner = get_runner("verilator")

    # -----------------------------------------------------------------------
    # Build
    # -----------------------------------------------------------------------
    runner.build(
        verilog_sources=[str(s) for s in VERILOG_SOURCES],
        hdl_toplevel=TOPLEVEL,
        build_dir=str(BUILD_DIR),
        always=True,
        build_args=[
            "--timing",
            "-Wno-WIDTHEXPAND",
            "-Wno-WIDTHTRUNC",
            "-Wno-UNUSED",
            "-Wno-UNOPTFLAT",
        ],
    )

    # -----------------------------------------------------------------------
    # Test
    # -----------------------------------------------------------------------
    runner.test(
        hdl_toplevel=TOPLEVEL,
        test_module=TEST_MODULE,
        build_dir=str(BUILD_DIR),
        results_xml=str(BUILD_DIR / "results.xml"),
    )


if __name__ == "__main__":
    main()
