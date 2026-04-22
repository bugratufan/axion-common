"""
tb_axion_common_pkg_cocotb.py

cocotb testbench for the axion_common_pkg SystemVerilog package.

Verifies all 19 requirement items:
  AXION-SV-PKG-001 … AXION-SV-PKG-019

DUT top  : tb_axion_common_pkg_wrap
Simulator: Verilator (via cocotb Makefile.sim)

Copyright (c) 2024 Bugra Tufan
MIT License
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

# ---------------------------------------------------------------------------
# Expected values (mirror of axion_common_pkg.sv)
# ---------------------------------------------------------------------------
C_AXI_DATA_WIDTH = 32
C_AXI_ADDR_WIDTH = 32
C_AXI_STRB_WIDTH = C_AXI_DATA_WIDTH // 8   # 4

C_AXI_RESP_OKAY   = 0b00
C_AXI_RESP_EXOKAY = 0b01
C_AXI_RESP_SLVERR = 0b10
C_AXI_RESP_DECERR = 0b11

# t_axi_lite_m2s packed width
#   awaddr(32) + awvalid(1) + awprot(3) + wdata(32) + wstrb(4) + wvalid(1)
#   + bready(1) + araddr(32) + arvalid(1) + arprot(3) + rready(1) = 111
M2S_WIDTH = 32 + 1 + 3 + 32 + 4 + 1 + 1 + 32 + 1 + 3 + 1   # 111

# t_axi_lite_s2m packed width
#   awready(1) + wready(1) + bresp(2) + bvalid(1) + arready(1)
#   + rdata(32) + rresp(2) + rvalid(1) = 41
S2M_WIDTH = 1 + 1 + 2 + 1 + 1 + 32 + 2 + 1   # 41


# ---------------------------------------------------------------------------
# Shared fixture
# ---------------------------------------------------------------------------
async def _init(dut):
    """Start 100 MHz clock, drive i_resp=0 and wait 2 edges to settle."""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    dut.i_resp.value = 0
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)


# ===========================================================================
# Constants
# ===========================================================================

@cocotb.test()
async def test_data_width(dut):
    """AXION-SV-PKG-001: C_AXI_DATA_WIDTH == 32"""
    await _init(dut)
    got = int(dut.o_data_width.value)
    assert got == C_AXI_DATA_WIDTH, \
        f"[FAIL] AXION-SV-PKG-001: expected {C_AXI_DATA_WIDTH}, got {got}"
    dut._log.info("[PASS] AXION-SV-PKG-001: C_AXI_DATA_WIDTH == 32")


@cocotb.test()
async def test_addr_width(dut):
    """AXION-SV-PKG-002: C_AXI_ADDR_WIDTH == 32"""
    await _init(dut)
    got = int(dut.o_addr_width.value)
    assert got == C_AXI_ADDR_WIDTH, \
        f"[FAIL] AXION-SV-PKG-002: expected {C_AXI_ADDR_WIDTH}, got {got}"
    dut._log.info("[PASS] AXION-SV-PKG-002: C_AXI_ADDR_WIDTH == 32")


@cocotb.test()
async def test_strb_width(dut):
    """AXION-SV-PKG-003: C_AXI_STRB_WIDTH == 4"""
    await _init(dut)
    got = int(dut.o_strb_width.value)
    assert got == C_AXI_STRB_WIDTH, \
        f"[FAIL] AXION-SV-PKG-003: expected {C_AXI_STRB_WIDTH}, got {got}"
    dut._log.info("[PASS] AXION-SV-PKG-003: C_AXI_STRB_WIDTH == 4")


@cocotb.test()
async def test_resp_okay(dut):
    """AXION-SV-PKG-004: C_AXI_RESP_OKAY == 2'b00"""
    await _init(dut)
    got = int(dut.o_resp_okay.value)
    assert got == C_AXI_RESP_OKAY, \
        f"[FAIL] AXION-SV-PKG-004: expected {C_AXI_RESP_OKAY}, got {got}"
    dut._log.info("[PASS] AXION-SV-PKG-004: C_AXI_RESP_OKAY == 2'b00")


@cocotb.test()
async def test_resp_exokay(dut):
    """AXION-SV-PKG-005: C_AXI_RESP_EXOKAY == 2'b01"""
    await _init(dut)
    got = int(dut.o_resp_exokay.value)
    assert got == C_AXI_RESP_EXOKAY, \
        f"[FAIL] AXION-SV-PKG-005: expected {C_AXI_RESP_EXOKAY}, got {got}"
    dut._log.info("[PASS] AXION-SV-PKG-005: C_AXI_RESP_EXOKAY == 2'b01")


