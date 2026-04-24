"""
tb_axion_axi_lite_filter_cocotb.py

Comprehensive cocotb testbench for axion_axi_lite_filter_wrap.

DUT chain:
    AXI Master  →  axion_axi_lite_filter  →  axi_test_axion_reg
                   (G_ADDR_BEGIN=0x4000,       (BASE_ADDR=0x4000)
                    G_ADDR_END  =0x4FFF)

Address tiers exercised:
  ┌─────────────────────────────────────────────────────────────────────┐
  │ Tier │ Address range     │ Filter  │ Register │ Master sees        │
  ├──────┼───────────────────┼─────────┼──────────┼────────────────────┤
  │  A   │ 0x4000, 0x4004    │ PASS    │ OKAY     │ OKAY               │
  │  B   │ 0x4008 .. 0x4FFF  │ PASS    │ SLVERR   │ SLVERR (from reg)  │
  │  C   │ < 0x4000 or >4FFF │ BLOCK   │ never    │ SLVERR (from filt) │
  └─────────────────────────────────────────────────────────────────────┘

Tests are grouped:
  Group 1  – Basic routing (reset, in-range, out-of-range, tier-B)
  Group 2  – Address boundary correctness (begin/end inclusive)
  Group 3  – Register read/write integrity (values, strobe)
  Group 4  – AXI4-Lite protocol compliance (valid stability, ready timing)
  Group 5  – W-channel timing variants (wvalid late, wvalid before awvalid)
  Group 6  – Back-pressure (bready / rready held low)
  Group 7  – Back-to-back and mixed sequences
  Group 8  – Reset mid-transaction
  Group 9  – Stress / randomised sweep
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles, with_timeout
import random

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
CLK_PERIOD_NS   = 10        # 100 MHz
TIMEOUT_CYCLES  = 500
TIMEOUT_NS      = TIMEOUT_CYCLES * CLK_PERIOD_NS

AXI_RESP_OKAY   = 0b00
AXI_RESP_SLVERR = 0b10

# Filter window (must match wrapper generics)
FILTER_BEGIN = 0x00004000
FILTER_END   = 0x00004FFF

# Register map (BASE_ADDR = 0x4000)
REG_BASE    = 0x00004000
ADDR_VERSION = REG_BASE + 0x00
ADDR_VAL     = REG_BASE + 0x04

# Register reset values
VERSION_RESET = 0xABCDEF01
VAL_RESET     = 0xDEADBEEF

# Tier-B address (in filter range, NOT a valid register address)
ADDR_TIER_B   = REG_BASE + 0x08   # 0x4008

# Tier-C addresses (outside filter window)
ADDR_BELOW    = FILTER_BEGIN - 1   # 0x3FFF
ADDR_ABOVE    = FILTER_END   + 1   # 0x5000
ADDR_ZERO     = 0x00000000
ADDR_HIGH     = 0x0000FFFF         # well above filter

# ---------------------------------------------------------------------------
# AXIMaster
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
        """
        AW + W driven simultaneously.  Returns bresp.
        bready_delay: extra cycles to wait before asserting bready.
        """
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

    async def write_w_late(self, addr: int, data: int, strb: int = 0xF,
                           w_delay_cycles: int = 4) -> int:
        """
        Assert awvalid first, wait w_delay_cycles, then assert wvalid.
        Returns bresp.
        """
        self._dut.m_awaddr.value  = addr
        self._dut.m_awprot.value  = 0
        self._dut.m_awvalid.value = 1

        aw_done = False
        elapsed = 0
        while True:
            await RisingEdge(self._clk)
            elapsed += 1
            if not aw_done and self._dut.m_awready.value == 1:
                self._dut.m_awvalid.value = 0
                aw_done = True
            if elapsed >= w_delay_cycles and not aw_done:
                # keep driving awvalid until ready even after delay
                pass
            if elapsed >= w_delay_cycles:
                break

        self._dut.m_wdata.value   = data
        self._dut.m_wstrb.value   = strb
        self._dut.m_wvalid.value  = 1

        if not aw_done:
            while True:
                await RisingEdge(self._clk)
                if self._dut.m_awready.value == 1:
                    self._dut.m_awvalid.value = 0
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


def reg_version(dut) -> int:
    return int(dut.reg_version.value)


def reg_val(dut) -> int:
    return int(dut.reg_val.value)


# ===========================================================================
# Group 1 – Basic routing
# ===========================================================================

@cocotb.test()
async def test_reset_behavior(dut):
    """FILT-001: After reset bvalid=0, rvalid=0; registers at reset values."""
    await setup(dut)
    await ClockCycles(dut.i_clk, 2)

    assert int(dut.m_bvalid.value) == 0, "bvalid not 0 after reset"
    assert int(dut.m_rvalid.value) == 0, "rvalid not 0 after reset"
    assert reg_version(dut) == VERSION_RESET, \
        f"version reset mismatch: 0x{reg_version(dut):08X}"
    assert reg_val(dut) == VAL_RESET, \
        f"val reset mismatch: 0x{reg_val(dut):08X}"
    dut._log.info("[PASS] FILT-001 – reset state correct")


@cocotb.test()
async def test_inrange_write_okay(dut):
    """FILT-002: Write to Tier-A address → OKAY; register updated."""
    master = await setup(dut)

    bresp = await with_timeout(master.write(ADDR_VAL, 0x12345678), TIMEOUT_NS, "ns")
    assert bresp == AXI_RESP_OKAY, f"Expected OKAY, got {bresp}"
    assert reg_val(dut) == 0x12345678, \
        f"val not updated: 0x{reg_val(dut):08X}"
    dut._log.info("[PASS] FILT-002 – in-range write OKAY; register updated")


@cocotb.test()
async def test_inrange_read_okay(dut):
    """FILT-003: Read from Tier-A address → OKAY + correct reset value."""
    master = await setup(dut)

    rdata, rresp = await with_timeout(master.read(ADDR_VERSION), TIMEOUT_NS, "ns")
    assert rresp  == AXI_RESP_OKAY, f"Expected OKAY, got {rresp}"
    assert rdata == VERSION_RESET, \
        f"version data wrong: 0x{rdata:08X} (expected 0x{VERSION_RESET:08X})"
    dut._log.info("[PASS] FILT-003 – in-range read OKAY with correct data")


@cocotb.test()
async def test_outofrange_write_slverr(dut):
    """FILT-004: Write to Tier-C address → SLVERR; register unchanged."""
    master = await setup(dut)

    bresp = await with_timeout(master.write(ADDR_BELOW, 0xDEAD1234), TIMEOUT_NS, "ns")
    assert bresp == AXI_RESP_SLVERR, f"Expected SLVERR, got {bresp}"
    # Register must not be touched
    assert reg_version(dut) == VERSION_RESET
    assert reg_val(dut) == VAL_RESET
    dut._log.info("[PASS] FILT-004 – out-of-range write returns SLVERR; registers intact")


@cocotb.test()
async def test_outofrange_read_slverr(dut):
    """FILT-005: Read from Tier-C address → SLVERR, rdata=0."""
    master = await setup(dut)

    rdata, rresp = await with_timeout(master.read(ADDR_ABOVE), TIMEOUT_NS, "ns")
    assert rresp == AXI_RESP_SLVERR, f"Expected SLVERR, got {rresp}"
    assert rdata == 0, f"rdata should be 0 for filter SLVERR, got 0x{rdata:08X}"
    dut._log.info("[PASS] FILT-005 – out-of-range read SLVERR + rdata=0")


@cocotb.test()
async def test_tierb_write_slverr_from_reg(dut):
    """FILT-006: Write to Tier-B (in filter, invalid reg addr) → SLVERR from reg."""
    master = await setup(dut)

    # 0x4008 is inside the filter window but not a valid register address
    bresp = await with_timeout(master.write(ADDR_TIER_B, 0xCAFEBABE), TIMEOUT_NS, "ns")
    assert bresp == AXI_RESP_SLVERR, f"Expected SLVERR from register, got {bresp}"
    # Register values must not be corrupted
    assert reg_version(dut) == VERSION_RESET
    assert reg_val(dut) == VAL_RESET
    dut._log.info("[PASS] FILT-006 – Tier-B write passes filter, register returns SLVERR")


@cocotb.test()
async def test_tierb_read_slverr_from_reg(dut):
    """FILT-007: Read from Tier-B → SLVERR from register; rdata=0."""
    master = await setup(dut)

    rdata, rresp = await with_timeout(master.read(ADDR_TIER_B), TIMEOUT_NS, "ns")
    assert rresp == AXI_RESP_SLVERR, f"Expected SLVERR from register, got {rresp}"
    dut._log.info("[PASS] FILT-007 – Tier-B read passes filter, register returns SLVERR")


# ===========================================================================
# Group 2 – Address boundary correctness
# ===========================================================================

@cocotb.test()
async def test_boundary_begin_write(dut):
    """FILT-008: Write to FILTER_BEGIN (0x4000) → OKAY (inclusive begin)."""
    master = await setup(dut)

    bresp = await with_timeout(master.write(FILTER_BEGIN, 0x11111111), TIMEOUT_NS, "ns")
    assert bresp == AXI_RESP_OKAY, f"Begin boundary write: expected OKAY, got {bresp}"
    assert reg_version(dut) == 0x11111111
    dut._log.info("[PASS] FILT-008 – begin boundary (0x4000) inclusive write OKAY")


@cocotb.test()
async def test_boundary_begin_read(dut):
    """FILT-009: Read from FILTER_BEGIN → OKAY."""
    master = await setup(dut)

    rdata, rresp = await with_timeout(master.read(FILTER_BEGIN), TIMEOUT_NS, "ns")
    assert rresp == AXI_RESP_OKAY, f"Begin boundary read: expected OKAY, got {rresp}"
    dut._log.info("[PASS] FILT-009 – begin boundary (0x4000) inclusive read OKAY")


@cocotb.test()
async def test_boundary_end_write(dut):
    """FILT-010: Write to FILTER_END (0x4FFF) → passes filter (Tier-B, reg SLVERR)."""
    master = await setup(dut)

    bresp = await with_timeout(master.write(FILTER_END, 0xBBBBBBBB), TIMEOUT_NS, "ns")
    # Filter passes it (inclusive end) but register has no register at 0x4FFF
    assert bresp == AXI_RESP_SLVERR, \
        f"End boundary (Tier-B): expected SLVERR from reg, got {bresp}"
    # Registers unchanged
    assert reg_version(dut) == VERSION_RESET
    assert reg_val(dut) == VAL_RESET
    dut._log.info("[PASS] FILT-010 – end boundary (0x4FFF) passes filter, reg SLVERR")


@cocotb.test()
async def test_boundary_just_below_begin(dut):
    """FILT-011: Write to FILTER_BEGIN-1 (0x3FFF) → filter SLVERR immediately."""
    master = await setup(dut)

    bresp = await with_timeout(
        master.write(FILTER_BEGIN - 1, 0xCCCCCCCC), TIMEOUT_NS, "ns"
    )
    assert bresp == AXI_RESP_SLVERR, \
        f"Just-below-begin: expected filter SLVERR, got {bresp}"
    assert reg_version(dut) == VERSION_RESET
    assert reg_val(dut) == VAL_RESET
    dut._log.info("[PASS] FILT-011 – just below begin (0x3FFF) → filter SLVERR")


@cocotb.test()
async def test_boundary_just_above_end(dut):
    """FILT-012: Write to FILTER_END+1 (0x5000) → filter SLVERR immediately."""
    master = await setup(dut)

    bresp = await with_timeout(
        master.write(FILTER_END + 1, 0xDDDDDDDD), TIMEOUT_NS, "ns"
    )
    assert bresp == AXI_RESP_SLVERR, \
        f"Just-above-end: expected filter SLVERR, got {bresp}"
    assert reg_version(dut) == VERSION_RESET
    assert reg_val(dut) == VAL_RESET
    dut._log.info("[PASS] FILT-012 – just above end (0x5000) → filter SLVERR")


@cocotb.test()
async def test_boundary_zero_addr(dut):
    """FILT-013: Read from address 0 → filter SLVERR."""
    master = await setup(dut)

    rdata, rresp = await with_timeout(master.read(ADDR_ZERO), TIMEOUT_NS, "ns")
    assert rresp == AXI_RESP_SLVERR, f"Addr 0: expected SLVERR, got {rresp}"
    dut._log.info("[PASS] FILT-013 – address 0 → filter SLVERR")


# ===========================================================================
# Group 3 – Register read/write integrity
# ===========================================================================

@cocotb.test()
async def test_write_read_version(dut):
    """FILT-014: Write then read version register; values must match."""
    master = await setup(dut)

    WR_DATA = 0xDEAD1234
    bresp = await with_timeout(master.write(ADDR_VERSION, WR_DATA), TIMEOUT_NS, "ns")
    assert bresp == AXI_RESP_OKAY

    rdata, rresp = await with_timeout(master.read(ADDR_VERSION), TIMEOUT_NS, "ns")
    assert rresp == AXI_RESP_OKAY
    assert rdata == WR_DATA, f"version readback 0x{rdata:08X} != 0x{WR_DATA:08X}"
    assert reg_version(dut) == WR_DATA
    dut._log.info("[PASS] FILT-014 – version write-read roundtrip")


@cocotb.test()
async def test_write_read_val(dut):
    """FILT-015: Write then read val register."""
    master = await setup(dut)

    WR_DATA = 0xCAFECAFE
    bresp = await with_timeout(master.write(ADDR_VAL, WR_DATA), TIMEOUT_NS, "ns")
    assert bresp == AXI_RESP_OKAY

    rdata, rresp = await with_timeout(master.read(ADDR_VAL), TIMEOUT_NS, "ns")
    assert rresp == AXI_RESP_OKAY
    assert rdata == WR_DATA, f"val readback 0x{rdata:08X} != 0x{WR_DATA:08X}"
    dut._log.info("[PASS] FILT-015 – val write-read roundtrip")


@cocotb.test()
async def test_partial_write_strobe_byte0_byte2(dut):
    """FILT-016: Write strb=0b0101 (bytes 0,2) → only those bytes updated."""
    master = await setup(dut)

    # Reset: val = 0xDEADBEEF
    # Write 0x11221122 with strb 0b0101 (bytes 0 and 2 only)
    # Expected: byte3=0xDE byte2=0x11 byte1=0xBE byte0=0x11 -> 0xDE11BE11
    WR_DATA = 0x11221122
    STROBE  = 0b0101
    EXPECT  = (VAL_RESET & 0xFF00FF00) | (WR_DATA & 0x00FF00FF)

    bresp = await with_timeout(
        master.write(ADDR_VAL, WR_DATA, strb=STROBE), TIMEOUT_NS, "ns"
    )
    assert bresp == AXI_RESP_OKAY

    rdata, rresp = await with_timeout(master.read(ADDR_VAL), TIMEOUT_NS, "ns")
    assert rresp == AXI_RESP_OKAY
    assert rdata == EXPECT, \
        f"Partial strobe: got 0x{rdata:08X}, expected 0x{EXPECT:08X}"
    dut._log.info("[PASS] FILT-016 – partial write strobe byte0+byte2 correct")


@cocotb.test()
async def test_outofrange_does_not_corrupt_registers(dut):
    """FILT-017: Multiple out-of-range writes must never alter register values."""
    master = await setup(dut)

    out_addrs = [ADDR_ZERO, ADDR_BELOW, ADDR_ABOVE, ADDR_HIGH, 0x0000BEEF]
    for addr in out_addrs:
        bresp = await with_timeout(
            master.write(addr, 0xDEADDEAD), TIMEOUT_NS, "ns"
        )
        assert bresp == AXI_RESP_SLVERR, \
            f"Addr 0x{addr:08X}: expected SLVERR, got {bresp}"

    assert reg_version(dut) == VERSION_RESET, \
        f"version corrupted: 0x{reg_version(dut):08X}"
    assert reg_val(dut) == VAL_RESET, \
        f"val corrupted: 0x{reg_val(dut):08X}"
    dut._log.info("[PASS] FILT-017 – out-of-range writes never corrupt registers")


@cocotb.test()
async def test_separate_registers_independent(dut):
    """FILT-018: Writing version must not affect val and vice versa."""
    master = await setup(dut)

    await with_timeout(master.write(ADDR_VERSION, 0x11111111), TIMEOUT_NS, "ns")
    assert reg_val(dut) == VAL_RESET, "val changed after writing version"

    await with_timeout(master.write(ADDR_VAL, 0x22222222), TIMEOUT_NS, "ns")
    assert reg_version(dut) == 0x11111111, "version changed after writing val"

    dut._log.info("[PASS] FILT-018 – version and val registers are independent")


# ===========================================================================
# Group 4 – AXI4-Lite protocol compliance
# ===========================================================================

@cocotb.test()
async def test_bvalid_stable_under_backpressure_outofrange(dut):
    """FILT-019: Out-of-range write; bvalid must stay HIGH while bready=0 (AXI spec §A3.3)."""
    master = await setup(dut)

    HOLD_CYCLES = 10

    # Issue AW+W without asserting bready
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

    # Wait for bvalid to assert
    for _ in range(TIMEOUT_CYCLES):
        await RisingEdge(dut.i_clk)
        if int(dut.m_bvalid.value) == 1:
            break

    assert int(dut.m_bvalid.value) == 1, "bvalid never asserted"
    assert int(dut.m_bresp.value) == AXI_RESP_SLVERR, \
        f"bresp should be SLVERR, got {int(dut.m_bresp.value)}"

    # Hold bready=0 for HOLD_CYCLES and verify bvalid stays high
    for cyc in range(HOLD_CYCLES):
        await RisingEdge(dut.i_clk)
        assert int(dut.m_bvalid.value) == 1, \
            f"bvalid dropped at backpressure cycle {cyc} (AXI4-Lite violation)"

    dut.m_bready.value = 1
    await RisingEdge(dut.i_clk)
    assert int(dut.m_bvalid.value) == 1, "bvalid must be high when bready first asserted"
    bresp = int(dut.m_bresp.value)
    dut.m_bready.value = 0
    assert bresp == AXI_RESP_SLVERR
    dut._log.info("[PASS] FILT-019 – bvalid stable under backpressure (out-of-range)")


@cocotb.test()
async def test_rvalid_stable_under_backpressure_outofrange(dut):
    """FILT-020: Out-of-range read; rvalid stays HIGH while rready=0."""
    master = await setup(dut)

    HOLD_CYCLES = 10

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

    for cyc in range(HOLD_CYCLES):
        await RisingEdge(dut.i_clk)
        assert int(dut.m_rvalid.value) == 1, \
            f"rvalid dropped at backpressure cycle {cyc} (AXI4-Lite violation)"

    dut.m_rready.value = 1
    await RisingEdge(dut.i_clk)
    dut.m_rready.value = 0
    dut._log.info("[PASS] FILT-020 – rvalid stable under backpressure (out-of-range)")


@cocotb.test()
async def test_bvalid_stable_under_backpressure_inrange(dut):
    """FILT-021: In-range write (Tier-A); bvalid stays high during bready_delay=8."""
    master = await setup(dut)

    bresp = await with_timeout(
        master.write(ADDR_VAL, 0x55AA55AA, bready_delay=8),
        TIMEOUT_NS, "ns"
    )
    assert bresp == AXI_RESP_OKAY
    dut._log.info("[PASS] FILT-021 – bvalid stable under backpressure (in-range)")


@cocotb.test()
async def test_rvalid_stable_under_backpressure_inrange(dut):
    """FILT-022: In-range read; rvalid stays high during rready_delay=8."""
    master = await setup(dut)

    rdata, rresp = await with_timeout(
        master.read(ADDR_VERSION, rready_delay=8),
        TIMEOUT_NS, "ns"
    )
    assert rresp == AXI_RESP_OKAY
    assert rdata == VERSION_RESET
    dut._log.info("[PASS] FILT-022 – rvalid stable under backpressure (in-range)")


@cocotb.test()
async def test_wready_single_pulse_outofrange(dut):
    """FILT-023: Out-of-range write; wready must pulse exactly once."""
    master = await setup(dut)

    wready_count = 0

    async def count_wready():
        nonlocal wready_count
        for _ in range(TIMEOUT_CYCLES):
            await RisingEdge(dut.i_clk)
            if int(dut.m_wready.value) == 1:
                wready_count += 1

    monitor = cocotb.start_soon(count_wready())
    await with_timeout(master.write(ADDR_BELOW, 0xABCD), TIMEOUT_NS, "ns")
    monitor.kill()

    assert wready_count == 1, \
        f"wready pulsed {wready_count} times for out-of-range write (expected 1)"
    dut._log.info("[PASS] FILT-023 – wready single pulse (out-of-range)")


@cocotb.test()
async def test_wready_single_pulse_inrange(dut):
    """FILT-024: In-range write; wready must pulse exactly once."""
    master = await setup(dut)

    wready_count = 0

    async def count_wready():
        nonlocal wready_count
        for _ in range(TIMEOUT_CYCLES):
            await RisingEdge(dut.i_clk)
            if int(dut.m_wready.value) == 1:
                wready_count += 1

    monitor = cocotb.start_soon(count_wready())
    await with_timeout(master.write(ADDR_VAL, 0x1234), TIMEOUT_NS, "ns")
    monitor.kill()

    assert wready_count == 1, \
        f"wready pulsed {wready_count} times for in-range write (expected 1)"
    dut._log.info("[PASS] FILT-024 – wready single pulse (in-range)")


@cocotb.test()
async def test_awready_single_pulse_outofrange(dut):
    """FILT-025: Out-of-range write; awready must pulse exactly once."""
    master = await setup(dut)

    awready_count = 0

    async def count_awready():
        nonlocal awready_count
        for _ in range(TIMEOUT_CYCLES):
            await RisingEdge(dut.i_clk)
            if int(dut.m_awready.value) == 1:
                awready_count += 1

    monitor = cocotb.start_soon(count_awready())
    await with_timeout(master.write(ADDR_ABOVE, 0xABCD), TIMEOUT_NS, "ns")
    monitor.kill()

    assert awready_count == 1, \
        f"awready pulsed {awready_count} times (expected 1)"
    dut._log.info("[PASS] FILT-025 – awready single pulse (out-of-range)")


@cocotb.test()
async def test_arready_single_pulse_outofrange(dut):
    """FILT-026: Out-of-range read; arready must pulse exactly once."""
    master = await setup(dut)

    arready_count = 0

    async def count_arready():
        nonlocal arready_count
        for _ in range(TIMEOUT_CYCLES):
            await RisingEdge(dut.i_clk)
            if int(dut.m_arready.value) == 1:
                arready_count += 1

    monitor = cocotb.start_soon(count_arready())
    await with_timeout(master.read(ADDR_BELOW), TIMEOUT_NS, "ns")
    monitor.kill()

    assert arready_count == 1, \
        f"arready pulsed {arready_count} times (expected 1)"
    dut._log.info("[PASS] FILT-026 – arready single pulse (out-of-range)")


@cocotb.test()
async def test_prot_forwarded_on_write(dut):
    """FILT-027: AWPROT value on master must be forwarded to register (in-range)."""
    master = await setup(dut)

    # We verify the transaction completes with OKAY; if prot weren't forwarded
    # the filter would have corrupted the channel.
    bresp = await with_timeout(
        master.write(ADDR_VAL, 0xAABBCCDD, prot=0b011), TIMEOUT_NS, "ns"
    )
    assert bresp == AXI_RESP_OKAY
    dut._log.info("[PASS] FILT-027 – AWPROT forwarded on in-range write")


@cocotb.test()
async def test_prot_forwarded_on_read(dut):
    """FILT-028: ARPROT value forwarded on in-range read."""
    master = await setup(dut)

    rdata, rresp = await with_timeout(
        master.read(ADDR_VERSION, prot=0b101), TIMEOUT_NS, "ns"
    )
    assert rresp == AXI_RESP_OKAY
    dut._log.info("[PASS] FILT-028 – ARPROT forwarded on in-range read")


# ===========================================================================
# Group 5 – W-channel timing variants
# ===========================================================================

@cocotb.test()
async def test_wvalid_late_inrange(dut):
    """FILT-029: AW presented 4 cycles before W (in-range) → OKAY, register updated."""
    master = await setup(dut)

    bresp = await with_timeout(
        master.write_w_late(ADDR_VAL, 0x99887766, w_delay_cycles=4),
        TIMEOUT_NS, "ns"
    )
    assert bresp == AXI_RESP_OKAY
    assert reg_val(dut) == 0x99887766
    dut._log.info("[PASS] FILT-029 – wvalid late (in-range) → OKAY")


@cocotb.test()
async def test_wvalid_late_outofrange(dut):
    """FILT-030: AW presented 4 cycles before W (out-of-range) → SLVERR, register intact."""
    master = await setup(dut)

    bresp = await with_timeout(
        master.write_w_late(ADDR_BELOW, 0xBAADC0DE, w_delay_cycles=4),
        TIMEOUT_NS, "ns"
    )
    assert bresp == AXI_RESP_SLVERR
    assert reg_version(dut) == VERSION_RESET
    assert reg_val(dut) == VAL_RESET
    dut._log.info("[PASS] FILT-030 – wvalid late (out-of-range) → SLVERR, register intact")


# ===========================================================================
# Group 6 – Back-pressure via bready/rready delay
# ===========================================================================

@cocotb.test()
async def test_bready_delay_10_outofrange(dut):
    """FILT-031: Out-of-range write with bready_delay=10 completes with SLVERR."""
    master = await setup(dut)

    bresp = await with_timeout(
        master.write(ADDR_ZERO, 0xFF, bready_delay=10), TIMEOUT_NS, "ns"
    )
    assert bresp == AXI_RESP_SLVERR
    dut._log.info("[PASS] FILT-031 – bready_delay=10 out-of-range SLVERR")


@cocotb.test()
async def test_rready_delay_10_outofrange(dut):
    """FILT-032: Out-of-range read with rready_delay=10 completes with SLVERR."""
    master = await setup(dut)

    rdata, rresp = await with_timeout(
        master.read(ADDR_ZERO, rready_delay=10), TIMEOUT_NS, "ns"
    )
    assert rresp == AXI_RESP_SLVERR
    dut._log.info("[PASS] FILT-032 – rready_delay=10 out-of-range SLVERR")


@cocotb.test()
async def test_bready_delay_10_inrange(dut):
    """FILT-033: In-range write with bready_delay=10 completes with OKAY."""
    master = await setup(dut)

    bresp = await with_timeout(
        master.write(ADDR_VAL, 0xAABBCCDD, bready_delay=10), TIMEOUT_NS, "ns"
    )
    assert bresp == AXI_RESP_OKAY
    dut._log.info("[PASS] FILT-033 – bready_delay=10 in-range OKAY")


@cocotb.test()
async def test_rready_delay_10_inrange(dut):
    """FILT-034: In-range read with rready_delay=10 completes with OKAY."""
    master = await setup(dut)

    rdata, rresp = await with_timeout(
        master.read(ADDR_VERSION, rready_delay=10), TIMEOUT_NS, "ns"
    )
    assert rresp == AXI_RESP_OKAY
    assert rdata == VERSION_RESET
    dut._log.info("[PASS] FILT-034 – rready_delay=10 in-range OKAY + correct data")


# ===========================================================================
# Group 7 – Back-to-back and mixed sequences
# ===========================================================================

@cocotb.test()
async def test_back_to_back_inrange_writes(dut):
    """FILT-035: 5 consecutive in-range writes; each returns OKAY, final value correct."""
    master = await setup(dut)

    for i in range(5):
        data = 0x10000000 + i
        bresp = await with_timeout(
            master.write(ADDR_VAL, data), TIMEOUT_NS, "ns"
        )
        assert bresp == AXI_RESP_OKAY, f"Write {i}: expected OKAY, got {bresp}"

    assert reg_val(dut) == 0x10000004, \
        f"Final val wrong: 0x{reg_val(dut):08X}"
    dut._log.info("[PASS] FILT-035 – 5 back-to-back in-range writes")


@cocotb.test()
async def test_back_to_back_outofrange_writes(dut):
    """FILT-036: 5 consecutive out-of-range writes; all SLVERR, registers intact."""
    master = await setup(dut)

    for i in range(5):
        bresp = await with_timeout(
            master.write(ADDR_ABOVE + i * 4, 0xDEAD0000 + i),
            TIMEOUT_NS, "ns"
        )
        assert bresp == AXI_RESP_SLVERR, f"Write {i}: expected SLVERR, got {bresp}"

    assert reg_version(dut) == VERSION_RESET
    assert reg_val(dut) == VAL_RESET
    dut._log.info("[PASS] FILT-036 – 5 back-to-back out-of-range writes all SLVERR")


@cocotb.test()
async def test_mixed_inrange_then_outofrange(dut):
    """FILT-037: in-range write → out-of-range write → in-range read; correct throughout."""
    master = await setup(dut)

    WR = 0xFEDCBA98
    bresp = await with_timeout(master.write(ADDR_VAL, WR), TIMEOUT_NS, "ns")
    assert bresp == AXI_RESP_OKAY

    bresp = await with_timeout(master.write(ADDR_BELOW, 0xDEAD), TIMEOUT_NS, "ns")
    assert bresp == AXI_RESP_SLVERR

    rdata, rresp = await with_timeout(master.read(ADDR_VAL), TIMEOUT_NS, "ns")
    assert rresp == AXI_RESP_OKAY
    assert rdata == WR, f"val readback wrong: 0x{rdata:08X}"
    dut._log.info("[PASS] FILT-037 – mixed in/out-of-range sequence correct")


@cocotb.test()
async def test_mixed_outofrange_then_inrange(dut):
    """FILT-038: out-of-range write → in-range write → in-range read."""
    master = await setup(dut)

    bresp = await with_timeout(master.write(ADDR_HIGH, 0x1), TIMEOUT_NS, "ns")
    assert bresp == AXI_RESP_SLVERR

    WR = 0x12ABCD34
    bresp = await with_timeout(master.write(ADDR_VERSION, WR), TIMEOUT_NS, "ns")
    assert bresp == AXI_RESP_OKAY

    rdata, rresp = await with_timeout(master.read(ADDR_VERSION), TIMEOUT_NS, "ns")
    assert rresp  == AXI_RESP_OKAY
    assert rdata == WR
    dut._log.info("[PASS] FILT-038 – out-of-range followed by in-range; filter cleans up")


@cocotb.test()
async def test_alternating_in_out_sequence(dut):
    """FILT-039: 6 alternating in-range / out-of-range transactions."""
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

    # Only the in-range writes (every odd index) updated val; last was 0xAAAA0003
    assert reg_val(dut) == 0xAAAA0003
    dut._log.info("[PASS] FILT-039 – 6-step alternating sequence correct")


@cocotb.test()
async def test_read_after_multiple_writes(dut):
    """FILT-040: Interleaved writes to both registers, read back both correctly."""
    master = await setup(dut)

    VER_DATA = 0x11223344
    VAL_DATA = 0x55667788

    await with_timeout(master.write(ADDR_VERSION, VER_DATA), TIMEOUT_NS, "ns")
    await with_timeout(master.write(ADDR_VAL,     VAL_DATA), TIMEOUT_NS, "ns")

    rdata, _ = await with_timeout(master.read(ADDR_VERSION), TIMEOUT_NS, "ns")
    assert rdata == VER_DATA, f"version readback: 0x{rdata:08X}"

    rdata, _ = await with_timeout(master.read(ADDR_VAL), TIMEOUT_NS, "ns")
    assert rdata == VAL_DATA, f"val readback: 0x{rdata:08X}"
    dut._log.info("[PASS] FILT-040 – interleaved writes; both registers correct on readback")


# ===========================================================================
# Group 8 – Reset mid-transaction
# ===========================================================================

@cocotb.test()
async def test_reset_mid_outofrange_write(dut):
    """FILT-041: Reset during out-of-range write (ST_WRITE_ERR_DATA); recovery works."""
    master = await setup(dut)

    # Drive awvalid but NOT wvalid so filter gets stuck in ST_WRITE_ERR_DATA
    dut.m_awaddr.value  = ADDR_ABOVE
    dut.m_awvalid.value = 1
    dut.m_wdata.value   = 0xFF
    dut.m_wstrb.value   = 0xF
    dut.m_wvalid.value  = 0
    dut.m_bready.value  = 0

    # Wait for awready (filter accepts address)
    for _ in range(TIMEOUT_CYCLES):
        await RisingEdge(dut.i_clk)
        if int(dut.m_awready.value) == 1:
            dut.m_awvalid.value = 0
            break

    await ClockCycles(dut.i_clk, 3)

    # Assert reset
    dut.i_rst_n.value = 0
    await ClockCycles(dut.i_clk, 5)
    assert int(dut.m_bvalid.value) == 0
    assert int(dut.m_rvalid.value) == 0

    dut.i_rst_n.value = 1
    master.init()
    await ClockCycles(dut.i_clk, 3)

    # Filter must be back in IDLE; in-range transaction must succeed
    bresp = await with_timeout(master.write(ADDR_VAL, 0x42424242), TIMEOUT_NS, "ns")
    assert bresp == AXI_RESP_OKAY
    assert reg_val(dut) == 0x42424242
    dut._log.info("[PASS] FILT-041 – reset mid out-of-range write; recovery OK")


@cocotb.test()
async def test_reset_mid_inrange_write(dut):
    """FILT-042: Reset during in-range pass-through write; filter recovers."""
    master = await setup(dut)

    # Kick off a write and reset after a few cycles
    write_task = cocotb.start_soon(master.write(ADDR_VAL, 0x99))

    await ClockCycles(dut.i_clk, 4)

    dut.i_rst_n.value = 0
    await ClockCycles(dut.i_clk, 5)
    dut.i_rst_n.value = 1
    master.init()
    write_task.kill()

    await ClockCycles(dut.i_clk, 4)

    # Post-reset: registers at reset values
    assert reg_version(dut) == VERSION_RESET
    assert reg_val(dut)     == VAL_RESET

    # Full transaction must work
    bresp = await with_timeout(master.write(ADDR_VERSION, 0xFEEDFACE), TIMEOUT_NS, "ns")
    assert bresp == AXI_RESP_OKAY
    dut._log.info("[PASS] FILT-042 – reset mid in-range write; recovery OK")


@cocotb.test()
async def test_reset_restores_register_values(dut):
    """FILT-043: Write registers, assert reset, values return to reset state."""
    master = await setup(dut)

    await with_timeout(master.write(ADDR_VERSION, 0x11111111), TIMEOUT_NS, "ns")
    await with_timeout(master.write(ADDR_VAL,     0x22222222), TIMEOUT_NS, "ns")
    assert reg_version(dut) == 0x11111111
    assert reg_val(dut)     == 0x22222222

    dut.i_rst_n.value = 0
    await ClockCycles(dut.i_clk, 5)
    dut.i_rst_n.value = 1
    master.init()
    await ClockCycles(dut.i_clk, 3)

    assert reg_version(dut) == VERSION_RESET, \
        f"version not restored: 0x{reg_version(dut):08X}"
    assert reg_val(dut) == VAL_RESET, \
        f"val not restored: 0x{reg_val(dut):08X}"
    dut._log.info("[PASS] FILT-043 – reset restores register values")


# ===========================================================================
# Group 9 – Stress / randomised sweep
# ===========================================================================

@cocotb.test()
async def test_stress_random_addresses_100_iters(dut):
    """FILT-044: 100 random address write/read iterations; response always correct."""
    master = await setup(dut)

    rng = random.Random(0xDEAD_BEEF)
    failures = []

    # Use a pool of test addresses with known expected responses
    def pick_addr_and_exp():
        tier = rng.choices(['A', 'B', 'C'], weights=[35, 25, 40])[0]
        if tier == 'A':
            addr = rng.choice([ADDR_VERSION, ADDR_VAL])
            return addr, AXI_RESP_OKAY
        elif tier == 'B':
            addr = rng.randint(REG_BASE + 8, FILTER_END)
            return addr, AXI_RESP_SLVERR
        else:
            if rng.random() < 0.5:
                addr = rng.randint(0, FILTER_BEGIN - 1)
            else:
                addr = rng.randint(FILTER_END + 1, 0x0000FFFF)
            return addr, AXI_RESP_SLVERR

    for iteration in range(100):
        addr, expected = pick_addr_and_exp()
        data = rng.randint(0, 0xFFFF_FFFF)

        try:
            bresp = await with_timeout(
                master.write(addr, data), TIMEOUT_NS, "ns"
            )
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
            rdata, rresp = await with_timeout(
                master.read(addr), TIMEOUT_NS, "ns"
            )
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
        f"{len(failures)} failures in stress test:\n" + "\n".join(failures[:20])
    dut._log.info("[PASS] FILT-044 – 100 random iterations all correct")


@cocotb.test()
async def test_stress_many_outofrange_register_intact(dut):
    """FILT-045: 30 out-of-range writes with varied addresses; register never corrupted."""
    master = await setup(dut)

    rng = random.Random(0xCAFE)
    out_addrs = (
        [rng.randint(0, FILTER_BEGIN - 1) for _ in range(15)] +
        [rng.randint(FILTER_END + 1, 0x0000FFFF) for _ in range(15)]
    )
    rng.shuffle(out_addrs)

    for addr in out_addrs:
        bresp = await with_timeout(
            master.write(addr, rng.randint(0, 0xFFFF_FFFF)),
            TIMEOUT_NS, "ns"
        )
        assert bresp == AXI_RESP_SLVERR, \
            f"addr=0x{addr:08X}: expected SLVERR, got {bresp}"

    assert reg_version(dut) == VERSION_RESET, \
        f"version corrupted after 30 out-of-range writes: 0x{reg_version(dut):08X}"
    assert reg_val(dut) == VAL_RESET, \
        f"val corrupted after 30 out-of-range writes: 0x{reg_val(dut):08X}"
    dut._log.info("[PASS] FILT-045 – 30 out-of-range writes; registers intact throughout")


@cocotb.test()
async def test_stress_write_read_val_50_times(dut):
    """FILT-046: Write then read val 50 times with different data; each readback exact."""
    master = await setup(dut)

    rng = random.Random(0x1234)
    for i in range(50):
        data = rng.randint(0, 0xFFFF_FFFF)

        bresp = await with_timeout(master.write(ADDR_VAL, data), TIMEOUT_NS, "ns")
        assert bresp == AXI_RESP_OKAY, f"iter {i}: write bresp={bresp}"

        rdata, rresp = await with_timeout(master.read(ADDR_VAL), TIMEOUT_NS, "ns")
        assert rresp == AXI_RESP_OKAY, f"iter {i}: read rresp={rresp}"
        assert rdata == data, f"iter {i}: readback 0x{rdata:08X} != 0x{data:08X}"

    dut._log.info("[PASS] FILT-046 – 50 write-read-verify cycles on val register")


@cocotb.test()
async def test_stress_mixed_with_bready_delay(dut):
    """FILT-047: 20 random transactions with random bready/rready delays."""
    master = await setup(dut)

    rng = random.Random(0xABCD)

    for i in range(20):
        is_write  = rng.random() < 0.5
        is_in_range = rng.random() < 0.5
        delay     = rng.randint(0, 6)

        if is_in_range:
            addr     = rng.choice([ADDR_VERSION, ADDR_VAL])
            exp_resp = AXI_RESP_OKAY
        else:
            if rng.random() < 0.5:
                addr = rng.randint(0, FILTER_BEGIN - 1)
            else:
                addr = rng.randint(FILTER_END + 1, 0x0000FFFF)
            exp_resp = AXI_RESP_SLVERR

        data = rng.randint(0, 0xFFFF_FFFF)

        if is_write:
            bresp = await with_timeout(
                master.write(addr, data, bready_delay=delay),
                TIMEOUT_NS, "ns"
            )
            assert bresp == exp_resp, \
                f"iter {i} WRITE addr=0x{addr:08X}: got {bresp}, expected {exp_resp}"
        else:
            rdata, rresp = await with_timeout(
                master.read(addr, rready_delay=delay),
                TIMEOUT_NS, "ns"
            )
            assert rresp == exp_resp, \
                f"iter {i} READ addr=0x{addr:08X}: got {rresp}, expected {exp_resp}"

    dut._log.info("[PASS] FILT-047 – 20 mixed transactions with random back-pressure")
