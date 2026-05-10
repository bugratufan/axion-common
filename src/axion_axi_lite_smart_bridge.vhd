--------------------------------------------------------------------------------
-- AXI4-Lite Smart Bridge
--
-- Routes a single AXI4-Lite master to exactly one of N AXI4-Lite slaves,
-- selected by address matching at the start of each transaction.
--
-- Features:
--   - Address-based routing: only the matching slave receives the transaction
--   - Per-slave base address and range configured via generic arrays
--   - Number of slaves inferred from the length of the generic arrays
--   - Immediate SLVERR if no slave's range covers the incoming address
--   - Configurable timeout: SLVERR returned if the selected slave does not
--     respond within g_SLAVE_TIMEOUT cycles
--   - Post-timeout drain: stale slave response consumed before next transaction
--   - Full address forwarded unchanged to slave (no base subtraction)
--   - Priority encoding: lowest-index slave wins on overlapping address ranges
--
-- Address match condition (inclusive both ends):
--   addr >= G_BASE_ADDRS(i)  AND  addr <= G_BASE_ADDRS(i) + G_ADDR_RANGES(i)
--
-- Example instantiation (3 slaves):
--   G_BASE_ADDRS  => (0 => x"0000_0000", 1 => x"0000_0100", 2 => x"0000_0200")
--   G_ADDR_RANGES => (0 => x"0000_00FF", 1 => x"0000_00FF", 2 => x"0000_00FF")
--
-- Copyright (c) 2024 Bugra Tufan
-- MIT License
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.axion_common_pkg.all;