@cocotb.test()
async def test_resp_slverr(dut):
    """AXION-SV-PKG-006: C_AXI_RESP_SLVERR == 2'b10"""
    await _init(dut)
    got = int(dut.o_resp_slverr.value)
    assert got == C_AXI_RESP_SLVERR, \
        f"[FAIL] AXION-SV-PKG-006: expected {C_AXI_RESP_SLVERR}, got {got}"
    dut._log.info("[PASS] AXION-SV-PKG-006: C_AXI_RESP_SLVERR == 2'b10")


@cocotb.test()
async def test_resp_decerr(dut):
    """AXION-SV-PKG-007: C_AXI_RESP_DECERR == 2'b11"""
    await _init(dut)
    got = int(dut.o_resp_decerr.value)
    assert got == C_AXI_RESP_DECERR, \
        f"[FAIL] AXION-SV-PKG-007: expected {C_AXI_RESP_DECERR}, got {got}"
    dut._log.info("[PASS] AXION-SV-PKG-007: C_AXI_RESP_DECERR == 2'b11")


# ===========================================================================
# Utility functions — f_axi_resp_is_ok
# ===========================================================================

@cocotb.test()
async def test_resp_is_ok_okay(dut):
    """AXION-SV-PKG-008: f_axi_resp_is_ok(OKAY) == 1"""
    await _init(dut)
    dut.i_resp.value = C_AXI_RESP_OKAY
    await RisingEdge(dut.clk)
    assert int(dut.o_resp_is_ok.value) == 1, \
        "[FAIL] AXION-SV-PKG-008: f_axi_resp_is_ok(OKAY) should be 1"
    dut._log.info("[PASS] AXION-SV-PKG-008: f_axi_resp_is_ok(OKAY) == 1")


@cocotb.test()
async def test_resp_is_ok_exokay(dut):
    """AXION-SV-PKG-009: f_axi_resp_is_ok(EXOKAY) == 1"""
    await _init(dut)
    dut.i_resp.value = C_AXI_RESP_EXOKAY
    await RisingEdge(dut.clk)
    assert int(dut.o_resp_is_ok.value) == 1, \
        "[FAIL] AXION-SV-PKG-009: f_axi_resp_is_ok(EXOKAY) should be 1"
    dut._log.info("[PASS] AXION-SV-PKG-009: f_axi_resp_is_ok(EXOKAY) == 1")


@cocotb.test()
async def test_resp_is_ok_slverr(dut):
    """AXION-SV-PKG-010: f_axi_resp_is_ok(SLVERR) == 0"""
    await _init(dut)
    dut.i_resp.value = C_AXI_RESP_SLVERR
    await RisingEdge(dut.clk)
    assert int(dut.o_resp_is_ok.value) == 0, \
        "[FAIL] AXION-SV-PKG-010: f_axi_resp_is_ok(SLVERR) should be 0"
    dut._log.info("[PASS] AXION-SV-PKG-010: f_axi_resp_is_ok(SLVERR) == 0")


@cocotb.test()
async def test_resp_is_ok_decerr(dut):
    """AXION-SV-PKG-011: f_axi_resp_is_ok(DECERR) == 0"""
    await _init(dut)
    dut.i_resp.value = C_AXI_RESP_DECERR
    await RisingEdge(dut.clk)
    assert int(dut.o_resp_is_ok.value) == 0, \
        "[FAIL] AXION-SV-PKG-011: f_axi_resp_is_ok(DECERR) should be 0"
    dut._log.info("[PASS] AXION-SV-PKG-011: f_axi_resp_is_ok(DECERR) == 0")


# ===========================================================================
# Utility functions — f_axi_resp_is_error
# ===========================================================================

@cocotb.test()
async def test_resp_is_error_okay(dut):
    """AXION-SV-PKG-012: f_axi_resp_is_error(OKAY) == 0"""
    await _init(dut)
    dut.i_resp.value = C_AXI_RESP_OKAY
    await RisingEdge(dut.clk)
    assert int(dut.o_resp_is_error.value) == 0, \
        "[FAIL] AXION-SV-PKG-012: f_axi_resp_is_error(OKAY) should be 0"
    dut._log.info("[PASS] AXION-SV-PKG-012: f_axi_resp_is_error(OKAY) == 0")


