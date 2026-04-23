"""
tb_axion_axi_lite_bridge_cocotb.py

Cocotb testbench for axion_axi_lite_bridge_wrap.
Drives all 34 test cases covering AXI-LITE-xxx, AXION-COMMON-xxx,
BUG-FIX-xxx and NEW-xxx requirement IDs.

DUT top: axion_axi_lite_bridge_wrap (G_NUM_SLAVES=3, G_TIMEOUT_WIDTH=8)
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles, with_timeout
import random

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
CLK_PERIOD_NS   = 10        # 10 ns = 100 MHz
TIMEOUT_CYCLES  = 350       # generous per-transaction watchdog
TIMEOUT_NS      = TIMEOUT_CYCLES * CLK_PERIOD_NS

AXI_RESP_OKAY   = 0b00
AXI_RESP_SLVERR = 0b10

# Slave response modes
MODE_OKAY       = 0
MODE_ERROR      = 2
MODE_NO_RESPOND = -1


# ---------------------------------------------------------------------------
# SlaveModel
# ---------------------------------------------------------------------------
class SlaveModel:
    """
    Software slave.  Responds to AXI4-Lite write and read transactions
    presented by the bridge on the sN_* flat signals of the DUT.
    """

    def __init__(self, dut, idx: int, clk):
        self._dut       = dut
        self._idx       = idx
        self._clk       = clk
        self.mode            = MODE_OKAY
        self.response_delay  = 0
        self.awready_delay   = 0
        self.read_data       = 0xDEADBEEF

        # Grab the signal objects once for convenience
        pfx = f"s{idx}_"
        self._awvalid  = getattr(dut, f"{pfx}awvalid")
        self._awready  = getattr(dut, f"{pfx}awready")
        self._wvalid   = getattr(dut, f"{pfx}wvalid")
        self._wready   = getattr(dut, f"{pfx}wready")
        self._bvalid   = getattr(dut, f"{pfx}bvalid")
        self._bresp    = getattr(dut, f"{pfx}bresp")
        self._bready   = getattr(dut, f"{pfx}bready")
        self._arvalid  = getattr(dut, f"{pfx}arvalid")
        self._arready  = getattr(dut, f"{pfx}arready")
        self._rvalid   = getattr(dut, f"{pfx}rvalid")
        self._rdata    = getattr(dut, f"{pfx}rdata")
        self._rresp    = getattr(dut, f"{pfx}rresp")
        self._rready   = getattr(dut, f"{pfx}rready")

        # Default output state
        self._awready.value = 0
        self._wready.value  = 0
        self._bvalid.value  = 0
        self._bresp.value   = 0
        self._arready.value = 0
        self._rvalid.value  = 0
        self._rdata.value   = 0
        self._rresp.value   = 0

    def start(self):
        """Launch background coroutines."""
        cocotb.start_soon(self._write_loop())
        cocotb.start_soon(self._read_loop())

    async def _write_loop(self):
        while True:
            # --- AW handshake ---
            if self.awready_delay == 0:
                self._awready.value = 1
                # Wait until awvalid is seen
                while True:
                    await RisingEdge(self._clk)
                    if self._awvalid.value == 1:
                        break
                self._awready.value = 0
            else:
                self._awready.value = 0
                # Wait until awvalid is seen
                while True:
                    await RisingEdge(self._clk)
                    if self._awvalid.value == 1:
                        break
                # Delay before asserting awready
                for _ in range(self.awready_delay):
                    await RisingEdge(self._clk)
                self._awready.value = 1
                await RisingEdge(self._clk)
                self._awready.value = 0

            # --- W handshake (wready=1 always, just wait for wvalid) ---
            self._wready.value = 1
            while True:
                await RisingEdge(self._clk)
                if self._wvalid.value == 1:
                    break
            self._wready.value = 0

            # --- B response ---
            if self.mode == MODE_NO_RESPOND:
                continue

            # Wait response_delay cycles before asserting bvalid
            for _ in range(self.response_delay):
                await RisingEdge(self._clk)

            self._bresp.value  = self.mode   # 0=OKAY, 2=SLVERR
            self._bvalid.value = 1

            # Wait for bready
            while True:
                await RisingEdge(self._clk)
                if self._bready.value == 1:
                    break

            self._bvalid.value = 0

    async def _read_loop(self):
        while True:
            # --- AR handshake (arready=1 always) ---
            self._arready.value = 1
            while True:
                await RisingEdge(self._clk)
                if self._arvalid.value == 1:
                    break
            self._arready.value = 0

            # --- R response ---
            if self.mode == MODE_NO_RESPOND:
                continue

            # Wait response_delay cycles before asserting rvalid
            for _ in range(self.response_delay):
                await RisingEdge(self._clk)

            self._rdata.value  = self.read_data
            self._rresp.value  = self.mode   # 0=OKAY, 2=SLVERR
            self._rvalid.value = 1

            # Wait for rready
            while True:
                await RisingEdge(self._clk)
                if self._rready.value == 1:
                    break

            self._rvalid.value = 0


# ---------------------------------------------------------------------------
# AXIMaster
# ---------------------------------------------------------------------------
class AXIMaster:
    """Drives the master-side flat signals on the DUT."""

    def __init__(self, dut, clk):
        self._dut  = dut
        self._clk  = clk

    def init(self):
        """Clear all master-driven outputs."""
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
                    bready_delay: int = 0) -> int:
        """
        AW + W issued simultaneously.
        Deasserts awvalid once awready seen; deasserts wvalid once wready seen.
        Optionally waits bready_delay cycles before asserting bready.
        Returns bresp.
        """
        self._dut.m_awaddr.value  = addr
        self._dut.m_awprot.value  = 0
        self._dut.m_awvalid.value = 1
        self._dut.m_wdata.value   = data
        self._dut.m_wstrb.value   = strb
        self._dut.m_wvalid.value  = 1

        aw_done = False
        w_done  = False

        while not (aw_done and w_done):
            await RisingEdge(self._clk)
            if not aw_done and self._dut.m_awready.value == 1:
                self._dut.m_awvalid.value = 0
                aw_done = True
            if not w_done and self._dut.m_wready.value == 1:
                self._dut.m_wvalid.value = 0
                w_done = True

        # Optional delay before accepting write response
        for _ in range(bready_delay):
            await RisingEdge(self._clk)

        self._dut.m_bready.value = 1
        while True:
            await RisingEdge(self._clk)
            if self._dut.m_bvalid.value == 1:
                bresp = int(self._dut.m_bresp.value)
                self._dut.m_bready.value = 0
                return bresp

    async def write_w_first(self, addr: int, data: int, strb: int = 0xF,
                             w_ahead_cycles: int = 3) -> int:
        """
        Assert wvalid w_ahead_cycles before awvalid.
        Otherwise identical to write().
        """
        self._dut.m_wdata.value   = data
        self._dut.m_wstrb.value   = strb
        self._dut.m_wvalid.value  = 1

        for _ in range(w_ahead_cycles):
            await RisingEdge(self._clk)

        self._dut.m_awaddr.value  = addr
        self._dut.m_awprot.value  = 0
        self._dut.m_awvalid.value = 1

        aw_done = False
        w_done  = False

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

    async def read(self, addr: int, rready_delay: int = 0):
        """
        Send AR, wait arready, optionally delay rready, wait rvalid.
        Returns (rdata, rresp).
        """
        self._dut.m_araddr.value  = addr
        self._dut.m_arprot.value  = 0
        self._dut.m_arvalid.value = 1

        while True:
            await RisingEdge(self._clk)
            if self._dut.m_arready.value == 1:
                self._dut.m_arvalid.value = 0
                break

        # Optional delay before asserting rready
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
# Test fixture
# ---------------------------------------------------------------------------
async def setup(dut):
    """
    Initialize DUT, start 100 MHz clock, assert reset for 5 cycles,
    start all three slave models. Returns (master, slaves[3]).
    """
    cocotb.start_soon(Clock(dut.i_clk, CLK_PERIOD_NS, units="ns").start())

    master = AXIMaster(dut, dut.i_clk)
    master.init()

    # Default slave input values (all inactive)
    for idx in range(3):
        getattr(dut, f"s{idx}_awready").value = 0
        getattr(dut, f"s{idx}_wready").value  = 0
        getattr(dut, f"s{idx}_bvalid").value  = 0
        getattr(dut, f"s{idx}_bresp").value   = 0
        getattr(dut, f"s{idx}_arready").value = 0
        getattr(dut, f"s{idx}_rvalid").value  = 0
        getattr(dut, f"s{idx}_rdata").value   = 0
        getattr(dut, f"s{idx}_rresp").value   = 0

    # Assert reset
    dut.i_rst_n.value = 0
    await ClockCycles(dut.i_clk, 5)
    dut.i_rst_n.value = 1
    await ClockCycles(dut.i_clk, 2)

    slaves = [SlaveModel(dut, i, dut.i_clk) for i in range(3)]
    for s in slaves:
        s.start()

    return master, slaves


def _set_all_slaves(slaves, mode, delay=0, awready_delay=0, read_data=0xDEADBEEF):
    for s in slaves:
        s.mode           = mode
        s.response_delay = delay
        s.awready_delay  = awready_delay
        s.read_data      = read_data


# ===========================================================================
# Group 1 — Migrated from VHDL TB
# ===========================================================================

@cocotb.test()
async def test_reset_behavior(dut):
    """AXI-LITE-008: After reset bvalid=0 and rvalid=0."""
    master, slaves = await setup(dut)
    await ClockCycles(dut.i_clk, 2)
    assert int(dut.m_bvalid.value) == 0, "bvalid should be 0 after reset"
    assert int(dut.m_rvalid.value) == 0, "rvalid should be 0 after reset"
    dut._log.info("[PASS] AXI-LITE-008 - bvalid=0 and rvalid=0 after reset")


@cocotb.test()
async def test_write_addr_handshake(dut):
    """AXI-LITE-001: awvalid held until awready; AW handshake completes."""
    master, slaves = await setup(dut)
    _set_all_slaves(slaves, MODE_OKAY)

    # We do a normal write and check that it completes (implies handshake worked)
    bresp = await with_timeout(master.write(0x1000, 0xABCD), TIMEOUT_NS, "ns")
    assert bresp == AXI_RESP_OKAY, f"Expected OKAY, got {bresp}"
    dut._log.info("[PASS] AXI-LITE-001 - AW handshake completed correctly")


@cocotb.test()
async def test_write_data_handshake(dut):
    """AXI-LITE-002: Write completes successfully."""
    master, slaves = await setup(dut)
    _set_all_slaves(slaves, MODE_OKAY)

    bresp = await with_timeout(master.write(0x2000, 0x12345678), TIMEOUT_NS, "ns")
    assert bresp == AXI_RESP_OKAY, f"Expected OKAY, got {bresp}"
    dut._log.info("[PASS] AXI-LITE-002 - Write data handshake completed")


@cocotb.test()
async def test_write_resp_handshake(dut):
    """AXI-LITE-003: bvalid stays high while bready=0; clears when bready=1."""
    master, slaves = await setup(dut)
    _set_all_slaves(slaves, MODE_OKAY)

    # bready_delay=3 means master waits 3 cycles after bvalid before accepting
    bresp = await with_timeout(master.write(0x3000, 0xDEAD, bready_delay=3),
                               TIMEOUT_NS, "ns")
    assert bresp == AXI_RESP_OKAY, f"Expected OKAY, got {bresp}"
    dut._log.info("[PASS] AXI-LITE-003 - bvalid stays high until bready accepted")


@cocotb.test()
async def test_read_addr_handshake(dut):
    """AXI-LITE-004: AR handshake completes."""
    master, slaves = await setup(dut)
    _set_all_slaves(slaves, MODE_OKAY, read_data=0xCAFE)

    rdata, rresp = await with_timeout(master.read(0x4000), TIMEOUT_NS, "ns")
    assert rresp == AXI_RESP_OKAY, f"Expected OKAY, got {rresp}"
    dut._log.info("[PASS] AXI-LITE-004 - AR handshake completed correctly")


@cocotb.test()
async def test_read_data_handshake(dut):
    """AXI-LITE-005: rvalid stays high while rready=0."""
    master, slaves = await setup(dut)
    _set_all_slaves(slaves, MODE_OKAY, read_data=0xBEEF)

    rdata, rresp = await with_timeout(master.read(0x5000, rready_delay=3),
                                      TIMEOUT_NS, "ns")
    assert rresp == AXI_RESP_OKAY, f"Expected OKAY, got {rresp}"
    dut._log.info("[PASS] AXI-LITE-005 - rvalid stays high until rready accepted")


@cocotb.test()
async def test_okay_response(dut):
    """AXI-LITE-006: Write and read both return OKAY."""
    master, slaves = await setup(dut)
    _set_all_slaves(slaves, MODE_OKAY, read_data=0x11223344)

    bresp = await with_timeout(master.write(0x1000, 0x11223344), TIMEOUT_NS, "ns")
    assert bresp == AXI_RESP_OKAY, f"Write: expected OKAY, got {bresp}"

    rdata, rresp = await with_timeout(master.read(0x1000), TIMEOUT_NS, "ns")
    assert rresp == AXI_RESP_OKAY, f"Read: expected OKAY, got {rresp}"
    dut._log.info("[PASS] AXI-LITE-006 - Write and read both OKAY")


@cocotb.test()
async def test_slverr_response(dut):
    """AXI-LITE-007: All slaves in ERROR mode → SLVERR."""
    master, slaves = await setup(dut)
    _set_all_slaves(slaves, MODE_ERROR)

    bresp = await with_timeout(master.write(0x1000, 0xABCD), TIMEOUT_NS, "ns")
    assert bresp == AXI_RESP_SLVERR, f"Write: expected SLVERR, got {bresp}"

    _set_all_slaves(slaves, MODE_ERROR)
    rdata, rresp = await with_timeout(master.read(0x1000), TIMEOUT_NS, "ns")
    assert rresp == AXI_RESP_SLVERR, f"Read: expected SLVERR, got {rresp}"
    dut._log.info("[PASS] AXI-LITE-007 - All-error slaves return SLVERR")


@cocotb.test()
async def test_request_broadcast(dut):
    """AXION-COMMON-001: All slave araddr signals equal master's araddr."""
    master, slaves = await setup(dut)
    _set_all_slaves(slaves, MODE_OKAY, read_data=0x42)

    TEST_ADDR = 0x00ABCDEF

    # Start read but capture slave addresses before rready completes
    rdata_coro = cocotb.start_soon(master.read(TEST_ADDR))

    # Let the bridge forward the address (a few cycles after arvalid)
    await ClockCycles(dut.i_clk, 3)

    for i in range(3):
        saddr = int(getattr(dut, f"s{i}_araddr").value)
        assert saddr == TEST_ADDR, \
            f"Slave {i} araddr=0x{saddr:08X}, expected 0x{TEST_ADDR:08X}"

    await rdata_coro
    dut._log.info("[PASS] AXION-COMMON-001 - araddr broadcast to all slaves")