entity axion_axi_lite_smart_bridge is
    generic (
        -- Per-slave base addresses; array length sets the number of slaves
        G_BASE_ADDRS    : t_addr_array;
        -- Per-slave address ranges (inclusive upper bound = base + range)
        G_ADDR_RANGES   : t_addr_array;
        -- Slave timeout in clock cycles (SLVERR returned if slave takes longer)
        g_SLAVE_TIMEOUT : positive := 256
    );
    port (
        i_clk         : in  std_logic;
        i_rst_n       : in  std_logic;

        -- Upstream: connects to AXI4-Lite master
        M_AXI_M2S     : in  t_axi_lite_m2s;
        M_AXI_S2M     : out t_axi_lite_s2m;

        -- Downstream: connects to AXI4-Lite slaves
        S_AXI_ARR_M2S : out t_axi_lite_m2s_array(G_BASE_ADDRS'range);
        S_AXI_ARR_S2M : in  t_axi_lite_s2m_array(G_BASE_ADDRS'range)
    );
end entity axion_axi_lite_smart_bridge;

architecture rtl of axion_axi_lite_smart_bridge is

    ---------------------------------------------------------------------------
    -- Types
    ---------------------------------------------------------------------------
    type t_state is (
        ST_IDLE,
        ST_WRITE_ADDR,      -- write: waiting for targeted slave awready
        ST_WRITE_DATA,      -- write: waiting for targeted slave wready
        ST_WRITE_RESP,      -- write: waiting for targeted slave bvalid
        ST_WRITE_COMPLETE,  -- write: SLVERR sent to master, draining slave if pending
        ST_WRITE_DRAIN,     -- write: consuming stale bvalid after master already served
        ST_WRITE_ERR_DATA,  -- no-match write: waiting for W channel before SLVERR
        ST_WRITE_ERR_RESP,  -- no-match/addr-timeout write: holding SLVERR bvalid
        ST_READ_ADDR,       -- read: waiting for targeted slave arready
        ST_READ_RESP,       -- read: waiting for targeted slave rvalid
        ST_READ_COMPLETE,   -- read: SLVERR sent to master, draining slave if pending
        ST_READ_DRAIN,      -- read: consuming stale rvalid after master already served
        ST_READ_ERR_RESP    -- no-match/addr-timeout read: holding SLVERR rvalid
    );

    ---------------------------------------------------------------------------
    -- Signals
    ---------------------------------------------------------------------------
    signal state            : t_state;
    signal timeout_cnt      : natural range 0 to g_SLAVE_TIMEOUT;
    signal timeout_flag     : std_logic;

    signal m_awaddr_reg     : std_logic_vector(C_AXI_ADDR_WIDTH-1 downto 0);
    signal m_awprot_reg     : std_logic_vector(2 downto 0);
    signal m_wdata_reg      : std_logic_vector(C_AXI_DATA_WIDTH-1 downto 0);
    signal m_wstrb_reg      : std_logic_vector(C_AXI_STRB_WIDTH-1 downto 0);
    signal m_araddr_reg     : std_logic_vector(C_AXI_ADDR_WIDTH-1 downto 0);
    signal m_arprot_reg     : std_logic_vector(2 downto 0);
    signal wdata_captured   : std_logic;

    -- Index of the slave selected for the current transaction
    signal sel_slave        : integer range G_BASE_ADDRS'low to G_BASE_ADDRS'high;

    -- Set when the targeted slave's response has been consumed (in COMPLETE state)
    signal slave_resp_seen  : std_logic;

    -- Guards the first cycle of WRITE_ERR_RESP / READ_ERR_RESP so that bvalid /
    -- rvalid is held for at least one observable cycle even when the master
    -- pre-asserts bready / rready before bvalid / rvalid is seen.
    --
    -- Cocotb's AxiLiteMaster pre-asserts bready and checks bvalid only AFTER
    -- a RisingEdge call.  Without this guard, bvalid is set in cycle N and
    -- cleared in cycle N+1 (bready already = 1); the master only checks after
    -- cycle N+1 and sees 0, causing a spurious TimeoutError.
    signal hold_err_resp    : std_logic;

    signal m_axi_out        : t_axi_lite_s2m;
    signal s_axi_out        : t_axi_lite_m2s_array(G_BASE_ADDRS'range);

begin

    assert G_BASE_ADDRS'length = G_ADDR_RANGES'length
        report "axion_axi_lite_smart_bridge: G_BASE_ADDRS and G_ADDR_RANGES must have equal length"
        severity failure;

    ---------------------------------------------------------------------------
    -- Main State Machine
    ---------------------------------------------------------------------------
    p_fsm : process(i_clk)
        variable v_match_found : boolean;
        variable v_match_idx   : integer range G_BASE_ADDRS'low to G_BASE_ADDRS'high;
    begin
        if rising_edge(i_clk) then
            if i_rst_n = '0' then
                state           <= ST_IDLE;
                timeout_cnt     <= 0;
                timeout_flag    <= '0';
                wdata_captured  <= '0';
                slave_resp_seen <= '0';
                hold_err_resp   <= '0';
                sel_slave       <= G_BASE_ADDRS'low;
                m_awaddr_reg    <= (others => '0');
                m_awprot_reg    <= (others => '0');
                m_wdata_reg     <= (others => '0');
                m_wstrb_reg     <= (others => '0');
                m_araddr_reg    <= (others => '0');
                m_arprot_reg    <= (others => '0');
                m_axi_out       <= C_AXI_LITE_S2M_INIT;
                for i in G_BASE_ADDRS'range loop
                    s_axi_out(i) <= C_AXI_LITE_M2S_INIT;
                end loop;

            else
                -- Default: clear single-cycle ready pulses
                m_axi_out.awready <= '0';
                m_axi_out.wready  <= '0';
                m_axi_out.arready <= '0';

                -- Timeout counter: counts only while waiting for a SLAVE response.
                -- Held at zero in IDLE, error states, and COMPLETE states.
                -- COMPLETE states wait for the MASTER (bready/rready), not the
                -- slave, so counting there would cause a stale timeout_flag to
                -- fire prematurely when the FSM later enters DRAIN.
                if state = ST_IDLE or
                   state = ST_WRITE_ERR_DATA or state = ST_WRITE_ERR_RESP or
                   state = ST_READ_ERR_RESP or
                   state = ST_WRITE_COMPLETE or state = ST_READ_COMPLETE
                then
                    timeout_cnt  <= 0;
                    timeout_flag <= '0';
                elsif timeout_cnt >= g_SLAVE_TIMEOUT - 1 then
                    timeout_flag <= '1';
                else
                    timeout_cnt <= timeout_cnt + 1;
                end if;

                case state is

                    -----------------------------------------------------------
                    -- IDLE: decode address and route or generate immediate error
                    -----------------------------------------------------------
                    when ST_IDLE =>
                        m_axi_out.bvalid <= '0';
                        m_axi_out.rvalid <= '0';
                        wdata_captured   <= '0';
                        slave_resp_seen  <= '0';

                        for i in G_BASE_ADDRS'range loop
                            s_axi_out(i) <= C_AXI_LITE_M2S_INIT;
                        end loop;

                        if M_AXI_M2S.awvalid = '1' then
                            -- Priority-encoded address decode
                            v_match_found := false;
                            v_match_idx   := G_BASE_ADDRS'low;
                            for i in G_BASE_ADDRS'range loop
                                if not v_match_found then
                                    if unsigned(M_AXI_M2S.awaddr) >= unsigned(G_BASE_ADDRS(i)) and
                                       unsigned(M_AXI_M2S.awaddr) <=
                                           unsigned(G_BASE_ADDRS(i)) + unsigned(G_ADDR_RANGES(i))
                                    then
                                        v_match_found := true;
                                        v_match_idx   := i;
                                    end if;
                                end if;
                            end loop;

                            m_axi_out.awready <= '1';

                            if v_match_found then
                                sel_slave    <= v_match_idx;
                                m_awaddr_reg <= M_AXI_M2S.awaddr;
                                m_awprot_reg <= M_AXI_M2S.awprot;

                                s_axi_out(v_match_idx).awaddr  <= M_AXI_M2S.awaddr;
                                s_axi_out(v_match_idx).awprot  <= M_AXI_M2S.awprot;
                                s_axi_out(v_match_idx).awvalid <= '1';

                                if M_AXI_M2S.wvalid = '1' then
                                    m_wdata_reg      <= M_AXI_M2S.wdata;
                                    m_wstrb_reg      <= M_AXI_M2S.wstrb;
                                    m_axi_out.wready <= '1';
                                    wdata_captured   <= '1';
                                    s_axi_out(v_match_idx).wdata  <= M_AXI_M2S.wdata;
                                    s_axi_out(v_match_idx).wstrb  <= M_AXI_M2S.wstrb;
                                    s_axi_out(v_match_idx).wvalid <= '1';
                                    s_axi_out(v_match_idx).bready <= '1';
                                end if;

                                state <= ST_WRITE_ADDR;
                            else
                                -- No matching slave → immediate SLVERR.
                                -- bvalid is pre-set here so it is visible for one full
                                -- cycle when WRITE_ERR_RESP is entered, even when the
                                -- master already has bready asserted.
                                if M_AXI_M2S.wvalid = '1' then
                                    m_axi_out.wready <= '1';
                                    m_axi_out.bresp  <= C_AXI_RESP_SLVERR;
                                    m_axi_out.bvalid <= '1';
                                    hold_err_resp    <= '1';
                                    state <= ST_WRITE_ERR_RESP;
                                else
                                    state <= ST_WRITE_ERR_DATA;
                                end if;
                            end if;

                        elsif M_AXI_M2S.arvalid = '1' then
                            -- Priority-encoded address decode
                            v_match_found := false;
                            v_match_idx   := G_BASE_ADDRS'low;
                            for i in G_BASE_ADDRS'range loop
                                if not v_match_found then
                                    if unsigned(M_AXI_M2S.araddr) >= unsigned(G_BASE_ADDRS(i)) and
                                       unsigned(M_AXI_M2S.araddr) <=
                                           unsigned(G_BASE_ADDRS(i)) + unsigned(G_ADDR_RANGES(i))
                                    then
                                        v_match_found := true;
                                        v_match_idx   := i;
                                    end if;
                                end if;
                            end loop;

                            m_axi_out.arready <= '1';

                            if v_match_found then
                                sel_slave    <= v_match_idx;
                                m_araddr_reg <= M_AXI_M2S.araddr;
                                m_arprot_reg <= M_AXI_M2S.arprot;

                                s_axi_out(v_match_idx).araddr  <= M_AXI_M2S.araddr;
                                s_axi_out(v_match_idx).arprot  <= M_AXI_M2S.arprot;
                                s_axi_out(v_match_idx).arvalid <= '1';
                                s_axi_out(v_match_idx).rready  <= '1';

                                state <= ST_READ_ADDR;
                            else
                                -- No matching slave → immediate SLVERR.
                                -- rvalid pre-set so it is visible when READ_ERR_RESP is entered.
                                m_axi_out.rdata  <= (others => '0');
                                m_axi_out.rresp  <= C_AXI_RESP_SLVERR;
                                m_axi_out.rvalid <= '1';
                                hold_err_resp    <= '1';
                                state <= ST_READ_ERR_RESP;
                            end if;
                        end if;

                    -----------------------------------------------------------
                    -- WRITE_ADDR: wait for targeted slave awready, then wait for wdata
                    -----------------------------------------------------------
                    when ST_WRITE_ADDR =>
                        if S_AXI_ARR_S2M(sel_slave).awready = '1' then
                            s_axi_out(sel_slave).awvalid <= '0';
                        end if;

                        if M_AXI_M2S.wvalid = '1' and wdata_captured = '0' then
                            m_wdata_reg      <= M_AXI_M2S.wdata;
                            m_wstrb_reg      <= M_AXI_M2S.wstrb;
                            m_axi_out.wready <= '1';
                            wdata_captured   <= '1';
                            s_axi_out(sel_slave).wdata  <= M_AXI_M2S.wdata;
                            s_axi_out(sel_slave).wstrb  <= M_AXI_M2S.wstrb;
                            s_axi_out(sel_slave).wvalid <= '1';
                            s_axi_out(sel_slave).bready <= '1';
                            state <= ST_WRITE_DATA;
                        elsif wdata_captured = '1' then
                            -- wdata forwarded simultaneously with AW in IDLE
                            state <= ST_WRITE_DATA;
                        end if;

                        -- Timeout: W channel never arrived (or AW never accepted).
                        -- Slave cannot have sent bvalid without completing the W handshake,
                        -- so no drain is needed; go straight to error response.
                        if timeout_flag = '1' then
                            timeout_flag  <= '0';
                            timeout_cnt   <= 0;
                            for i in G_BASE_ADDRS'range loop
                                s_axi_out(i) <= C_AXI_LITE_M2S_INIT;
                            end loop;
                            m_axi_out.bresp  <= C_AXI_RESP_SLVERR;
                            m_axi_out.bvalid <= '1';
                            hold_err_resp    <= '1';
                            state <= ST_WRITE_ERR_RESP;
                        end if;

                    -----------------------------------------------------------
                    -- WRITE_DATA: wait for targeted slave wready
                    -----------------------------------------------------------
                    when ST_WRITE_DATA =>
                        -- Clear awvalid for slaves that assert awready late
                        if S_AXI_ARR_S2M(sel_slave).awready = '1' then
                            s_axi_out(sel_slave).awvalid <= '0';
                        end if;

                        if S_AXI_ARR_S2M(sel_slave).wready = '1' then
                            s_axi_out(sel_slave).wvalid <= '0';
                            state <= ST_WRITE_RESP;
                        end if;

                        -- Timeout: slave accepted AW+W but wready not seen yet.
                        -- Slave may eventually complete and assert bvalid → drain needed.
                        if timeout_flag = '1' then
                            timeout_flag     <= '0';
                            timeout_cnt      <= 0;
                            m_axi_out.bresp  <= C_AXI_RESP_SLVERR;
                            m_axi_out.bvalid <= '1';
                            state <= ST_WRITE_COMPLETE;
                        end if;

                    -----------------------------------------------------------
                    -- WRITE_RESP: wait for targeted slave bvalid
                    -----------------------------------------------------------
                    when ST_WRITE_RESP =>
                        if S_AXI_ARR_S2M(sel_slave).bvalid = '1' then
                            m_axi_out.bresp  <= S_AXI_ARR_S2M(sel_slave).bresp;
                            m_axi_out.bvalid <= '1';
                            s_axi_out(sel_slave).bready <= '0';
                            slave_resp_seen  <= '1';
                            state <= ST_WRITE_COMPLETE;
                        end if;

                        -- Timeout: slave is still processing → drain needed.
                        if timeout_flag = '1' then
                            timeout_flag     <= '0';
                            timeout_cnt      <= 0;
                            m_axi_out.bresp  <= C_AXI_RESP_SLVERR;
                            m_axi_out.bvalid <= '1';
                            state <= ST_WRITE_COMPLETE;
                        end if;

                    -----------------------------------------------------------
                    -- WRITE_COMPLETE: hold response for master; drain slave if needed
                    -----------------------------------------------------------
                    when ST_WRITE_COMPLETE =>
                        -- Absorb slave response if it arrives while waiting for bready
                        if S_AXI_ARR_S2M(sel_slave).bvalid = '1' and slave_resp_seen = '0' then
                            slave_resp_seen             <= '1';
                            s_axi_out(sel_slave).bready <= '0';
                        end if;

                        if M_AXI_M2S.bready = '1' then
                            m_axi_out.bvalid <= '0';
                            -- Use combinatorial bvalid here: slave_resp_seen may not yet
                            -- reflect an update scheduled this same delta.
                            if slave_resp_seen = '1' or S_AXI_ARR_S2M(sel_slave).bvalid = '1' then
                                state <= ST_IDLE;
                            else
                                -- Slave hasn't responded yet; keep bready asserted and drain
                                s_axi_out(sel_slave).bready <= '1';
                                state <= ST_WRITE_DRAIN;
                            end if;
                        end if;

                    -----------------------------------------------------------
                    -- WRITE_DRAIN: consume stale bvalid; second timeout forces exit
                    -----------------------------------------------------------
                    when ST_WRITE_DRAIN =>
                        if S_AXI_ARR_S2M(sel_slave).bvalid = '1' or timeout_flag = '1' then
                            s_axi_out(sel_slave).bready <= '0';
                            state <= ST_IDLE;
                        end if;

                    -----------------------------------------------------------
                    -- WRITE_ERR_DATA: no-match write, waiting for W channel
                    -----------------------------------------------------------
                    when ST_WRITE_ERR_DATA =>
                        if M_AXI_M2S.wvalid = '1' then
                            m_axi_out.wready <= '1';
                            m_axi_out.bresp  <= C_AXI_RESP_SLVERR;
                            m_axi_out.bvalid <= '1';
                            hold_err_resp    <= '1';
                            state <= ST_WRITE_ERR_RESP;
                        end if;

                    -----------------------------------------------------------
                    -- WRITE_ERR_RESP: bvalid was pre-set; wait for master bready
                    -----------------------------------------------------------
                    when ST_WRITE_ERR_RESP =>
                        -- bvalid is already '1' (set in the preceding state).
                        -- hold_err_resp is '1' on the first cycle in this state.
                        -- We clear it and skip the bready check that cycle so the
                        -- master always has at least one rising edge to observe
                        -- bvalid before it is deasserted.
                        m_axi_out.bresp <= C_AXI_RESP_SLVERR;
                        hold_err_resp   <= '0';
                        if M_AXI_M2S.bready = '1' and hold_err_resp = '0' then
                            m_axi_out.bvalid <= '0';
                            state <= ST_IDLE;
                        end if;

                    -----------------------------------------------------------
                    -- READ_ADDR: wait for targeted slave arready
                    -----------------------------------------------------------
                    when ST_READ_ADDR =>
                        if S_AXI_ARR_S2M(sel_slave).arready = '1' then
                            s_axi_out(sel_slave).arvalid <= '0';
                            state <= ST_READ_RESP;
                        end if;

                        -- Timeout: AR not yet accepted, slave will not produce rvalid
                        -- → no drain needed; go straight to error response.
                        if timeout_flag = '1' then
                            timeout_flag     <= '0';
                            timeout_cnt      <= 0;
                            for i in G_BASE_ADDRS'range loop
                                s_axi_out(i) <= C_AXI_LITE_M2S_INIT;
                            end loop;
                            m_axi_out.rdata  <= (others => '0');
                            m_axi_out.rresp  <= C_AXI_RESP_SLVERR;
                            m_axi_out.rvalid <= '1';
                            hold_err_resp    <= '1';
                            state <= ST_READ_ERR_RESP;
                        end if;

                    -----------------------------------------------------------
                    -- READ_RESP: wait for targeted slave rvalid
                    -----------------------------------------------------------
                    when ST_READ_RESP =>
                        if S_AXI_ARR_S2M(sel_slave).rvalid = '1' then
                            m_axi_out.rdata  <= S_AXI_ARR_S2M(sel_slave).rdata;
                            m_axi_out.rresp  <= S_AXI_ARR_S2M(sel_slave).rresp;
                            m_axi_out.rvalid <= '1';
                            s_axi_out(sel_slave).rready <= '0';
                            slave_resp_seen  <= '1';
                            state <= ST_READ_COMPLETE;
                        end if;

                        -- Timeout: slave is still processing → drain needed.
                        if timeout_flag = '1' then
                            timeout_flag     <= '0';
                            timeout_cnt      <= 0;
                            m_axi_out.rdata  <= (others => '0');
                            m_axi_out.rresp  <= C_AXI_RESP_SLVERR;
                            m_axi_out.rvalid <= '1';
                            state <= ST_READ_COMPLETE;
                        end if;

                    -----------------------------------------------------------
                    -- READ_COMPLETE: hold response for master; drain slave if needed
                    -----------------------------------------------------------
                    when ST_READ_COMPLETE =>
                        -- Absorb slave response if it arrives while waiting for rready
                        if S_AXI_ARR_S2M(sel_slave).rvalid = '1' and slave_resp_seen = '0' then
                            slave_resp_seen             <= '1';
                            s_axi_out(sel_slave).rready <= '0';
                        end if;

                        if M_AXI_M2S.rready = '1' then
                            m_axi_out.rvalid <= '0';
                            if slave_resp_seen = '1' or S_AXI_ARR_S2M(sel_slave).rvalid = '1' then
                                state <= ST_IDLE;
                            else
                                s_axi_out(sel_slave).rready <= '1';
                                state <= ST_READ_DRAIN;
                            end if;
                        end if;

                    -----------------------------------------------------------
                    -- READ_DRAIN: consume stale rvalid; second timeout forces exit
                    -----------------------------------------------------------
                    when ST_READ_DRAIN =>
                        if S_AXI_ARR_S2M(sel_slave).rvalid = '1' or timeout_flag = '1' then
                            s_axi_out(sel_slave).rready <= '0';
                            state <= ST_IDLE;
                        end if;

                    -----------------------------------------------------------
                    -- READ_ERR_RESP: rvalid was pre-set; wait for master rready
                    -----------------------------------------------------------
                    when ST_READ_ERR_RESP =>
                        -- rvalid is already '1' (set in the preceding state).
                        -- Same hold_err_resp guard as WRITE_ERR_RESP.
                        m_axi_out.rresp <= C_AXI_RESP_SLVERR;
                        hold_err_resp   <= '0';
                        if M_AXI_M2S.rready = '1' and hold_err_resp = '0' then
                            m_axi_out.rvalid <= '0';
                            state <= ST_IDLE;
                        end if;

                    when others =>
                        state <= ST_IDLE;

                end case;
            end if;
        end if;
    end process p_fsm;

    ---------------------------------------------------------------------------
    -- Output Assignments
    ---------------------------------------------------------------------------
    M_AXI_S2M     <= m_axi_out;
    S_AXI_ARR_M2S <= s_axi_out;

end architecture rtl;
