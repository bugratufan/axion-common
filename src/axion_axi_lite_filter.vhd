--------------------------------------------------------------------------------
-- AXI4-Lite Address Filter
--
-- Filters AXI4-Lite transactions based on a configurable address range.
-- Transactions whose address falls within [G_ADDR_BEGIN, G_ADDR_END] are
-- forwarded to the downstream slave transparently (zero added handshake
-- overhead once the transaction is in progress).
-- Transactions outside this range are terminated locally with a SLVERR
-- response; the downstream slave never sees them.
--
-- Latency: 1 clock cycle is added before the first address-phase handshake
-- (the guard spends one cycle checking the range before forwarding).
-- All subsequent channel handshakes run at full speed.
--
-- Copyright (c) 2024 Bugra Tufan
-- MIT License
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.axion_common_pkg.all;

entity axion_axi_lite_filter is
    generic (
        -- Inclusive lower bound of the allowed address range
        G_ADDR_BEGIN : std_logic_vector(C_AXI_ADDR_WIDTH-1 downto 0) := (others => '0');
        -- Inclusive upper bound of the allowed address range
        G_ADDR_END   : std_logic_vector(C_AXI_ADDR_WIDTH-1 downto 0) := (others => '1')
    );
    port (
        i_clk   : in  std_logic;
        i_rst_n : in  std_logic;

        -- Upstream port — master connects here
        UP_M2S  : in  t_axi_lite_m2s;
        UP_S2M  : out t_axi_lite_s2m;

        -- Downstream port — slave connects here
        DN_M2S  : out t_axi_lite_m2s;
        DN_S2M  : in  t_axi_lite_s2m
    );
end entity axion_axi_lite_filter;

architecture rtl of axion_axi_lite_filter is

    ---------------------------------------------------------------------------
    -- Types
    ---------------------------------------------------------------------------
    type t_state is (
        ST_IDLE,
        ST_WRITE_PASS,      -- in-range write: transparent forwarding
        ST_WRITE_ERR_DATA,  -- out-of-range write: waiting for W channel
        ST_WRITE_ERR_RESP,  -- out-of-range write: asserting SLVERR B channel
        ST_READ_PASS,       -- in-range read: transparent forwarding
        ST_READ_ERR_RESP    -- out-of-range read: asserting SLVERR R channel
    );

    ---------------------------------------------------------------------------
    -- Signals
    ---------------------------------------------------------------------------
    signal state       : t_state;

    -- Error-path handshake registers (single-cycle pulses or held valids)
    signal err_awready : std_logic;
    signal err_wready  : std_logic;
    signal err_arready : std_logic;
    signal err_bvalid  : std_logic;
    signal err_rvalid  : std_logic;

