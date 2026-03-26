--------------------------------------------------------------------------------
-- AXI4-Lite Bridge Cocotb Wrapper
--
-- Wraps axion_axi_lite_bridge with flat std_logic ports so cocotb can drive
-- all signals directly without needing record-type VPI access.
--
-- Fixed configuration: G_NUM_SLAVES = 3
-- Passthrough:         G_TIMEOUT_WIDTH generic
--
-- Copyright (c) 2024 Bugra Tufan
-- MIT License
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library axion_common;
use axion_common.axion_common_pkg.all;

entity axion_axi_lite_bridge_wrap is
    generic (
        G_TIMEOUT_WIDTH : positive := 16
    );
    port (
        -- Clock and Reset
        i_clk       : in  std_logic;
        i_rst_n     : in  std_logic;

        -- ----------------------------------------------------------------
        -- Master-side flat signals
        -- ----------------------------------------------------------------
        -- Write Address Channel
        m_awaddr    : in  std_logic_vector(31 downto 0);
        m_awprot    : in  std_logic_vector(2 downto 0);
        m_awvalid   : in  std_logic;
        m_awready   : out std_logic;

        -- Write Data Channel
        m_wdata     : in  std_logic_vector(31 downto 0);
        m_wstrb     : in  std_logic_vector(3 downto 0);
        m_wvalid    : in  std_logic;
        m_wready    : out std_logic;

        -- Write Response Channel
        m_bresp     : out std_logic_vector(1 downto 0);
        m_bvalid    : out std_logic;
        m_bready    : in  std_logic;

        -- Read Address Channel
        m_araddr    : in  std_logic_vector(31 downto 0);
        m_arprot    : in  std_logic_vector(2 downto 0);
        m_arvalid   : in  std_logic;
        m_arready   : out std_logic;

        -- Read Data Channel
        m_rdata     : out std_logic_vector(31 downto 0);
        m_rresp     : out std_logic_vector(1 downto 0);
        m_rvalid    : out std_logic;
        m_rready    : in  std_logic;

        -- ----------------------------------------------------------------
        -- Slave 0 flat signals
        -- ----------------------------------------------------------------
        -- Write Address Channel
        s0_awaddr   : out std_logic_vector(31 downto 0);
        s0_awprot   : out std_logic_vector(2 downto 0);
        s0_awvalid  : out std_logic;
        s0_awready  : in  std_logic;

        -- Write Data Channel
        s0_wdata    : out std_logic_vector(31 downto 0);
        s0_wstrb    : out std_logic_vector(3 downto 0);
        s0_wvalid   : out std_logic;
        s0_wready   : in  std_logic;

        -- Write Response Channel
        s0_bresp    : in  std_logic_vector(1 downto 0);
        s0_bvalid   : in  std_logic;
        s0_bready   : out std_logic;

        -- Read Address Channel
        s0_araddr   : out std_logic_vector(31 downto 0);
        s0_arprot   : out std_logic_vector(2 downto 0);
        s0_arvalid  : out std_logic;
        s0_arready  : in  std_logic;

        -- Read Data Channel
        s0_rdata    : in  std_logic_vector(31 downto 0);
        s0_rresp    : in  std_logic_vector(1 downto 0);
        s0_rvalid   : in  std_logic;
        s0_rready   : out std_logic;

        -- ----------------------------------------------------------------
        -- Slave 1 flat signals
        -- ----------------------------------------------------------------
        -- Write Address Channel
        s1_awaddr   : out std_logic_vector(31 downto 0);
        s1_awprot   : out std_logic_vector(2 downto 0);
        s1_awvalid  : out std_logic;
        s1_awready  : in  std_logic;

        -- Write Data Channel
        s1_wdata    : out std_logic_vector(31 downto 0);
        s1_wstrb    : out std_logic_vector(3 downto 0);
        s1_wvalid   : out std_logic;
        s1_wready   : in  std_logic;

        -- Write Response Channel
        s1_bresp    : in  std_logic_vector(1 downto 0);
        s1_bvalid   : in  std_logic;
        s1_bready   : out std_logic;

        -- Read Address Channel
        s1_araddr   : out std_logic_vector(31 downto 0);
        s1_arprot   : out std_logic_vector(2 downto 0);
        s1_arvalid  : out std_logic;
        s1_arready  : in  std_logic;

        -- Read Data Channel
        s1_rdata    : in  std_logic_vector(31 downto 0);
        s1_rresp    : in  std_logic_vector(1 downto 0);
        s1_rvalid   : in  std_logic;
        s1_rready   : out std_logic;

        -- ----------------------------------------------------------------
        -- Slave 2 flat signals
        -- ----------------------------------------------------------------
        -- Write Address Channel
        s2_awaddr   : out std_logic_vector(31 downto 0);
        s2_awprot   : out std_logic_vector(2 downto 0);
        s2_awvalid  : out std_logic;
        s2_awready  : in  std_logic;

        -- Write Data Channel
        s2_wdata    : out std_logic_vector(31 downto 0);
        s2_wstrb    : out std_logic_vector(3 downto 0);
        s2_wvalid   : out std_logic;
        s2_wready   : in  std_logic;

        -- Write Response Channel
        s2_bresp    : in  std_logic_vector(1 downto 0);
        s2_bvalid   : in  std_logic;
        s2_bready   : out std_logic;

        -- Read Address Channel
        s2_araddr   : out std_logic_vector(31 downto 0);
        s2_arprot   : out std_logic_vector(2 downto 0);
        s2_arvalid  : out std_logic;
        s2_arready  : in  std_logic;

        -- Read Data Channel
        s2_rdata    : in  std_logic_vector(31 downto 0);
        s2_rresp    : in  std_logic_vector(1 downto 0);
        s2_rvalid   : in  std_logic;
        s2_rready   : out std_logic
    );