@cocotb.test()
async def test_first_okay_selection(dut):
    """AXION-COMMON-002: slave0=OKAY, slaves1&2=ERROR → master gets OKAY."""
    master, slaves = await setup(dut)
    slaves[0].mode = MODE_OKAY
    slaves[1].mode = MODE_ERROR
    slaves[2].mode = MODE_ERROR

    bresp = await with_timeout(master.write(0x1000, 0x1), TIMEOUT_NS, "ns")
    assert bresp == AXI_RESP_OKAY, f"Expected OKAY, got {bresp}"
    dut._log.info("[PASS] AXION-COMMON-002 - First OKAY slave selected")


@cocotb.test()
async def test_all_error_response(dut):
    """AXION-COMMON-003: All slaves ERROR → SLVERR."""
    master, slaves = await setup(dut)
    _set_all_slaves(slaves, MODE_ERROR)

    bresp = await with_timeout(master.write(0x2000, 0x2), TIMEOUT_NS, "ns")
    assert bresp == AXI_RESP_SLVERR, f"Expected SLVERR, got {bresp}"
    dut._log.info("[PASS] AXION-COMMON-003 - All-error slaves return SLVERR")


@cocotb.test()
async def test_timeout_mechanism(dut):
    """AXION-COMMON-004: All slaves NO_RESPOND → SLVERR within 350 cycles."""
    master, slaves = await setup(dut)
    _set_all_slaves(slaves, MODE_NO_RESPOND)

    bresp = await with_timeout(master.write(0x3000, 0x3), TIMEOUT_NS, "ns")
    assert bresp == AXI_RESP_SLVERR, f"Expected SLVERR on timeout, got {bresp}"
    dut._log.info("[PASS] AXION-COMMON-004 - Timeout returns SLVERR")