@cocotb.test()
async def test_resp_is_error_exokay(dut):
    """AXION-SV-PKG-013: f_axi_resp_is_error(EXOKAY) == 0"""
    await _init(dut)
    dut.i_resp.value = C_AXI_RESP_EXOKAY
    await RisingEdge(dut.clk)
    assert int(dut.o_resp_is_error.value) == 0, \
        "[FAIL] AXION-SV-PKG-013: f_axi_resp_is_error(EXOKAY) should be 0"
    dut._log.info("[PASS] AXION-SV-PKG-013: f_axi_resp_is_error(EXOKAY) == 0")


@cocotb.test()
async def test_resp_is_error_slverr(dut):
    """AXION-SV-PKG-014: f_axi_resp_is_error(SLVERR) == 1"""
    await _init(dut)
    dut.i_resp.value = C_AXI_RESP_SLVERR
    await RisingEdge(dut.clk)
    assert int(dut.o_resp_is_error.value) == 1, \
        "[FAIL] AXION-SV-PKG-014: f_axi_resp_is_error(SLVERR) should be 1"
    dut._log.info("[PASS] AXION-SV-PKG-014: f_axi_resp_is_error(SLVERR) == 1")


@cocotb.test()
async def test_resp_is_error_decerr(dut):
    """AXION-SV-PKG-015: f_axi_resp_is_error(DECERR) == 1"""
    await _init(dut)
    dut.i_resp.value = C_AXI_RESP_DECERR
    await RisingEdge(dut.clk)
    assert int(dut.o_resp_is_error.value) == 1, \
        "[FAIL] AXION-SV-PKG-015: f_axi_resp_is_error(DECERR) should be 1"
    dut._log.info("[PASS] AXION-SV-PKG-015: f_axi_resp_is_error(DECERR) == 1")


# ===========================================================================
# Struct metadata
# ===========================================================================

@cocotb.test()
async def test_m2s_struct_width(dut):
    """AXION-SV-PKG-016: $bits(t_axi_lite_m2s) == 111"""
    await _init(dut)
    got = int(dut.o_m2s_width.value)
    assert got == M2S_WIDTH, \
        f"[FAIL] AXION-SV-PKG-016: expected {M2S_WIDTH}, got {got}"
    dut._log.info(f"[PASS] AXION-SV-PKG-016: $bits(t_axi_lite_m2s) == {M2S_WIDTH}")


@cocotb.test()
async def test_s2m_struct_width(dut):
    """AXION-SV-PKG-017: $bits(t_axi_lite_s2m) == 41"""
    await _init(dut)
    got = int(dut.o_s2m_width.value)
    assert got == S2M_WIDTH, \
        f"[FAIL] AXION-SV-PKG-017: expected {S2M_WIDTH}, got {got}"
    dut._log.info(f"[PASS] AXION-SV-PKG-017: $bits(t_axi_lite_s2m) == {S2M_WIDTH}")


# ===========================================================================
# Init constants
# ===========================================================================

@cocotb.test()
async def test_m2s_init_all_zero(dut):
    """AXION-SV-PKG-018: C_AXI_LITE_M2S_INIT — sampled fields are all zero"""
    await _init(dut)
    assert int(dut.o_m2s_awvalid_init.value) == 0, \
        "[FAIL] AXION-SV-PKG-018: M2S_INIT.awvalid not zero"
    assert int(dut.o_m2s_rready_init.value) == 0, \
        "[FAIL] AXION-SV-PKG-018: M2S_INIT.rready not zero"
    dut._log.info("[PASS] AXION-SV-PKG-018: C_AXI_LITE_M2S_INIT fields all zero")


@cocotb.test()
async def test_s2m_init_default(dut):
    """AXION-SV-PKG-019: C_AXI_LITE_S2M_INIT — valid/resp fields at default"""
    await _init(dut)
    assert int(dut.o_s2m_bvalid_init.value) == 0, \
        "[FAIL] AXION-SV-PKG-019: S2M_INIT.bvalid not zero"
    assert int(dut.o_s2m_rvalid_init.value) == 0, \
        "[FAIL] AXION-SV-PKG-019: S2M_INIT.rvalid not zero"
    assert int(dut.o_s2m_bresp_init.value) == C_AXI_RESP_OKAY, \
        "[FAIL] AXION-SV-PKG-019: S2M_INIT.bresp not OKAY"
    assert int(dut.o_s2m_rresp_init.value) == C_AXI_RESP_OKAY, \
        "[FAIL] AXION-SV-PKG-019: S2M_INIT.rresp not OKAY"
    dut._log.info("[PASS] AXION-SV-PKG-019: C_AXI_LITE_S2M_INIT fields at default")