end entity axion_axi_lite_bridge_wrap;

architecture rtl of axion_axi_lite_bridge_wrap is

    ---------------------------------------------------------------------------
    -- Internal record signals
    ---------------------------------------------------------------------------
    signal m_axi_m2s       : t_axi_lite_m2s;
    signal m_axi_s2m       : t_axi_lite_s2m;
    signal s_axi_arr_m2s   : t_axi_lite_m2s_array(0 to 2);
    signal s_axi_arr_s2m   : t_axi_lite_s2m_array(0 to 2);

begin

    ---------------------------------------------------------------------------
    -- Assemble master M2S record from flat inputs
    ---------------------------------------------------------------------------
    m_axi_m2s.awaddr  <= m_awaddr;
    m_axi_m2s.awprot  <= m_awprot;
    m_axi_m2s.awvalid <= m_awvalid;
    m_axi_m2s.wdata   <= m_wdata;
    m_axi_m2s.wstrb   <= m_wstrb;
    m_axi_m2s.wvalid  <= m_wvalid;
    m_axi_m2s.bready  <= m_bready;
    m_axi_m2s.araddr  <= m_araddr;
    m_axi_m2s.arprot  <= m_arprot;
    m_axi_m2s.arvalid <= m_arvalid;
    m_axi_m2s.rready  <= m_rready;

    ---------------------------------------------------------------------------
    -- Disassemble master S2M record to flat outputs
    ---------------------------------------------------------------------------
    m_awready <= m_axi_s2m.awready;
    m_wready  <= m_axi_s2m.wready;
    m_bresp   <= m_axi_s2m.bresp;
    m_bvalid  <= m_axi_s2m.bvalid;
    m_arready <= m_axi_s2m.arready;
    m_rdata   <= m_axi_s2m.rdata;
    m_rresp   <= m_axi_s2m.rresp;
    m_rvalid  <= m_axi_s2m.rvalid;

    ---------------------------------------------------------------------------
    -- Assemble slave S2M records from flat inputs
    ---------------------------------------------------------------------------
    -- Slave 0
    s_axi_arr_s2m(0).awready <= s0_awready;
    s_axi_arr_s2m(0).wready  <= s0_wready;
    s_axi_arr_s2m(0).bresp   <= s0_bresp;
    s_axi_arr_s2m(0).bvalid  <= s0_bvalid;
    s_axi_arr_s2m(0).arready <= s0_arready;
    s_axi_arr_s2m(0).rdata   <= s0_rdata;
    s_axi_arr_s2m(0).rresp   <= s0_rresp;
    s_axi_arr_s2m(0).rvalid  <= s0_rvalid;

    -- Slave 1
    s_axi_arr_s2m(1).awready <= s1_awready;
    s_axi_arr_s2m(1).wready  <= s1_wready;
    s_axi_arr_s2m(1).bresp   <= s1_bresp;
    s_axi_arr_s2m(1).bvalid  <= s1_bvalid;
    s_axi_arr_s2m(1).arready <= s1_arready;
    s_axi_arr_s2m(1).rdata   <= s1_rdata;
    s_axi_arr_s2m(1).rresp   <= s1_rresp;
    s_axi_arr_s2m(1).rvalid  <= s1_rvalid;

    -- Slave 2
    s_axi_arr_s2m(2).awready <= s2_awready;
    s_axi_arr_s2m(2).wready  <= s2_wready;
    s_axi_arr_s2m(2).bresp   <= s2_bresp;
    s_axi_arr_s2m(2).bvalid  <= s2_bvalid;
    s_axi_arr_s2m(2).arready <= s2_arready;
    s_axi_arr_s2m(2).rdata   <= s2_rdata;
    s_axi_arr_s2m(2).rresp   <= s2_rresp;
    s_axi_arr_s2m(2).rvalid  <= s2_rvalid;

    ---------------------------------------------------------------------------
    -- Disassemble slave M2S records to flat outputs
    ---------------------------------------------------------------------------
    -- Slave 0
    s0_awaddr  <= s_axi_arr_m2s(0).awaddr;
    s0_awprot  <= s_axi_arr_m2s(0).awprot;
    s0_awvalid <= s_axi_arr_m2s(0).awvalid;
    s0_wdata   <= s_axi_arr_m2s(0).wdata;
    s0_wstrb   <= s_axi_arr_m2s(0).wstrb;
    s0_wvalid  <= s_axi_arr_m2s(0).wvalid;
    s0_bready  <= s_axi_arr_m2s(0).bready;
    s0_araddr  <= s_axi_arr_m2s(0).araddr;
    s0_arprot  <= s_axi_arr_m2s(0).arprot;
    s0_arvalid <= s_axi_arr_m2s(0).arvalid;
    s0_rready  <= s_axi_arr_m2s(0).rready;

    -- Slave 1
    s1_awaddr  <= s_axi_arr_m2s(1).awaddr;
    s1_awprot  <= s_axi_arr_m2s(1).awprot;
    s1_awvalid <= s_axi_arr_m2s(1).awvalid;
    s1_wdata   <= s_axi_arr_m2s(1).wdata;
    s1_wstrb   <= s_axi_arr_m2s(1).wstrb;
    s1_wvalid  <= s_axi_arr_m2s(1).wvalid;
    s1_bready  <= s_axi_arr_m2s(1).bready;
    s1_araddr  <= s_axi_arr_m2s(1).araddr;
    s1_arprot  <= s_axi_arr_m2s(1).arprot;
    s1_arvalid <= s_axi_arr_m2s(1).arvalid;
    s1_rready  <= s_axi_arr_m2s(1).rready;

    -- Slave 2
    s2_awaddr  <= s_axi_arr_m2s(2).awaddr;
    s2_awprot  <= s_axi_arr_m2s(2).awprot;
    s2_awvalid <= s_axi_arr_m2s(2).awvalid;
    s2_wdata   <= s_axi_arr_m2s(2).wdata;
    s2_wstrb   <= s_axi_arr_m2s(2).wstrb;
    s2_wvalid  <= s_axi_arr_m2s(2).wvalid;
    s2_bready  <= s_axi_arr_m2s(2).bready;
    s2_araddr  <= s_axi_arr_m2s(2).araddr;
    s2_arprot  <= s_axi_arr_m2s(2).arprot;
    s2_arvalid <= s_axi_arr_m2s(2).arvalid;
    s2_rready  <= s_axi_arr_m2s(2).rready;

    ---------------------------------------------------------------------------
    -- DUT instantiation
    ---------------------------------------------------------------------------
    u_dut : entity axion_common.axion_axi_lite_bridge
        generic map (
            G_NUM_SLAVES    => 3,
            G_TIMEOUT_WIDTH => G_TIMEOUT_WIDTH
        )
        port map (
            i_clk           => i_clk,
            i_rst_n         => i_rst_n,
            M_AXI_M2S       => m_axi_m2s,
            M_AXI_S2M       => m_axi_s2m,
            S_AXI_ARR_M2S   => s_axi_arr_m2s,
            S_AXI_ARR_S2M   => s_axi_arr_s2m
        );

end architecture rtl;