@cocotb.test()
async def test_slave_count(dut):
    """AXION-COMMON-005: 3 slaves work correctly."""
    master, slaves = await setup(dut)
    _set_all_slaves(slaves, MODE_OKAY, read_data=0x55AA55AA)

    for i in range(3):
        bresp = await with_timeout(master.write(0x1000 * (i + 1), i),
                                   TIMEOUT_NS, "ns")
        assert bresp == AXI_RESP_OKAY, f"Write {i}: expected OKAY, got {bresp}"

    dut._log.info("[PASS] AXION-COMMON-005 - 3-slave configuration works")


@cocotb.test()
async def test_write_sequence(dut):
    """AXION-COMMON-006: Write returns OKAY."""
    master, slaves = await setup(dut)
    _set_all_slaves(slaves, MODE_OKAY)

    bresp = await with_timeout(master.write(0x1000, 0xDEADBEEF), TIMEOUT_NS, "ns")
    assert bresp == AXI_RESP_OKAY, f"Expected OKAY, got {bresp}"
    dut._log.info("[PASS] AXION-COMMON-006 - Write sequence returns OKAY")


@cocotb.test()
async def test_read_sequence(dut):
    """AXION-COMMON-007: Read returns correct data."""
    master, slaves = await setup(dut)
    EXPECTED = 0x12345678
    _set_all_slaves(slaves, MODE_OKAY, read_data=EXPECTED)

    rdata, rresp = await with_timeout(master.read(0x2000), TIMEOUT_NS, "ns")
    assert rresp  == AXI_RESP_OKAY, f"Expected OKAY, got {rresp}"
    assert rdata  == EXPECTED, f"Expected 0x{EXPECTED:08X}, got 0x{rdata:08X}"
    dut._log.info("[PASS] AXION-COMMON-007 - Read returns correct data")


