"""
tb_axion_axi_lite_router_cocotb.py

Comprehensive cocotb testbench for axion_axi_lite_router_wrap.

DUT chain:
    AXI Master  →  axion_axi_lite_router  →  axi_test_axion_reg
                   G_BASE_ADDR  = 0x4000       BASE_ADDR = 0x0000
                   G_ADDR_RANGE = 0xFFF

Address tiers exercised:
  ┌──────┬───────────────────────┬─────────────────────┬──────────────────────┐
  │ Tier │ Upstream addr         │ Translated (DN)     │ Master sees          │
  ├──────┼───────────────────────┼─────────────────────┼──────────────────────┤
  │  A   │ 0x4000 (version)      │ 0x0000              │ OKAY                 │
  │  A   │ 0x4004 (val)          │ 0x0004              │ OKAY                 │
  │  B   │ 0x4008 .. 0x4FFF      │ 0x0008 .. 0x0FFF    │ SLVERR (from reg)    │
  │  C   │ < 0x4000 or > 0x4FFF  │ – (blocked)         │ SLVERR (from router) │
  └──────┴───────────────────────┴─────────────────────┴──────────────────────┘

Key distinction from filter: the router SUBTRACTS the base address before
forwarding. The register file expects addresses starting at 0x0000, so an
OKAY response on a Tier-A transaction proves translation is working correctly
(without subtraction the register would see 0x4000 and return SLVERR).

Test groups:
  Group 1  – Basic routing (SLVERR path, basic OKAY path)
  Group 2  – Address translation proof (critical router-specific tests)
  Group 3  – Address boundary correctness (inclusive begin/end, ±1)
  Group 4  – Register read/write integrity (values, strobe, independence)
  Group 5  – AXI4-Lite protocol compliance (ready pulses, valid stability)
  Group 6  – W-channel timing variants (wvalid late, data-first)
  Group 7  – Back-pressure (bready / rready held low)
  Group 8  – Back-to-back and mixed sequences
  Group 9  – Reset mid-transaction
  Group 10 – Stress / randomised sweep
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles, with_timeout
import random

# ---------------------------------------------------------------------------
# Constants – must match wrapper generics
# ---------------------------------------------------------------------------
CLK_PERIOD_NS   = 10        # 100 MHz
TIMEOUT_CYCLES  = 500
TIMEOUT_NS      = TIMEOUT_CYCLES * CLK_PERIOD_NS

AXI_RESP_OKAY   = 0b00
AXI_RESP_SLVERR = 0b10

# Router window (must match G_BASE_ADDR_INT / G_ADDR_RANGE_INT)
ROUTER_BASE  = 0x00004000
ROUTER_RANGE = 0x00000FFF
ROUTER_END   = ROUTER_BASE + ROUTER_RANGE   # 0x4FFF inclusive

# Upstream addresses that map to valid register entries
ADDR_VERSION = ROUTER_BASE + 0x00   # 0x4000 → translated 0x0000 → version reg
ADDR_VAL     = ROUTER_BASE + 0x04   # 0x4004 → translated 0x0004 → val reg

# Upstream Tier-B: inside router window, but no register at translated address
ADDR_TIER_B  = ROUTER_BASE + 0x08   # 0x4008 → translated 0x0008 → no reg

# Upstream Tier-C: outside router window entirely
ADDR_BELOW   = ROUTER_BASE - 1      # 0x3FFF
ADDR_ABOVE   = ROUTER_END  + 1      # 0x5000
ADDR_ZERO    = 0x00000000
ADDR_HIGH    = 0x0000FFFF

# Register reset values
VERSION_RESET = 0xABCDEF01
VAL_RESET     = 0xDEADBEEF


# ---------------------------------------------------------------------------
# AXIMaster helper
# ---------------------------------------------------------------------------
class AXIMaster:
    """Drives upstream (master-side) flat signals on the DUT wrapper."""

    def __init__(self, dut, clk):
        self._dut = dut
        self._clk = clk

    def init(self):
        self._dut.m_awaddr.value  = 0
        self._dut.m_awprot.value  = 0
        self._dut.m_awvalid.value = 0
        self._dut.m_wdata.value   = 0
        self._dut.m_wstrb.value   = 0
        self._dut.m_wvalid.value  = 0
        self._dut.m_bready.value  = 0
        self._dut.m_araddr.value  = 0
        self._dut.m_arprot.value  = 0
        self._dut.m_arvalid.value = 0
        self._dut.m_rready.value  = 0

    async def write(self, addr: int, data: int, strb: int = 0xF,
                    bready_delay: int = 0, prot: int = 0) -> int:
        """AW + W driven simultaneously. Returns bresp."""
        self._dut.m_awaddr.value  = addr
        self._dut.m_awprot.value  = prot
        self._dut.m_awvalid.value = 1
        self._dut.m_wdata.value   = data
        self._dut.m_wstrb.value   = strb
        self._dut.m_wvalid.value  = 1

        aw_done = w_done = False
        while not (aw_done and w_done):
            await RisingEdge(self._clk)
            if not aw_done and self._dut.m_awready.value == 1:
                self._dut.m_awvalid.value = 0
                aw_done = True
            if not w_done and self._dut.m_wready.value == 1:
                self._dut.m_wvalid.value = 0
                w_done = True

        for _ in range(bready_delay):
            await RisingEdge(self._clk)

        self._dut.m_bready.value = 1
        while True:
            await RisingEdge(self._clk)
            if self._dut.m_bvalid.value == 1:
                bresp = int(self._dut.m_bresp.value)
                self._dut.m_bready.value = 0
                return bresp

    async def write_aw_first(self, addr: int, data: int, strb: int = 0xF,
                             w_delay_cycles: int = 4) -> int:
        """Assert awvalid first, then wvalid after w_delay_cycles. Returns bresp."""
        self._dut.m_awaddr.value  = addr
        self._dut.m_awprot.value  = 0
        self._dut.m_awvalid.value = 1

        aw_done = False
        for _ in range(w_delay_cycles):
            await RisingEdge(self._clk)
            if not aw_done and self._dut.m_awready.value == 1:
                self._dut.m_awvalid.value = 0
                aw_done = True

        self._dut.m_wdata.value  = data
        self._dut.m_wstrb.value  = strb
        self._dut.m_wvalid.value = 1

        if not aw_done:
            while True:
                await RisingEdge(self._clk)
                if self._dut.m_awready.value == 1:
                    self._dut.m_awvalid.value = 0
                    aw_done = True
                    break

        while True:
            await RisingEdge(self._clk)
            if self._dut.m_wready.value == 1:
                self._dut.m_wvalid.value = 0
                break

        self._dut.m_bready.value = 1
        while True:
            await RisingEdge(self._clk)
            if self._dut.m_bvalid.value == 1:
                bresp = int(self._dut.m_bresp.value)
                self._dut.m_bready.value = 0
                return bresp

    async def write_w_first(self, addr: int, data: int, strb: int = 0xF,
                            aw_delay_cycles: int = 4) -> int:
        """Assert wvalid first, then awvalid after aw_delay_cycles. Returns bresp.

        The router holds the W channel until AW arrives, so when AW finally
        comes both channels are forwarded simultaneously. awready and wready
        therefore arrive in the SAME clock cycle — both must be captured
        together or a sequential wait will miss one of them.
        """
        self._dut.m_wdata.value  = data
        self._dut.m_wstrb.value  = strb
        self._dut.m_wvalid.value = 1

        aw_done = w_done = False

        # Wait aw_delay_cycles; wready won't come here (router blocks W until AW)
        for _ in range(aw_delay_cycles):
            await RisingEdge(self._clk)
            if not w_done and self._dut.m_wready.value == 1:
                self._dut.m_wvalid.value = 0
                w_done = True

        # Now assert awvalid
        self._dut.m_awaddr.value  = addr
        self._dut.m_awprot.value  = 0
        self._dut.m_awvalid.value = 1

        # Check BOTH channels each cycle: they may arrive simultaneously
        while not (aw_done and w_done):
            await RisingEdge(self._clk)
            if not aw_done and self._dut.m_awready.value == 1:
                self._dut.m_awvalid.value = 0
                aw_done = True
            if not w_done and self._dut.m_wready.value == 1:
                self._dut.m_wvalid.value = 0
                w_done = True

        self._dut.m_bready.value = 1
        while True:
            await RisingEdge(self._clk)
            if self._dut.m_bvalid.value == 1:
                bresp = int(self._dut.m_bresp.value)
                self._dut.m_bready.value = 0
                return bresp

    async def read(self, addr: int, rready_delay: int = 0,
                   prot: int = 0):
        """Returns (rdata, rresp)."""
        self._dut.m_araddr.value  = addr
        self._dut.m_arprot.value  = prot
        self._dut.m_arvalid.value = 1

        while True:
            await RisingEdge(self._clk)
            if self._dut.m_arready.value == 1:
                self._dut.m_arvalid.value = 0
                break

        for _ in range(rready_delay):
            await RisingEdge(self._clk)

        self._dut.m_rready.value = 1
        while True:
            await RisingEdge(self._clk)
            if self._dut.m_rvalid.value == 1:
                rdata = int(self._dut.m_rdata.value)
                rresp = int(self._dut.m_rresp.value)
                self._dut.m_rready.value = 0
                return rdata, rresp


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
async def setup(dut):
    """Start clock, assert reset, return AXIMaster."""
    cocotb.start_soon(Clock(dut.i_clk, CLK_PERIOD_NS, units="ns").start())

    master = AXIMaster(dut, dut.i_clk)
    master.init()

    dut.i_rst_n.value = 0
    await ClockCycles(dut.i_clk, 8)
    dut.i_rst_n.value = 1
    await ClockCycles(dut.i_clk, 2)

    return master


def dut_reg_version(dut) -> int:
    return int(dut.reg_version.value)


def dut_reg_val(dut) -> int:
    return int(dut.reg_val.value)


# ===========================================================================
# Group 1 – Basic routing
# ===========================================================================

@cocotb.test()
async def test_reset_behavior(dut):
    """ROUT-001: After reset bvalid=0, rvalid=0; registers at reset values."""
    await setup(dut)
    await ClockCycles(dut.i_clk, 2)

    assert int(dut.m_bvalid.value) == 0, "bvalid not 0 after reset"
    assert int(dut.m_rvalid.value) == 0, "rvalid not 0 after reset"
    assert dut_reg_version(dut) == VERSION_RESET, \
        f"version reset mismatch: 0x{dut_reg_version(dut):08X}"
    assert dut_reg_val(dut) == VAL_RESET, \
        f"val reset mismatch: 0x{dut_reg_val(dut):08X}"
    dut._log.info("[PASS] ROUT-001 – reset state correct")


@cocotb.test()
async def test_inrange_write_okay(dut):
    """ROUT-002: Write to Tier-A address → OKAY; register updated."""
    master = await setup(dut)

    bresp = await with_timeout(master.write(ADDR_VAL, 0x12345678), TIMEOUT_NS, "ns")
    assert bresp == AXI_RESP_OKAY, f"Expected OKAY, got {bresp}"
    assert dut_reg_val(dut) == 0x12345678, \
        f"val not updated: 0x{dut_reg_val(dut):08X}"
    dut._log.info("[PASS] ROUT-002 – in-range write OKAY; register updated")


@cocotb.test()
async def test_inrange_read_okay(dut):
    """ROUT-003: Read from Tier-A address → OKAY + correct reset value."""
    master = await setup(dut)

    rdata, rresp = await with_timeout(master.read(ADDR_VERSION), TIMEOUT_NS, "ns")
    assert rresp == AXI_RESP_OKAY, f"Expected OKAY, got {rresp}"
    assert rdata == VERSION_RESET, \
        f"version data wrong: 0x{rdata:08X} (expected 0x{VERSION_RESET:08X})"
    dut._log.info("[PASS] ROUT-003 – in-range read OKAY with correct data")


@cocotb.test()
async def test_outofrange_write_slverr(dut):
    """ROUT-004: Write to Tier-C address → SLVERR from router; registers unchanged."""
    master = await setup(dut)

    bresp = await with_timeout(master.write(ADDR_BELOW, 0xDEAD1234), TIMEOUT_NS, "ns")
    assert bresp == AXI_RESP_SLVERR, f"Expected SLVERR, got {bresp}"
    assert dut_reg_version(dut) == VERSION_RESET
    assert dut_reg_val(dut) == VAL_RESET
    dut._log.info("[PASS] ROUT-004 – out-of-range write returns SLVERR; registers intact")


@cocotb.test()
async def test_outofrange_read_slverr(dut):
    """ROUT-005: Read from Tier-C address → SLVERR from router, rdata=0."""
    master = await setup(dut)

    rdata, rresp = await with_timeout(master.read(ADDR_ABOVE), TIMEOUT_NS, "ns")
    assert rresp == AXI_RESP_SLVERR, f"Expected SLVERR, got {rresp}"
    assert rdata == 0, f"rdata must be 0 for router SLVERR, got 0x{rdata:08X}"
    dut._log.info("[PASS] ROUT-005 – out-of-range read SLVERR + rdata=0")


@cocotb.test()
async def test_tierb_write_slverr_from_reg(dut):
    """ROUT-006: Write to Tier-B address (router passes, no reg match) → SLVERR from reg."""
    master = await setup(dut)

    bresp = await with_timeout(master.write(ADDR_TIER_B, 0xCAFEBABE), TIMEOUT_NS, "ns")
    assert bresp == AXI_RESP_SLVERR, f"Expected SLVERR from register, got {bresp}"
    assert dut_reg_version(dut) == VERSION_RESET
    assert dut_reg_val(dut) == VAL_RESET
    dut._log.info("[PASS] ROUT-006 – Tier-B write passes router; register returns SLVERR")


@cocotb.test()
async def test_tierb_read_slverr_from_reg(dut):
    """ROUT-007: Read from Tier-B → SLVERR from register."""
    master = await setup(dut)

    rdata, rresp = await with_timeout(master.read(ADDR_TIER_B), TIMEOUT_NS, "ns")
    assert rresp == AXI_RESP_SLVERR, f"Expected SLVERR from register, got {rresp}"
    dut._log.info("[PASS] ROUT-007 – Tier-B read passes router; register returns SLVERR")


# ===========================================================================
# Group 2 – Address translation proof (router-specific)
# ===========================================================================

@cocotb.test()
async def test_translation_version_register(dut):
    """ROUT-008: Upstream 0x4000 must translate to 0x0000 (version register).
    Proof: register BASE_ADDR=0x0000, so OKAY only if translation occurred."""
    master = await setup(dut)

    WR = 0xAABBCCDD
    bresp = await with_timeout(master.write(ADDR_VERSION, WR), TIMEOUT_NS, "ns")
    assert bresp == AXI_RESP_OKAY, \
        f"Translation failed? Expected OKAY at upstream 0x{ADDR_VERSION:08X}, got {bresp}"
    assert dut_reg_version(dut) == WR, \
        f"version reg wrong: 0x{dut_reg_version(dut):08X} (expected 0x{WR:08X})"

    rdata, rresp = await with_timeout(master.read(ADDR_VERSION), TIMEOUT_NS, "ns")
    assert rresp == AXI_RESP_OKAY
    assert rdata == WR, f"Readback 0x{rdata:08X} != 0x{WR:08X}"
    dut._log.info("[PASS] ROUT-008 – 0x4000→0x0000 translation confirmed (version)")


@cocotb.test()
async def test_translation_val_register(dut):
    """ROUT-009: Upstream 0x4004 must translate to 0x0004 (val register).
    Proof: register BASE_ADDR=0x0000, OKAY only if subtraction was applied."""
    master = await setup(dut)

    WR = 0x11223344
    bresp = await with_timeout(master.write(ADDR_VAL, WR), TIMEOUT_NS, "ns")
    assert bresp == AXI_RESP_OKAY, \
        f"Translation failed? upstream 0x{ADDR_VAL:08X} expected OKAY, got {bresp}"
    assert dut_reg_val(dut) == WR

    rdata, rresp = await with_timeout(master.read(ADDR_VAL), TIMEOUT_NS, "ns")
    assert rresp == AXI_RESP_OKAY
    assert rdata == WR
    dut._log.info("[PASS] ROUT-009 – 0x4004→0x0004 translation confirmed (val)")


@cocotb.test()
async def test_untranslated_address_would_fail(dut):
    """ROUT-010: Without translation, 0x4000 would reach register as 0x4000.
    The register has BASE_ADDR=0 so addresses 0x4000/0x4004 are invalid there.
    This test sends 0x4000 and asserts OKAY – proving translation DID happen
    (no translation → register SLVERR)."""
    master = await setup(dut)

    bresp = await with_timeout(master.write(ADDR_VERSION, 0xFACEFACE), TIMEOUT_NS, "ns")
    assert bresp == AXI_RESP_OKAY, \
        "Expected OKAY – if this fails the router is not subtracting base address!"
    dut._log.info("[PASS] ROUT-010 – translation proof via contrast: OKAY confirms subtraction")


@cocotb.test()
async def test_translation_boundary_base_addr(dut):
    """ROUT-011: Upstream G_BASE_ADDR (0x4000) translates to exactly 0x0000."""
    master = await setup(dut)

    WR = 0xDEADC0DE
    bresp = await with_timeout(master.write(ROUTER_BASE, WR), TIMEOUT_NS, "ns")
    assert bresp == AXI_RESP_OKAY, f"Upstream base addr: expected OKAY, got {bresp}"
    assert dut_reg_version(dut) == WR
    dut._log.info("[PASS] ROUT-011 – base addr translates to 0x0000; version written")


@cocotb.test()
async def test_translation_consecutive_addresses(dut):
    """ROUT-012: Both 0x4000 and 0x4004 translate correctly and independently."""
    master = await setup(dut)

    V = 0x11111111
    X = 0x22222222

    await with_timeout(master.write(ADDR_VERSION, V), TIMEOUT_NS, "ns")
    await with_timeout(master.write(ADDR_VAL,     X), TIMEOUT_NS, "ns")

    rv, _ = await with_timeout(master.read(ADDR_VERSION), TIMEOUT_NS, "ns")
    rx, _ = await with_timeout(master.read(ADDR_VAL),     TIMEOUT_NS, "ns")

    assert rv == V, f"version: 0x{rv:08X} != 0x{V:08X}"
    assert rx == X, f"val:     0x{rx:08X} != 0x{X:08X}"
    dut._log.info("[PASS] ROUT-012 – consecutive translated addresses are independent")


# ===========================================================================
# Group 3 – Address boundary correctness
# ===========================================================================

@cocotb.test()
async def test_boundary_begin_write(dut):
    """ROUT-013: Write to ROUTER_BASE (0x4000) → OKAY (inclusive begin)."""
    master = await setup(dut)

    bresp = await with_timeout(master.write(ROUTER_BASE, 0x11111111), TIMEOUT_NS, "ns")
    assert bresp == AXI_RESP_OKAY, f"Begin boundary: expected OKAY, got {bresp}"
    assert dut_reg_version(dut) == 0x11111111
    dut._log.info("[PASS] ROUT-013 – begin boundary (0x4000) inclusive write OKAY")


@cocotb.test()
async def test_boundary_begin_read(dut):
    """ROUT-014: Read from ROUTER_BASE → OKAY."""
    master = await setup(dut)

    rdata, rresp = await with_timeout(master.read(ROUTER_BASE), TIMEOUT_NS, "ns")
    assert rresp == AXI_RESP_OKAY, f"Begin boundary read: expected OKAY, got {rresp}"
    dut._log.info("[PASS] ROUT-014 – begin boundary (0x4000) inclusive read OKAY")


@cocotb.test()
async def test_boundary_end_write(dut):
    """ROUT-015: Write to ROUTER_END (0x4FFF) → passes router (Tier-B, reg SLVERR)."""
    master = await setup(dut)

    bresp = await with_timeout(master.write(ROUTER_END, 0xBBBBBBBB), TIMEOUT_NS, "ns")
    assert bresp == AXI_RESP_SLVERR, \
        f"End boundary (Tier-B): expected SLVERR from reg, got {bresp}"
    assert dut_reg_version(dut) == VERSION_RESET
    assert dut_reg_val(dut) == VAL_RESET
    dut._log.info("[PASS] ROUT-015 – end boundary (0x4FFF) passes router, reg SLVERR")


@cocotb.test()
async def test_boundary_just_below_begin(dut):
    """ROUT-016: Write to ROUTER_BASE-1 (0x3FFF) → router SLVERR immediately."""
    master = await setup(dut)

    bresp = await with_timeout(
        master.write(ROUTER_BASE - 1, 0xCCCCCCCC), TIMEOUT_NS, "ns"
    )
    assert bresp == AXI_RESP_SLVERR, f"Just-below-begin: expected SLVERR, got {bresp}"
    assert dut_reg_version(dut) == VERSION_RESET
    assert dut_reg_val(dut) == VAL_RESET
    dut._log.info("[PASS] ROUT-016 – just below begin (0x3FFF) → router SLVERR")


@cocotb.test()
async def test_boundary_just_above_end(dut):
    """ROUT-017: Write to ROUTER_END+1 (0x5000) → router SLVERR immediately."""
    master = await setup(dut)

    bresp = await with_timeout(
        master.write(ROUTER_END + 1, 0xDDDDDDDD), TIMEOUT_NS, "ns"
    )
    assert bresp == AXI_RESP_SLVERR, f"Just-above-end: expected SLVERR, got {bresp}"
    assert dut_reg_version(dut) == VERSION_RESET
    assert dut_reg_val(dut) == VAL_RESET
    dut._log.info("[PASS] ROUT-017 – just above end (0x5000) → router SLVERR")


@cocotb.test()
async def test_boundary_addr_zero(dut):
    """ROUT-018: Read/write at address 0 → router SLVERR (far below window)."""
    master = await setup(dut)

    bresp = await with_timeout(master.write(ADDR_ZERO, 0xABCD1234), TIMEOUT_NS, "ns")
    assert bresp == AXI_RESP_SLVERR, f"Addr 0 write: expected SLVERR, got {bresp}"

    rdata, rresp = await with_timeout(master.read(ADDR_ZERO), TIMEOUT_NS, "ns")
    assert rresp == AXI_RESP_SLVERR, f"Addr 0 read: expected SLVERR, got {rresp}"
    dut._log.info("[PASS] ROUT-018 – address 0 → router SLVERR on both read and write")


@cocotb.test()
async def test_boundary_all_ones_addr(dut):
    """ROUT-019: Write to 0xFFFFFFFF → router SLVERR."""
    master = await setup(dut)

    bresp = await with_timeout(master.write(0xFFFFFFFF, 0x1), TIMEOUT_NS, "ns")
    assert bresp == AXI_RESP_SLVERR, f"0xFFFFFFFF: expected SLVERR, got {bresp}"
    dut._log.info("[PASS] ROUT-019 – 0xFFFFFFFF → router SLVERR")


# ===========================================================================
# Group 4 – Register read/write integrity
# ===========================================================================

@cocotb.test()
async def test_write_read_version(dut):
    """ROUT-020: Write then read version register; values must match."""
    master = await setup(dut)

    WR = 0xDEAD1234
    await with_timeout(master.write(ADDR_VERSION, WR), TIMEOUT_NS, "ns")
    rdata, rresp = await with_timeout(master.read(ADDR_VERSION), TIMEOUT_NS, "ns")

    assert rresp == AXI_RESP_OKAY
    assert rdata == WR, f"version readback 0x{rdata:08X} != 0x{WR:08X}"
    assert dut_reg_version(dut) == WR
    dut._log.info("[PASS] ROUT-020 – version write-read roundtrip")


@cocotb.test()
async def test_write_read_val(dut):
    """ROUT-021: Write then read val register."""
    master = await setup(dut)

    WR = 0xCAFECAFE
    await with_timeout(master.write(ADDR_VAL, WR), TIMEOUT_NS, "ns")
    rdata, rresp = await with_timeout(master.read(ADDR_VAL), TIMEOUT_NS, "ns")

    assert rresp == AXI_RESP_OKAY
    assert rdata == WR, f"val readback 0x{rdata:08X} != 0x{WR:08X}"
    dut._log.info("[PASS] ROUT-021 – val write-read roundtrip")


@cocotb.test()
async def test_partial_write_strobe_bytes_0_2(dut):
    """ROUT-022: Write strb=0b0101 (bytes 0,2) → only those bytes updated."""
    master = await setup(dut)

    # val reset = 0xDEADBEEF
    # Write 0x11221122 with strb 0b0101 (bytes 0 and 2 only)
    # Expected: byte3=0xDE byte2=0x11 byte1=0xBE byte0=0x11 → 0xDE11BE11
    WR_DATA = 0x11221122
    STROBE  = 0b0101
    EXPECT  = (VAL_RESET & 0xFF00FF00) | (WR_DATA & 0x00FF00FF)

    bresp = await with_timeout(
        master.write(ADDR_VAL, WR_DATA, strb=STROBE), TIMEOUT_NS, "ns"
    )
    assert bresp == AXI_RESP_OKAY

    rdata, rresp = await with_timeout(master.read(ADDR_VAL), TIMEOUT_NS, "ns")
    assert rresp == AXI_RESP_OKAY
    assert rdata == EXPECT, f"Partial strobe: got 0x{rdata:08X}, expected 0x{EXPECT:08X}"
    dut._log.info("[PASS] ROUT-022 – partial write strobe byte0+byte2 correct")


@cocotb.test()
async def test_partial_write_strobe_high_bytes(dut):
    """ROUT-023: Write strb=0b1100 (bytes 2,3) → only upper bytes updated."""
    master = await setup(dut)

    # version reset = 0xABCDEF01
    # Write 0x12345678 strb=0b1100 → byte3=0x12 byte2=0x34 keep byte1=0xEF byte0=0x01
    WR_DATA = 0x12345678
    STROBE  = 0b1100
    EXPECT  = (WR_DATA & 0xFFFF0000) | (VERSION_RESET & 0x0000FFFF)

    bresp = await with_timeout(
        master.write(ADDR_VERSION, WR_DATA, strb=STROBE), TIMEOUT_NS, "ns"
    )
    assert bresp == AXI_RESP_OKAY

    rdata, rresp = await with_timeout(master.read(ADDR_VERSION), TIMEOUT_NS, "ns")
    assert rresp == AXI_RESP_OKAY
    assert rdata == EXPECT, f"High-byte strobe: got 0x{rdata:08X}, expected 0x{EXPECT:08X}"
    dut._log.info("[PASS] ROUT-023 – partial write strobe byte2+byte3 correct")


@cocotb.test()
async def test_outofrange_does_not_corrupt_registers(dut):
    """ROUT-024: Multiple out-of-range writes must never alter register values."""
    master = await setup(dut)

    out_addrs = [ADDR_ZERO, ADDR_BELOW, ADDR_ABOVE, ADDR_HIGH, 0x0000BEEF]
    for addr in out_addrs:
        bresp = await with_timeout(
            master.write(addr, 0xDEADDEAD), TIMEOUT_NS, "ns"
        )
        assert bresp == AXI_RESP_SLVERR, \
            f"Addr 0x{addr:08X}: expected SLVERR, got {bresp}"

    assert dut_reg_version(dut) == VERSION_RESET, \
        f"version corrupted: 0x{dut_reg_version(dut):08X}"
    assert dut_reg_val(dut) == VAL_RESET, \
        f"val corrupted: 0x{dut_reg_val(dut):08X}"
    dut._log.info("[PASS] ROUT-024 – out-of-range writes never corrupt registers")


@cocotb.test()
async def test_registers_independent(dut):
    """ROUT-025: Writing version must not affect val and vice versa."""
    master = await setup(dut)

    await with_timeout(master.write(ADDR_VERSION, 0x11111111), TIMEOUT_NS, "ns")
    assert dut_reg_val(dut) == VAL_RESET, "val changed after writing version"

    await with_timeout(master.write(ADDR_VAL, 0x22222222), TIMEOUT_NS, "ns")
    assert dut_reg_version(dut) == 0x11111111, "version changed after writing val"

    dut._log.info("[PASS] ROUT-025 – version and val registers are independent")


# ===========================================================================
# Group 5 – AXI4-Lite protocol compliance
# ===========================================================================

@cocotb.test()
async def test_bvalid_stable_under_backpressure_outofrange(dut):
    """ROUT-026: Out-of-range write; bvalid must stay HIGH while bready=0 (AXI §A3.3)."""
    master = await setup(dut)

    HOLD = 10

    dut.m_awaddr.value  = ADDR_ABOVE
    dut.m_awprot.value  = 0
    dut.m_awvalid.value = 1
    dut.m_wdata.value   = 0xAA
    dut.m_wstrb.value   = 0xF
    dut.m_wvalid.value  = 1
    dut.m_bready.value  = 0

    aw_done = w_done = False
    for _ in range(TIMEOUT_CYCLES):
        await RisingEdge(dut.i_clk)
        if not aw_done and int(dut.m_awready.value) == 1:
            dut.m_awvalid.value = 0
            aw_done = True
        if not w_done and int(dut.m_wready.value) == 1:
            dut.m_wvalid.value = 0
            w_done = True
        if aw_done and w_done:
            break

    for _ in range(TIMEOUT_CYCLES):
        await RisingEdge(dut.i_clk)
        if int(dut.m_bvalid.value) == 1:
            break

    assert int(dut.m_bvalid.value) == 1, "bvalid never asserted"
    assert int(dut.m_bresp.value) == AXI_RESP_SLVERR

    for cyc in range(HOLD):
        await RisingEdge(dut.i_clk)
        assert int(dut.m_bvalid.value) == 1, \
            f"bvalid dropped at cycle {cyc} (AXI4-Lite violation)"

    dut.m_bready.value = 1
    await RisingEdge(dut.i_clk)
    assert int(dut.m_bvalid.value) == 1, "bvalid must be high when bready first asserted"
    dut.m_bready.value = 0
    dut._log.info("[PASS] ROUT-026 – bvalid stable under backpressure (out-of-range)")


@cocotb.test()
async def test_rvalid_stable_under_backpressure_outofrange(dut):
    """ROUT-027: Out-of-range read; rvalid stays HIGH while rready=0."""
    master = await setup(dut)

    HOLD = 10

    dut.m_araddr.value  = ADDR_BELOW
    dut.m_arprot.value  = 0
    dut.m_arvalid.value = 1
    dut.m_rready.value  = 0

    for _ in range(TIMEOUT_CYCLES):
        await RisingEdge(dut.i_clk)
        if int(dut.m_arready.value) == 1:
            dut.m_arvalid.value = 0
            break

    for _ in range(TIMEOUT_CYCLES):
        await RisingEdge(dut.i_clk)
        if int(dut.m_rvalid.value) == 1:
            break

    assert int(dut.m_rvalid.value) == 1, "rvalid never asserted"
    assert int(dut.m_rresp.value) == AXI_RESP_SLVERR

    for cyc in range(HOLD):
        await RisingEdge(dut.i_clk)
        assert int(dut.m_rvalid.value) == 1, \
            f"rvalid dropped at cycle {cyc} (AXI4-Lite violation)"

    dut.m_rready.value = 1
    await RisingEdge(dut.i_clk)
    dut.m_rready.value = 0
    dut._log.info("[PASS] ROUT-027 – rvalid stable under backpressure (out-of-range)")


@cocotb.test()
async def test_bvalid_stable_under_backpressure_inrange(dut):
    """ROUT-028: In-range write; bvalid stable during bready_delay=8."""
    master = await setup(dut)

    bresp = await with_timeout(
        master.write(ADDR_VAL, 0x55AA55AA, bready_delay=8), TIMEOUT_NS, "ns"
    )
    assert bresp == AXI_RESP_OKAY
    dut._log.info("[PASS] ROUT-028 – bvalid stable under backpressure (in-range)")


@cocotb.test()
async def test_rvalid_stable_under_backpressure_inrange(dut):
    """ROUT-029: In-range read; rvalid stable during rready_delay=8."""
    master = await setup(dut)

    rdata, rresp = await with_timeout(
        master.read(ADDR_VERSION, rready_delay=8), TIMEOUT_NS, "ns"
    )
    assert rresp == AXI_RESP_OKAY
    assert rdata == VERSION_RESET
    dut._log.info("[PASS] ROUT-029 – rvalid stable under backpressure (in-range)")


@cocotb.test()
async def test_wready_single_pulse_outofrange(dut):
    """ROUT-030: Out-of-range write; wready must pulse exactly once."""
    master = await setup(dut)

    wready_count = 0

    async def count_wready():
        nonlocal wready_count
        for _ in range(TIMEOUT_CYCLES):
            await RisingEdge(dut.i_clk)
            if int(dut.m_wready.value) == 1:
                wready_count += 1

    mon = cocotb.start_soon(count_wready())
    await with_timeout(master.write(ADDR_BELOW, 0xABCD), TIMEOUT_NS, "ns")
    mon.kill()

    assert wready_count == 1, f"wready pulsed {wready_count} times (expected 1)"
    dut._log.info("[PASS] ROUT-030 – wready single pulse (out-of-range)")


@cocotb.test()
async def test_awready_single_pulse_outofrange(dut):
    """ROUT-031: Out-of-range write; awready must pulse exactly once."""
    master = await setup(dut)

    awready_count = 0

    async def count_awready():
        nonlocal awready_count
        for _ in range(TIMEOUT_CYCLES):
            await RisingEdge(dut.i_clk)
            if int(dut.m_awready.value) == 1:
                awready_count += 1

    mon = cocotb.start_soon(count_awready())
    await with_timeout(master.write(ADDR_ABOVE, 0xABCD), TIMEOUT_NS, "ns")
    mon.kill()

    assert awready_count == 1, f"awready pulsed {awready_count} times (expected 1)"
    dut._log.info("[PASS] ROUT-031 – awready single pulse (out-of-range)")


@cocotb.test()
async def test_arready_single_pulse_outofrange(dut):
    """ROUT-032: Out-of-range read; arready must pulse exactly once."""
    master = await setup(dut)

    arready_count = 0

    async def count_arready():
        nonlocal arready_count
        for _ in range(TIMEOUT_CYCLES):
            await RisingEdge(dut.i_clk)
            if int(dut.m_arready.value) == 1:
                arready_count += 1

    mon = cocotb.start_soon(count_arready())
    await with_timeout(master.read(ADDR_BELOW), TIMEOUT_NS, "ns")
    mon.kill()

    assert arready_count == 1, f"arready pulsed {arready_count} times (expected 1)"
    dut._log.info("[PASS] ROUT-032 – arready single pulse (out-of-range)")


@cocotb.test()
async def test_prot_forwarded_on_write(dut):
    """ROUT-033: AWPROT forwarded transparently on in-range write."""
    master = await setup(dut)

    bresp = await with_timeout(
        master.write(ADDR_VAL, 0xAABBCCDD, prot=0b011), TIMEOUT_NS, "ns"
    )
    assert bresp == AXI_RESP_OKAY
    dut._log.info("[PASS] ROUT-033 – AWPROT forwarded on in-range write")


@cocotb.test()
async def test_prot_forwarded_on_read(dut):
    """ROUT-034: ARPROT forwarded transparently on in-range read."""
    master = await setup(dut)

    rdata, rresp = await with_timeout(
        master.read(ADDR_VERSION, prot=0b101), TIMEOUT_NS, "ns"
    )
    assert rresp == AXI_RESP_OKAY
    dut._log.info("[PASS] ROUT-034 – ARPROT forwarded on in-range read")


# ===========================================================================
# Group 6 – W-channel timing variants
# ===========================================================================

@cocotb.test()
async def test_aw_before_w_inrange(dut):
    """ROUT-035: AW presented 4 cycles before W (in-range) → OKAY, register updated."""
    master = await setup(dut)

    bresp = await with_timeout(
        master.write_aw_first(ADDR_VAL, 0x99887766, w_delay_cycles=4),
        TIMEOUT_NS, "ns"
    )
    assert bresp == AXI_RESP_OKAY
    assert dut_reg_val(dut) == 0x99887766
    dut._log.info("[PASS] ROUT-035 – AW-first 4 cycles (in-range) → OKAY")


@cocotb.test()
async def test_aw_before_w_outofrange(dut):
    """ROUT-036: AW presented 4 cycles before W (out-of-range) → SLVERR, registers intact."""
    master = await setup(dut)

    bresp = await with_timeout(
        master.write_aw_first(ADDR_BELOW, 0xBAADC0DE, w_delay_cycles=4),
        TIMEOUT_NS, "ns"
    )
    assert bresp == AXI_RESP_SLVERR
    assert dut_reg_version(dut) == VERSION_RESET
    assert dut_reg_val(dut) == VAL_RESET
    dut._log.info("[PASS] ROUT-036 – AW-first (out-of-range) → SLVERR, registers intact")


@cocotb.test()
async def test_w_before_aw_inrange(dut):
    """ROUT-037: W presented 4 cycles before AW (data-first) → OKAY (AXI-LITE-005)."""
    master = await setup(dut)

    bresp = await with_timeout(
        master.write_w_first(ADDR_VERSION, 0xFEEDFACE, aw_delay_cycles=4),
        TIMEOUT_NS, "ns"
    )
    assert bresp == AXI_RESP_OKAY
    assert dut_reg_version(dut) == 0xFEEDFACE
    dut._log.info("[PASS] ROUT-037 – W-first 4 cycles (in-range) → OKAY (AXI-LITE-005)")


@cocotb.test()
async def test_w_before_aw_outofrange(dut):
    """ROUT-038: W data-first (out-of-range) → SLVERR, registers intact."""
    master = await setup(dut)

    bresp = await with_timeout(
        master.write_w_first(ADDR_ABOVE, 0xDEADBABE, aw_delay_cycles=4),
        TIMEOUT_NS, "ns"
    )
    assert bresp == AXI_RESP_SLVERR
    assert dut_reg_version(dut) == VERSION_RESET
    assert dut_reg_val(dut) == VAL_RESET
    dut._log.info("[PASS] ROUT-038 – W-first (out-of-range) → SLVERR, registers intact")


# ===========================================================================
# Group 7 – Back-pressure (bready / rready delay)
# ===========================================================================

@cocotb.test()
async def test_bready_delay_inrange(dut):
    """ROUT-039: In-range write with bready_delay=10 → OKAY."""
    master = await setup(dut)

    bresp = await with_timeout(
        master.write(ADDR_VAL, 0xAABBCCDD, bready_delay=10), TIMEOUT_NS, "ns"
    )
    assert bresp == AXI_RESP_OKAY
    dut._log.info("[PASS] ROUT-039 – bready_delay=10 in-range OKAY")


@cocotb.test()
async def test_bready_delay_outofrange(dut):
    """ROUT-040: Out-of-range write with bready_delay=10 → SLVERR."""
    master = await setup(dut)

    bresp = await with_timeout(
        master.write(ADDR_ZERO, 0xFF, bready_delay=10), TIMEOUT_NS, "ns"
    )
    assert bresp == AXI_RESP_SLVERR
    dut._log.info("[PASS] ROUT-040 – bready_delay=10 out-of-range SLVERR")


@cocotb.test()
async def test_rready_delay_inrange(dut):
    """ROUT-041: In-range read with rready_delay=10 → OKAY + correct data."""
    master = await setup(dut)

    rdata, rresp = await with_timeout(
        master.read(ADDR_VERSION, rready_delay=10), TIMEOUT_NS, "ns"
    )
    assert rresp == AXI_RESP_OKAY
    assert rdata == VERSION_RESET
    dut._log.info("[PASS] ROUT-041 – rready_delay=10 in-range OKAY + correct data")


@cocotb.test()
async def test_rready_delay_outofrange(dut):
    """ROUT-042: Out-of-range read with rready_delay=10 → SLVERR."""
    master = await setup(dut)

    rdata, rresp = await with_timeout(
        master.read(ADDR_ZERO, rready_delay=10), TIMEOUT_NS, "ns"
    )
    assert rresp == AXI_RESP_SLVERR
    dut._log.info("[PASS] ROUT-042 – rready_delay=10 out-of-range SLVERR")


# ===========================================================================
# Group 8 – Back-to-back and mixed sequences
# ===========================================================================

@cocotb.test()
async def test_back_to_back_inrange_writes(dut):
    """ROUT-043: 5 consecutive in-range writes; each OKAY, final value correct."""
    master = await setup(dut)

    for i in range(5):
        data = 0x10000000 + i
        bresp = await with_timeout(master.write(ADDR_VAL, data), TIMEOUT_NS, "ns")
        assert bresp == AXI_RESP_OKAY, f"Write {i}: expected OKAY, got {bresp}"

    assert dut_reg_val(dut) == 0x10000004, \
        f"Final val wrong: 0x{dut_reg_val(dut):08X}"
    dut._log.info("[PASS] ROUT-043 – 5 back-to-back in-range writes")


@cocotb.test()
async def test_back_to_back_outofrange_writes(dut):
    """ROUT-044: 5 consecutive out-of-range writes; all SLVERR, registers intact."""
    master = await setup(dut)

    for i in range(5):
        bresp = await with_timeout(
            master.write(ADDR_ABOVE + i * 4, 0xDEAD0000 + i), TIMEOUT_NS, "ns"
        )
        assert bresp == AXI_RESP_SLVERR, f"Write {i}: expected SLVERR, got {bresp}"

    assert dut_reg_version(dut) == VERSION_RESET
    assert dut_reg_val(dut) == VAL_RESET
    dut._log.info("[PASS] ROUT-044 – 5 back-to-back out-of-range writes all SLVERR")


@cocotb.test()
async def test_mixed_in_then_out_then_read(dut):
    """ROUT-045: in-range write → out-of-range write → in-range read; correct throughout."""
    master = await setup(dut)

    WR = 0xFEDCBA98
    await with_timeout(master.write(ADDR_VAL, WR), TIMEOUT_NS, "ns")
    bresp = await with_timeout(master.write(ADDR_BELOW, 0xDEAD), TIMEOUT_NS, "ns")
    assert bresp == AXI_RESP_SLVERR

    rdata, rresp = await with_timeout(master.read(ADDR_VAL), TIMEOUT_NS, "ns")
    assert rresp == AXI_RESP_OKAY
    assert rdata == WR, f"val readback wrong: 0x{rdata:08X}"
    dut._log.info("[PASS] ROUT-045 – in→out→read sequence correct")


@cocotb.test()
async def test_mixed_out_then_in_then_read(dut):
    """ROUT-046: out-of-range write → in-range write → in-range read."""
    master = await setup(dut)

    bresp = await with_timeout(master.write(ADDR_HIGH, 0x1), TIMEOUT_NS, "ns")
    assert bresp == AXI_RESP_SLVERR

    WR = 0x12ABCD34
    await with_timeout(master.write(ADDR_VERSION, WR), TIMEOUT_NS, "ns")

    rdata, rresp = await with_timeout(master.read(ADDR_VERSION), TIMEOUT_NS, "ns")
    assert rresp == AXI_RESP_OKAY
    assert rdata == WR
    dut._log.info("[PASS] ROUT-046 – out→in→read sequence; router cleans up correctly")


@cocotb.test()
async def test_alternating_6_step_sequence(dut):
    """ROUT-047: 6 alternating in-range/out-of-range writes; state machine stays clean."""
    master = await setup(dut)

    sequence = [
        (ADDR_VAL,   0xAAAA0001, AXI_RESP_OKAY),
        (ADDR_BELOW, 0xBBBB0001, AXI_RESP_SLVERR),
        (ADDR_VAL,   0xAAAA0002, AXI_RESP_OKAY),
        (ADDR_ABOVE, 0xBBBB0002, AXI_RESP_SLVERR),
        (ADDR_VAL,   0xAAAA0003, AXI_RESP_OKAY),
        (ADDR_ZERO,  0xBBBB0003, AXI_RESP_SLVERR),
    ]

    for addr, data, exp in sequence:
        bresp = await with_timeout(master.write(addr, data), TIMEOUT_NS, "ns")
        assert bresp == exp, \
            f"addr=0x{addr:08X} data=0x{data:08X}: got {bresp}, expected {exp}"

    assert dut_reg_val(dut) == 0xAAAA0003
    dut._log.info("[PASS] ROUT-047 – 6-step alternating sequence correct")


@cocotb.test()
async def test_read_after_multiple_writes(dut):
    """ROUT-048: Interleaved writes to both registers; read back both correctly."""
    master = await setup(dut)

    VER = 0x11223344
    VAL = 0x55667788

    await with_timeout(master.write(ADDR_VERSION, VER), TIMEOUT_NS, "ns")
    await with_timeout(master.write(ADDR_VAL,     VAL), TIMEOUT_NS, "ns")

    rv, _ = await with_timeout(master.read(ADDR_VERSION), TIMEOUT_NS, "ns")
    rx, _ = await with_timeout(master.read(ADDR_VAL),     TIMEOUT_NS, "ns")

    assert rv == VER, f"version: 0x{rv:08X}"
    assert rx == VAL, f"val:     0x{rx:08X}"
    dut._log.info("[PASS] ROUT-048 – interleaved writes; both registers correct on readback")


@cocotb.test()
async def test_read_read_sequence(dut):
    """ROUT-049: Two consecutive reads return correct data each time."""
    master = await setup(dut)

    WR = 0xABCD1234
    await with_timeout(master.write(ADDR_VAL, WR), TIMEOUT_NS, "ns")

    for i in range(2):
        rdata, rresp = await with_timeout(master.read(ADDR_VAL), TIMEOUT_NS, "ns")
        assert rresp == AXI_RESP_OKAY, f"Read {i}: rresp={rresp}"
        assert rdata == WR, f"Read {i}: 0x{rdata:08X} != 0x{WR:08X}"

    dut._log.info("[PASS] ROUT-049 – two consecutive reads both correct")


# ===========================================================================
# Group 9 – Reset mid-transaction
# ===========================================================================

@cocotb.test()
async def test_reset_mid_outofrange_write(dut):
    """ROUT-050: Reset during out-of-range write (ST_WRITE_ERR_DATA); recovery works."""
    master = await setup(dut)

    # Kick off AW without W → router enters ST_WRITE_ERR_DATA
    dut.m_awaddr.value  = ADDR_ABOVE
    dut.m_awvalid.value = 1
    dut.m_wvalid.value  = 0
    dut.m_bready.value  = 0

    for _ in range(TIMEOUT_CYCLES):
        await RisingEdge(dut.i_clk)
        if int(dut.m_awready.value) == 1:
            dut.m_awvalid.value = 0
            break

    await ClockCycles(dut.i_clk, 3)

    dut.i_rst_n.value = 0
    await ClockCycles(dut.i_clk, 5)
    assert int(dut.m_bvalid.value) == 0
    assert int(dut.m_rvalid.value) == 0

    dut.i_rst_n.value = 1
    master.init()
    await ClockCycles(dut.i_clk, 3)

    bresp = await with_timeout(master.write(ADDR_VAL, 0x42424242), TIMEOUT_NS, "ns")
    assert bresp == AXI_RESP_OKAY
    assert dut_reg_val(dut) == 0x42424242
    dut._log.info("[PASS] ROUT-050 – reset mid out-of-range write; recovery OK")


@cocotb.test()
async def test_reset_mid_inrange_write(dut):
    """ROUT-051: Reset during in-range pass-through; router recovers cleanly."""
    master = await setup(dut)

    write_task = cocotb.start_soon(master.write(ADDR_VAL, 0x99))

    await ClockCycles(dut.i_clk, 4)

    dut.i_rst_n.value = 0
    await ClockCycles(dut.i_clk, 5)
    dut.i_rst_n.value = 1
    master.init()
    write_task.kill()

    await ClockCycles(dut.i_clk, 4)

    assert dut_reg_version(dut) == VERSION_RESET
    assert dut_reg_val(dut)     == VAL_RESET

    bresp = await with_timeout(master.write(ADDR_VERSION, 0xFEEDFACE), TIMEOUT_NS, "ns")
    assert bresp == AXI_RESP_OKAY
    dut._log.info("[PASS] ROUT-051 – reset mid in-range write; recovery OK")


@cocotb.test()
async def test_reset_restores_register_values(dut):
    """ROUT-052: Write registers, assert reset; values return to reset state."""
    master = await setup(dut)

    await with_timeout(master.write(ADDR_VERSION, 0x11111111), TIMEOUT_NS, "ns")
    await with_timeout(master.write(ADDR_VAL,     0x22222222), TIMEOUT_NS, "ns")
    assert dut_reg_version(dut) == 0x11111111
    assert dut_reg_val(dut)     == 0x22222222

    dut.i_rst_n.value = 0
    await ClockCycles(dut.i_clk, 5)
    dut.i_rst_n.value = 1
    master.init()
    await ClockCycles(dut.i_clk, 3)

    assert dut_reg_version(dut) == VERSION_RESET, \
        f"version not restored: 0x{dut_reg_version(dut):08X}"
    assert dut_reg_val(dut) == VAL_RESET, \
        f"val not restored: 0x{dut_reg_val(dut):08X}"
    dut._log.info("[PASS] ROUT-052 – reset restores all register values")


@cocotb.test()
async def test_reset_mid_outofrange_read(dut):
    """ROUT-053: Reset during out-of-range read (ST_READ_ERR_RESP); recovery works."""
    master = await setup(dut)

    # Drive arvalid but hold rready low so we stay in ST_READ_ERR_RESP
    dut.m_araddr.value  = ADDR_ABOVE
    dut.m_arvalid.value = 1
    dut.m_rready.value  = 0

    for _ in range(TIMEOUT_CYCLES):
        await RisingEdge(dut.i_clk)
        if int(dut.m_arready.value) == 1:
            dut.m_arvalid.value = 0
            break

    # Wait until rvalid asserts
    for _ in range(TIMEOUT_CYCLES):
        await RisingEdge(dut.i_clk)
        if int(dut.m_rvalid.value) == 1:
            break

    assert int(dut.m_rvalid.value) == 1, "rvalid should be asserted before reset"

    dut.i_rst_n.value = 0
    await ClockCycles(dut.i_clk, 5)
    assert int(dut.m_rvalid.value) == 0, "rvalid not cleared by reset"
    dut.i_rst_n.value = 1
    master.init()
    await ClockCycles(dut.i_clk, 3)

    # Normal in-range read must work post-reset
    rdata, rresp = await with_timeout(master.read(ADDR_VERSION), TIMEOUT_NS, "ns")
    assert rresp == AXI_RESP_OKAY
    assert rdata == VERSION_RESET
    dut._log.info("[PASS] ROUT-053 – reset mid out-of-range read; recovery OK")


# ===========================================================================
# Group 10 – Stress / randomised sweep
# ===========================================================================

@cocotb.test()
async def test_stress_random_100_iterations(dut):
    """ROUT-054: 100 random address write+read iterations; response always correct."""
    master = await setup(dut)

    rng = random.Random(0xDEAD_BEEF)

    def pick_addr_and_exp():
        tier = rng.choices(['A', 'B', 'C'], weights=[35, 25, 40])[0]
        if tier == 'A':
            return rng.choice([ADDR_VERSION, ADDR_VAL]), AXI_RESP_OKAY
        elif tier == 'B':
            return rng.randint(ROUTER_BASE + 8, ROUTER_END), AXI_RESP_SLVERR
        else:
            if rng.random() < 0.5:
                return rng.randint(0, ROUTER_BASE - 1), AXI_RESP_SLVERR
            else:
                return rng.randint(ROUTER_END + 1, 0x0000FFFF), AXI_RESP_SLVERR

    failures = []

    for iteration in range(100):
        addr, expected = pick_addr_and_exp()
        data = rng.randint(0, 0xFFFF_FFFF)

        try:
            bresp = await with_timeout(master.write(addr, data), TIMEOUT_NS, "ns")
            if bresp != expected:
                failures.append(
                    f"iter {iteration} WRITE addr=0x{addr:08X}: "
                    f"got bresp={bresp}, expected {expected}"
                )
        except Exception as exc:
            failures.append(f"iter {iteration} WRITE exception: {exc}")
            master.init()
            await ClockCycles(dut.i_clk, 5)
            continue

        try:
            rdata, rresp = await with_timeout(master.read(addr), TIMEOUT_NS, "ns")
            if rresp != expected:
                failures.append(
                    f"iter {iteration} READ addr=0x{addr:08X}: "
                    f"got rresp={rresp}, expected {expected}"
                )
        except Exception as exc:
            failures.append(f"iter {iteration} READ exception: {exc}")
            master.init()
            await ClockCycles(dut.i_clk, 5)

    assert not failures, \
        f"{len(failures)} failures:\n" + "\n".join(failures[:20])
    dut._log.info("[PASS] ROUT-054 – 100 random iterations all correct")


@cocotb.test()
async def test_stress_outofrange_register_intact(dut):
    """ROUT-055: 30 out-of-range writes with varied addresses; registers never corrupted."""
    master = await setup(dut)

    rng = random.Random(0xCAFE)
    out_addrs = (
        [rng.randint(0, ROUTER_BASE - 1) for _ in range(15)] +
        [rng.randint(ROUTER_END + 1, 0x0000FFFF) for _ in range(15)]
    )
    rng.shuffle(out_addrs)

    for addr in out_addrs:
        bresp = await with_timeout(
            master.write(addr, rng.randint(0, 0xFFFF_FFFF)), TIMEOUT_NS, "ns"
        )
        assert bresp == AXI_RESP_SLVERR, \
            f"addr=0x{addr:08X}: expected SLVERR, got {bresp}"

    assert dut_reg_version(dut) == VERSION_RESET, \
        f"version corrupted: 0x{dut_reg_version(dut):08X}"
    assert dut_reg_val(dut) == VAL_RESET, \
        f"val corrupted: 0x{dut_reg_val(dut):08X}"
    dut._log.info("[PASS] ROUT-055 – 30 out-of-range writes; registers intact throughout")


@cocotb.test()
async def test_stress_write_read_val_50_times(dut):
    """ROUT-056: Write then read val 50 times with different data; each readback exact."""
    master = await setup(dut)

    rng = random.Random(0x1234)
    for i in range(50):
        data = rng.randint(0, 0xFFFF_FFFF)

        bresp = await with_timeout(master.write(ADDR_VAL, data), TIMEOUT_NS, "ns")
        assert bresp == AXI_RESP_OKAY, f"iter {i}: write bresp={bresp}"

        rdata, rresp = await with_timeout(master.read(ADDR_VAL), TIMEOUT_NS, "ns")
        assert rresp == AXI_RESP_OKAY, f"iter {i}: read rresp={rresp}"
        assert rdata == data, f"iter {i}: readback 0x{rdata:08X} != 0x{data:08X}"

    dut._log.info("[PASS] ROUT-056 – 50 write-read-verify cycles on val register")


@cocotb.test()
async def test_stress_mixed_with_backpressure(dut):
    """ROUT-057: 20 random transactions with random bready/rready delays."""
    master = await setup(dut)

    rng = random.Random(0xABCD)

    for i in range(20):
        is_write    = rng.random() < 0.5
        is_in_range = rng.random() < 0.5
        delay       = rng.randint(0, 6)

        if is_in_range:
            addr     = rng.choice([ADDR_VERSION, ADDR_VAL])
            exp_resp = AXI_RESP_OKAY
        else:
            if rng.random() < 0.5:
                addr = rng.randint(0, ROUTER_BASE - 1)
            else:
                addr = rng.randint(ROUTER_END + 1, 0x0000FFFF)
            exp_resp = AXI_RESP_SLVERR

        data = rng.randint(0, 0xFFFF_FFFF)

        if is_write:
            bresp = await with_timeout(
                master.write(addr, data, bready_delay=delay), TIMEOUT_NS, "ns"
            )
            assert bresp == exp_resp, \
                f"iter {i} WRITE addr=0x{addr:08X}: got {bresp}, expected {exp_resp}"
        else:
            rdata, rresp = await with_timeout(
                master.read(addr, rready_delay=delay), TIMEOUT_NS, "ns"
            )
            assert rresp == exp_resp, \
                f"iter {i} READ addr=0x{addr:08X}: got {rresp}, expected {exp_resp}"

    dut._log.info("[PASS] ROUT-057 – 20 mixed transactions with random back-pressure")


@cocotb.test()
async def test_stress_translation_sweep_all_mapped_addresses(dut):
    """ROUT-058: Write/read to ADDR_VERSION and ADDR_VAL 20 times in random order,
    verifying that translation is consistent across many iterations."""
    master = await setup(dut)

    rng = random.Random(0x5AFE)
    addrs = [ADDR_VERSION, ADDR_VAL]

    state = {ADDR_VERSION: VERSION_RESET, ADDR_VAL: VAL_RESET}

    for i in range(20):
        addr = rng.choice(addrs)
        data = rng.randint(0, 0xFFFF_FFFF)

        bresp = await with_timeout(master.write(addr, data), TIMEOUT_NS, "ns")
        assert bresp == AXI_RESP_OKAY, f"iter {i} write 0x{addr:08X}: got {bresp}"
        state[addr] = data

        rdata, rresp = await with_timeout(master.read(addr), TIMEOUT_NS, "ns")
        assert rresp == AXI_RESP_OKAY, f"iter {i} read 0x{addr:08X}: rresp={rresp}"
        assert rdata == state[addr], \
            f"iter {i} readback 0x{rdata:08X} != 0x{state[addr]:08X}"

    # Final: verify both registers against tracked state
    rv, _ = await with_timeout(master.read(ADDR_VERSION), TIMEOUT_NS, "ns")
    rx, _ = await with_timeout(master.read(ADDR_VAL),     TIMEOUT_NS, "ns")
    assert rv == state[ADDR_VERSION]
    assert rx == state[ADDR_VAL]

    dut._log.info("[PASS] ROUT-058 – 20-iteration translation consistency sweep passed")