begin

    ---------------------------------------------------------------------------
    -- State Machine
    ---------------------------------------------------------------------------
    p_fsm : process(i_clk)
    begin
        if rising_edge(i_clk) then
            if i_rst_n = '0' then
                state       <= ST_IDLE;
                err_awready <= '0';
                err_wready  <= '0';
                err_arready <= '0';
                err_bvalid  <= '0';
                err_rvalid  <= '0';
            else
                -- Default: clear single-cycle ready pulses every cycle
                err_awready <= '0';
                err_wready  <= '0';
                err_arready <= '0';

                case state is
                    -----------------------------------------------------------
                    -- IDLE: inspect the incoming transaction and route it
                    -----------------------------------------------------------
                    when ST_IDLE =>
                        err_bvalid <= '0';
                        err_rvalid <= '0';

                        if UP_M2S.awvalid = '1' then
                            if unsigned(UP_M2S.awaddr) >= unsigned(G_ADDR_BEGIN) and
                               unsigned(UP_M2S.awaddr) <= unsigned(G_ADDR_END)
                            then
                                state <= ST_WRITE_PASS;
                            else
                                -- Accept AW (and W if already present) locally
                                err_awready <= '1';
                                if UP_M2S.wvalid = '1' then
                                    err_wready <= '1';
                                    state <= ST_WRITE_ERR_RESP;
                                else
                                    state <= ST_WRITE_ERR_DATA;
                                end if;
                            end if;

                        elsif UP_M2S.arvalid = '1' then
                            if unsigned(UP_M2S.araddr) >= unsigned(G_ADDR_BEGIN) and
                               unsigned(UP_M2S.araddr) <= unsigned(G_ADDR_END)
                            then
                                state <= ST_READ_PASS;
                            else
                                err_arready <= '1';
                                state <= ST_READ_ERR_RESP;
                            end if;
                        end if;

                    -----------------------------------------------------------
                    -- WRITE_PASS: forward all write channels transparently;
                    -- exit once the B-channel handshake completes
                    -----------------------------------------------------------
                    when ST_WRITE_PASS =>
                        if DN_S2M.bvalid = '1' and UP_M2S.bready = '1' then
                            state <= ST_IDLE;
                        end if;

                    -----------------------------------------------------------
                    -- WRITE_ERR_DATA: AW accepted, waiting for W channel
                    -----------------------------------------------------------
                    when ST_WRITE_ERR_DATA =>
                        if UP_M2S.wvalid = '1' then
                            err_wready <= '1';
                            state <= ST_WRITE_ERR_RESP;
                        end if;

                    -----------------------------------------------------------
                    -- WRITE_ERR_RESP: hold SLVERR bvalid until master accepts
                    -----------------------------------------------------------
                    when ST_WRITE_ERR_RESP =>
                        err_bvalid <= '1';
                        if UP_M2S.bready = '1' then
                            err_bvalid <= '0';   -- last assignment wins
                            state <= ST_IDLE;
                        end if;

                    -----------------------------------------------------------
                    -- READ_PASS: forward all read channels transparently;
                    -- exit once the R-channel handshake completes
                    -----------------------------------------------------------
                    when ST_READ_PASS =>
                        if DN_S2M.rvalid = '1' and UP_M2S.rready = '1' then
                            state <= ST_IDLE;
                        end if;

                    -----------------------------------------------------------
                    -- READ_ERR_RESP: hold SLVERR rvalid until master accepts
                    -----------------------------------------------------------
                    when ST_READ_ERR_RESP =>
                        err_rvalid <= '1';
                        if UP_M2S.rready = '1' then
                            err_rvalid <= '0';   -- last assignment wins
                            state <= ST_IDLE;
                        end if;

                    when others =>
                        state <= ST_IDLE;

                end case;
            end if;
        end if;
    end process p_fsm;

    ---------------------------------------------------------------------------
    -- Combinatorial Output Mux
    -- Pass-through states: wire upstream <-> downstream directly.
    -- All other states: block downstream and drive local error signals.
    ---------------------------------------------------------------------------
    p_out : process(state, UP_M2S, DN_S2M,
                    err_awready, err_wready, err_arready,
                    err_bvalid, err_rvalid)
        variable v_s2m : t_axi_lite_s2m;
    begin
        if state = ST_WRITE_PASS or state = ST_READ_PASS then
            DN_M2S <= UP_M2S;
            UP_S2M <= DN_S2M;
        else
            DN_M2S        <= C_AXI_LITE_M2S_INIT;
            v_s2m         := C_AXI_LITE_S2M_INIT;
            v_s2m.awready := err_awready;
            v_s2m.wready  := err_wready;
            v_s2m.arready := err_arready;
            v_s2m.bvalid  := err_bvalid;
            v_s2m.bresp   := C_AXI_RESP_SLVERR;
            v_s2m.rvalid  := err_rvalid;
            v_s2m.rresp   := C_AXI_RESP_SLVERR;
            v_s2m.rdata   := (others => '0');
            UP_S2M        <= v_s2m;
        end if;
    end process p_out;

end architecture rtl;