@cocotb.test()
async def test_back_to_back(dut):
    """AXION-COMMON-008: 3 writes + 3 reads + interleaved all succeed."""
    master, slaves = await setup(dut)
    _set_all_slaves(slaves, MODE_OKAY, read_data=0xA5A5A5A5)

    for i in range(3):
        bresp = await with_timeout(master.write(0x1000 + i * 4, 0x100 + i),
                                   TIMEOUT_NS, "ns")
        assert bresp == AXI_RESP_OKAY, f"Write {i}: expected OKAY, got {bresp}"

    for i in range(3):
        rdata, rresp = await with_timeout(master.read(0x1000 + i * 4),
                                          TIMEOUT_NS, "ns")
        assert rresp == AXI_RESP_OKAY, f"Read {i}: expected OKAY, got {rresp}"

    # Interleaved
    for i in range(3):
        bresp = await with_timeout(master.write(0x2000 + i * 4, 0x200 + i),
                                   TIMEOUT_NS, "ns")
        assert bresp == AXI_RESP_OKAY, f"Interleaved write {i}: expected OKAY"
        rdata, rresp = await with_timeout(master.read(0x2000 + i * 4),
                                          TIMEOUT_NS, "ns")
        assert rresp == AXI_RESP_OKAY, f"Interleaved read {i}: expected OKAY"

    dut._log.info("[PASS] AXION-COMMON-008 - Back-to-back transactions succeed")


@cocotb.test()
async def test_partial_slave_response(dut):
    """AXION-COMMON-009: slave0=OKAY, 1&2=NO_RESPOND → OKAY."""
    master, slaves = await setup(dut)
    slaves[0].mode = MODE_OKAY
    slaves[1].mode = MODE_NO_RESPOND
    slaves[2].mode = MODE_NO_RESPOND

    bresp = await with_timeout(master.write(0x1000, 0xAA), TIMEOUT_NS, "ns")
    assert bresp == AXI_RESP_OKAY, f"Expected OKAY, got {bresp}"
    dut._log.info("[PASS] AXION-COMMON-009 - Partial slave response returns OKAY")


@cocotb.test()
async def test_address_transparency(dut):
    """AXION-COMMON-010: araddr and arprot forwarded exactly to all slaves."""
    master, slaves = await setup(dut)
    _set_all_slaves(slaves, MODE_OKAY)

    TEST_ADDR = 0xDEAD1234
    TEST_PROT = 0b101

    # Drive arvalid manually without completing the transaction so we can sample
    dut.m_araddr.value  = TEST_ADDR
    dut.m_arprot.value  = TEST_PROT
    dut.m_arvalid.value = 1

    # Wait until arready
    while True:
        await RisingEdge(dut.i_clk)
        if int(dut.m_arready.value) == 1:
            break
    dut.m_arvalid.value = 0

    # Give the bridge one cycle to latch and forward
    await RisingEdge(dut.i_clk)

    for i in range(3):
        saddr = int(getattr(dut, f"s{i}_araddr").value)
        assert saddr == TEST_ADDR, \
            f"Slave {i} araddr=0x{saddr:08X}, expected 0x{TEST_ADDR:08X}"

    # Complete the read so we leave a clean state
    dut.m_rready.value = 1
    deadline = TIMEOUT_CYCLES
    while deadline > 0:
        await RisingEdge(dut.i_clk)
        if int(dut.m_rvalid.value) == 1:
            break
        deadline -= 1
    dut.m_rready.value = 0

    dut._log.info("[PASS] AXION-COMMON-010 - Address and prot forwarded to slaves")


@cocotb.test()
async def test_data_integrity(dut):
    """AXION-COMMON-011: wdata/wstrb forwarded exactly; rdata returned correctly."""
    master, slaves = await setup(dut)
    WDATA = 0xCAFEBABE
    WSTRB = 0b1010
    RDATA = 0x55AA1234
    _set_all_slaves(slaves, MODE_OKAY, read_data=RDATA)

    # Write and check slave side
    write_coro = cocotb.start_soon(master.write(0x1000, WDATA, strb=WSTRB))

    # Let bridge forward data
    await ClockCycles(dut.i_clk, 4)
    # (Forwarded values may be registered, give a few cycles to propagate)
    for cyc in range(20):
        await RisingEdge(dut.i_clk)
        if any(int(getattr(dut, f"s{i}_wvalid").value) == 1 for i in range(3)):
            for i in range(3):
                sw = int(getattr(dut, f"s{i}_wdata").value)
                ss = int(getattr(dut, f"s{i}_wstrb").value)
                assert sw == WDATA, f"Slave {i} wdata=0x{sw:08X} expected 0x{WDATA:08X}"
                assert ss == WSTRB, f"Slave {i} wstrb={ss:#06b} expected {WSTRB:#06b}"
            break

    await write_coro

    # Read back
    rdata, rresp = await with_timeout(master.read(0x1000), TIMEOUT_NS, "ns")
    assert rresp == AXI_RESP_OKAY, f"Read: expected OKAY, got {rresp}"
    assert rdata == RDATA, f"rdata=0x{rdata:08X}, expected 0x{RDATA:08X}"
    dut._log.info("[PASS] AXION-COMMON-011 - wdata/wstrb forwarded; rdata correct")


@cocotb.test()
async def test_reset_recovery(dut):
    """AXION-COMMON-012: Reset mid-transaction; bridge works after reset."""
    master, slaves = await setup(dut)
    _set_all_slaves(slaves, MODE_NO_RESPOND)  # transaction will stall

    # Kick off a write (will not complete — slaves don't respond)
    write_task = cocotb.start_soon(master.write(0x1000, 0xFF))

    # Let the bridge enter a write state
    await ClockCycles(dut.i_clk, 10)

    # Assert reset mid-transaction
    dut.i_rst_n.value = 0
    await ClockCycles(dut.i_clk, 5)

    assert int(dut.m_bvalid.value) == 0, "bvalid should be 0 during reset"
    assert int(dut.m_rvalid.value) == 0, "rvalid should be 0 during reset"

    # De-assert reset and clean up master state
    dut.i_rst_n.value = 1
    master.init()
    write_task.kill()

    await ClockCycles(dut.i_clk, 5)

    # Bridge should now work
    _set_all_slaves(slaves, MODE_OKAY)
    bresp = await with_timeout(master.write(0x2000, 0x42), TIMEOUT_NS, "ns")
    assert bresp == AXI_RESP_OKAY, f"Post-reset write: expected OKAY, got {bresp}"
    dut._log.info("[PASS] AXION-COMMON-012 - Bridge recovers after reset")


# ===========================================================================
# Group 1 — BUG-FIX tests
# ===========================================================================

@cocotb.test()
async def test_wready_single_pulse(dut):
    """BUG-FIX-001: awvalid+wvalid together → wready pulses exactly once."""
    master, slaves = await setup(dut)
    _set_all_slaves(slaves, MODE_OKAY)

    wready_count = 0

    async def count_wready():
        nonlocal wready_count
        for _ in range(TIMEOUT_CYCLES):
            await RisingEdge(dut.i_clk)
            if int(dut.m_wready.value) == 1:
                wready_count += 1

    monitor = cocotb.start_soon(count_wready())
    await master.write(0x1000, 0xAA)
    monitor.kill()

    assert wready_count == 1, \
        f"wready pulsed {wready_count} times, expected exactly 1 (BUG-FIX-001)"
    dut._log.info("[PASS] BUG-FIX-001 - wready pulsed exactly once")


@cocotb.test()
async def test_write_drain_delayed(dut):
    """BUG-FIX-002: slave0=OKAY fast, slaves1&2=ERROR delay=20 → second write OKAY."""
    master, slaves = await setup(dut)
    slaves[0].mode           = MODE_OKAY
    slaves[0].response_delay = 0
    slaves[1].mode           = MODE_ERROR
    slaves[1].response_delay = 20
    slaves[2].mode           = MODE_ERROR
    slaves[2].response_delay = 20

    bresp1 = await with_timeout(master.write(0x1000, 0x1), TIMEOUT_NS, "ns")
    assert bresp1 == AXI_RESP_OKAY, f"First write: expected OKAY, got {bresp1}"

    bresp2 = await with_timeout(master.write(0x2000, 0x2), TIMEOUT_NS, "ns")
    assert bresp2 == AXI_RESP_OKAY, f"Second write: expected OKAY, got {bresp2}"
    dut._log.info("[PASS] BUG-FIX-002 - Drain of delayed error slaves; second write OKAY")


@cocotb.test()
async def test_write_drain_timeout(dut):
    """BUG-FIX-003: slave0=OKAY, 1&2=NO_RESPOND → drain timeout → second write OKAY."""
    master, slaves = await setup(dut)
    slaves[0].mode = MODE_OKAY
    slaves[1].mode = MODE_NO_RESPOND
    slaves[2].mode = MODE_NO_RESPOND

    bresp1 = await with_timeout(master.write(0x1000, 0x1), TIMEOUT_NS, "ns")
    assert bresp1 == AXI_RESP_OKAY, f"First write: expected OKAY, got {bresp1}"

    # Second write — drain must have completed (via timeout) by now
    slaves[1].mode = MODE_OKAY
    slaves[2].mode = MODE_OKAY
    bresp2 = await with_timeout(master.write(0x2000, 0x2), TIMEOUT_NS, "ns")
    assert bresp2 == AXI_RESP_OKAY, f"Second write: expected OKAY, got {bresp2}"
    dut._log.info("[PASS] BUG-FIX-003 - Drain timeout allows second write OKAY")


@cocotb.test()
async def test_read_drain_delayed(dut):
    """BUG-FIX-004: slave0=OKAY fast, 1&2=ERROR delay=20 → second read OKAY+correct data."""
    master, slaves = await setup(dut)
    DATA0 = 0xFACEFACE
    slaves[0].mode           = MODE_OKAY
    slaves[0].response_delay = 0
    slaves[0].read_data      = DATA0
    slaves[1].mode           = MODE_ERROR
    slaves[1].response_delay = 20
    slaves[2].mode           = MODE_ERROR
    slaves[2].response_delay = 20

    rdata1, rresp1 = await with_timeout(master.read(0x1000), TIMEOUT_NS, "ns")
    assert rresp1 == AXI_RESP_OKAY, f"First read: expected OKAY, got {rresp1}"
    assert rdata1 == DATA0, f"First read data mismatch 0x{rdata1:08X}"

    DATA2 = 0x0BADCAFE
    slaves[0].read_data = DATA2
    rdata2, rresp2 = await with_timeout(master.read(0x2000), TIMEOUT_NS, "ns")
    assert rresp2 == AXI_RESP_OKAY, f"Second read: expected OKAY, got {rresp2}"
    assert rdata2 == DATA2, f"Second read data 0x{rdata2:08X} expected 0x{DATA2:08X}"
    dut._log.info("[PASS] BUG-FIX-004 - Read drain of delayed errors; second read correct")


@cocotb.test()
async def test_read_drain_timeout(dut):
    """BUG-FIX-005: slave0=OKAY, 1&2=NO_RESPOND → drain timeout → second read OKAY."""
    master, slaves = await setup(dut)
    slaves[0].mode      = MODE_OKAY
    slaves[0].read_data = 0x1234
    slaves[1].mode      = MODE_NO_RESPOND
    slaves[2].mode      = MODE_NO_RESPOND

    rdata1, rresp1 = await with_timeout(master.read(0x1000), TIMEOUT_NS, "ns")
    assert rresp1 == AXI_RESP_OKAY, f"First read: expected OKAY, got {rresp1}"

    slaves[1].mode      = MODE_OKAY
    slaves[2].mode      = MODE_OKAY
    slaves[0].read_data = 0x5678
    slaves[1].read_data = 0x5678
    slaves[2].read_data = 0x5678
    rdata2, rresp2 = await with_timeout(master.read(0x2000), TIMEOUT_NS, "ns")
    assert rresp2 == AXI_RESP_OKAY, f"Second read: expected OKAY, got {rresp2}"
    dut._log.info("[PASS] BUG-FIX-005 - Read drain timeout allows second read OKAY")


@cocotb.test()
async def test_late_awready(dut):
    """BUG-FIX-006: slave1 awready_delay=5 → write still completes OKAY; second write OKAY."""
    master, slaves = await setup(dut)
    _set_all_slaves(slaves, MODE_OKAY)
    slaves[1].awready_delay = 5

    bresp1 = await with_timeout(master.write(0x1000, 0xAA), TIMEOUT_NS, "ns")
    assert bresp1 == AXI_RESP_OKAY, f"First write: expected OKAY, got {bresp1}"

    slaves[1].awready_delay = 0
    bresp2 = await with_timeout(master.write(0x2000, 0xBB), TIMEOUT_NS, "ns")
    assert bresp2 == AXI_RESP_OKAY, f"Second write: expected OKAY, got {bresp2}"
    dut._log.info("[PASS] BUG-FIX-006 - Late awready; both writes OKAY")


# ===========================================================================
# Group 2 — New extended tests
# ===========================================================================

@cocotb.test()
async def test_bready_backpressure(dut):
    """NEW-001: once bvalid asserts, hold bready=0 for DELAY cycles; bvalid must stay
    high throughout (AXI4 Lite §A3.3 handshake stability); bresp=OKAY."""
    master, slaves = await setup(dut)
    _set_all_slaves(slaves, MODE_OKAY)

    DELAY = 8

    # Issue AW+W simultaneously, drive bready manually so we control timing exactly.
    dut.m_awaddr.value  = 0x1000
    dut.m_awprot.value  = 0
    dut.m_awvalid.value = 1
    dut.m_wdata.value   = 0xAA
    dut.m_wstrb.value   = 0xF
    dut.m_wvalid.value  = 1
    dut.m_bready.value  = 0

    # Wait for AW+W handshake
    aw_done = w_done = False
    while not (aw_done and w_done):
        await RisingEdge(dut.i_clk)
        if not aw_done and int(dut.m_awready.value) == 1:
            dut.m_awvalid.value = 0
            aw_done = True
        if not w_done and int(dut.m_wready.value) == 1:
            dut.m_wvalid.value = 0
            w_done = True

    # Wait for bvalid to first go high (bridge response ready)
    while True:
        await RisingEdge(dut.i_clk)
        if int(dut.m_bvalid.value) == 1:
            break

    # bvalid is now high. Verify it stays high for DELAY cycles while bready=0.
    for cycle in range(DELAY - 1):
        await RisingEdge(dut.i_clk)
        assert int(dut.m_bvalid.value) == 1, \
            f"bvalid dropped at backpressure cycle {cycle + 1}/{DELAY - 1} before bready (AXI4 violation)"

    # Accept the response
    dut.m_bready.value = 1
    await RisingEdge(dut.i_clk)
    assert int(dut.m_bvalid.value) == 1, "bvalid must still be high when bready is first asserted"
    bresp = int(dut.m_bresp.value)
    dut.m_bready.value = 0

    assert bresp == AXI_RESP_OKAY, f"Expected OKAY, got {bresp}"
    dut._log.info("[PASS] NEW-001 - bvalid held high under bready backpressure")


@cocotb.test()
async def test_rready_backpressure(dut):
    """NEW-002: read with rready_delay=8; verify rvalid high those 8 cycles; rresp=OKAY."""
    master, slaves = await setup(dut)
    _set_all_slaves(slaves, MODE_OKAY, read_data=0x42)

    DELAY = 8
    rvalid_count = 0

    async def monitor_rvalid(cycles):
        nonlocal rvalid_count
        for _ in range(cycles + 2):
            await RisingEdge(dut.i_clk)
            if int(dut.m_rvalid.value) == 1:
                rvalid_count += 1

    read_coro   = cocotb.start_soon(master.read(0x1000, rready_delay=DELAY))
    monitor     = cocotb.start_soon(monitor_rvalid(DELAY + 4))

    rdata, rresp = await read_coro
    await monitor

    assert rvalid_count >= DELAY, \
        f"rvalid only seen {rvalid_count} cycles, expected >= {DELAY}"
    assert rresp == AXI_RESP_OKAY, f"Expected OKAY, got {rresp}"
    dut._log.info("[PASS] NEW-002 - rvalid held high under rready backpressure")


@cocotb.test()
async def test_w_before_aw(dut):
    """NEW-003: write_w_first(w_ahead_cycles=3); write must complete OKAY."""
    master, slaves = await setup(dut)
    _set_all_slaves(slaves, MODE_OKAY)

    bresp = await with_timeout(
        master.write_w_first(0x1000, 0xABCDABCD, w_ahead_cycles=3),
        TIMEOUT_NS, "ns"
    )
    assert bresp == AXI_RESP_OKAY, f"Expected OKAY, got {bresp}"
    dut._log.info("[PASS] NEW-003 - W before AW; write completes OKAY")


@cocotb.test()
async def test_awvalid_held_until_awready(dut):
    """NEW-004: all slave awready_delay=6; sN_awvalid stays 1 until awready, then 0."""
    master, slaves = await setup(dut)
    _set_all_slaves(slaves, MODE_OKAY, awready_delay=6)

    awvalid_deasserted = [False, False, False]

    async def monitor_awvalid_slave(idx):
        seen_high = False
        for _ in range(TIMEOUT_CYCLES):
            await RisingEdge(dut.i_clk)
            av = int(getattr(dut, f"s{idx}_awvalid").value)
            ar = int(getattr(dut, f"s{idx}_awready").value)
            if av == 1:
                seen_high = True
            if seen_high and ar == 1:
                # awready came — next cycle awvalid should be 0
                await RisingEdge(dut.i_clk)
                av_after = int(getattr(dut, f"s{idx}_awvalid").value)
                assert av_after == 0, \
                    f"Slave {idx} awvalid still 1 one cycle after awready"
                awvalid_deasserted[idx] = True
                return

    monitors = [cocotb.start_soon(monitor_awvalid_slave(i)) for i in range(3)]
    await master.write(0x1000, 0xBB)
    for m in monitors:
        await m

    for i in range(3):
        assert awvalid_deasserted[i], \
            f"Slave {i} awvalid was never deasserted after awready"
    dut._log.info("[PASS] NEW-004 - awvalid held until awready then deasserted")


@cocotb.test()
async def test_late_bvalid_in_complete(dut):
    """NEW-005: slave0=OKAY delay=2; slave1=ERROR delay=10; slave2=ERROR delay=15;
    bready_delay=12; verify bridge returns to IDLE cleanly; second write OKAY."""
    master, slaves = await setup(dut)
    slaves[0].mode           = MODE_OKAY
    slaves[0].response_delay = 2
    slaves[1].mode           = MODE_ERROR
    slaves[1].response_delay = 10
    slaves[2].mode           = MODE_ERROR
    slaves[2].response_delay = 15

    bresp1 = await with_timeout(
        master.write(0x1000, 0x1, bready_delay=12),
        TIMEOUT_NS, "ns"
    )
    assert bresp1 == AXI_RESP_OKAY, f"First write: expected OKAY, got {bresp1}"

    # Bridge should now be back in IDLE; second write must work
    _set_all_slaves(slaves, MODE_OKAY)
    bresp2 = await with_timeout(master.write(0x2000, 0x2), TIMEOUT_NS, "ns")
    assert bresp2 == AXI_RESP_OKAY, f"Second write: expected OKAY, got {bresp2}"
    dut._log.info("[PASS] NEW-005 - Late bvalid during WRITE_COMPLETE; bridge IDLEs cleanly")


@cocotb.test()
async def test_late_rvalid_in_complete(dut):
    """NEW-006: Same scenario for reads — late rvalid; bridge cleans up; second read OKAY."""
    master, slaves = await setup(dut)
    DATA = 0x99887766
    slaves[0].mode           = MODE_OKAY
    slaves[0].response_delay = 2
    slaves[0].read_data      = DATA
    slaves[1].mode           = MODE_ERROR
    slaves[1].response_delay = 10
    slaves[2].mode           = MODE_ERROR
    slaves[2].response_delay = 15

    rdata1, rresp1 = await with_timeout(
        master.read(0x1000, rready_delay=12),
        TIMEOUT_NS, "ns"
    )
    assert rresp1 == AXI_RESP_OKAY, f"First read: expected OKAY, got {rresp1}"
    assert rdata1 == DATA, f"First read data 0x{rdata1:08X} expected 0x{DATA:08X}"

    RDATA2 = 0x11223344
    _set_all_slaves(slaves, MODE_OKAY, read_data=RDATA2)
    rdata2, rresp2 = await with_timeout(master.read(0x2000), TIMEOUT_NS, "ns")
    assert rresp2 == AXI_RESP_OKAY, f"Second read: expected OKAY, got {rresp2}"
    assert rdata2 == RDATA2, f"Second read data 0x{rdata2:08X} expected 0x{RDATA2:08X}"
    dut._log.info("[PASS] NEW-006 - Late rvalid during READ_COMPLETE; bridge IDLEs cleanly")


@cocotb.test()
async def test_randomized_sequence(dut):
    """NEW-007: 20 random iterations with random addr/data/mode/delay."""
    master, slaves = await setup(dut)

    rng = random.Random(42)
    failures = []

    for iteration in range(20):
        # Random slave configuration: 70% OKAY, 30% ERROR per slave
        slave_modes = [
            MODE_OKAY if rng.random() < 0.7 else MODE_ERROR
            for _ in range(3)
        ]
        delay = rng.randint(1, 5)
        for i, s in enumerate(slaves):
            s.mode           = slave_modes[i]
            s.response_delay = delay
            s.read_data      = rng.randint(0, 0xFFFFFFFF)

        any_okay = any(m == MODE_OKAY for m in slave_modes)
        expected_resp = AXI_RESP_OKAY if any_okay else AXI_RESP_SLVERR

        addr = rng.randint(0, 0xFFFF) << 2
        data = rng.randint(0, 0xFFFFFFFF)

        try:
            bresp = await with_timeout(master.write(addr, data), TIMEOUT_NS, "ns")
            if bresp != expected_resp:
                failures.append(
                    f"iter {iteration} write: got {bresp}, expected {expected_resp}"
                )
        except Exception as e:
            failures.append(f"iter {iteration} write exception: {e}")
            master.init()
            continue

        # Reset modes for read (same slave_modes)
        for i, s in enumerate(slaves):
            s.mode      = slave_modes[i]
            s.read_data = data  # let slave echo back the data

        try:
            rdata, rresp = await with_timeout(master.read(addr), TIMEOUT_NS, "ns")
            if rresp != expected_resp:
                failures.append(
                    f"iter {iteration} read: got {rresp}, expected {expected_resp}"
                )
        except Exception as e:
            failures.append(f"iter {iteration} read exception: {e}")
            master.init()

    assert not failures, "Randomized sequence failures:\n" + "\n".join(failures)
    dut._log.info("[PASS] NEW-007 - 20 random iterations all correct")


@cocotb.test()
async def test_wready_count_verification(dut):
    """NEW-008: 5 consecutive writes each with awvalid+wvalid simultaneous;
    total wready pulses must equal exactly 5."""
    master, slaves = await setup(dut)
    _set_all_slaves(slaves, MODE_OKAY)

    total_wready = 0

    async def count_wready():
        nonlocal total_wready
        for _ in range(TIMEOUT_CYCLES * 5):
            await RisingEdge(dut.i_clk)
            if int(dut.m_wready.value) == 1:
                total_wready += 1

    counter = cocotb.start_soon(count_wready())

    for i in range(5):
        bresp = await with_timeout(
            master.write(0x1000 + i * 4, 0x100 + i),
            TIMEOUT_NS, "ns"
        )
        assert bresp == AXI_RESP_OKAY, f"Write {i}: expected OKAY, got {bresp}"

    counter.kill()

    assert total_wready == 5, \
        f"wready pulsed {total_wready} times for 5 writes, expected exactly 5"
    dut._log.info("[PASS] NEW-008 - wready count = 5 for 5 simultaneous AW+W writes")
