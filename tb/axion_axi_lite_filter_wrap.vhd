--------------------------------------------------------------------------------
-- AXI4-Lite Filter + Register Cocotb Wrapper
--
-- Instantiates axion_axi_lite_filter followed by axi_test_axion_reg so that
-- the register file is the downstream slave.  Only master-side flat signals
-- and register-output signals are exposed to cocotb; the filter<->register
-- connection is internal.
--
-- Address map used by the test suite:
--   Filter window : G_ADDR_BEGIN_INT .. G_ADDR_END_INT
--                   (default 0x4000 .. 0x4FFF)
--   Reg BASE_ADDR : 0x4000
--     0x4000 : version  (RW, reset = 0xABCDEF01)
--     0x4004 : val      (RW, reset = 0xDEADBEEF)
--   0x4008..0x4FFF : in filter range but outside register map -> reg SLVERR
--   < 0x4000 or > 0x4FFF : outside filter window -> filter SLVERR
--
-- Copyright (c) 2024 Bugra Tufan
-- MIT License
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library axion_common;
use axion_common.axion_common_pkg.all;

entity axion_axi_lite_filter_wrap is
    generic (
        G_ADDR_BEGIN_INT : natural := 16#00004000#;
        G_ADDR_END_INT   : natural := 16#00004FFF#
    );
    port (
        i_clk       : in  std_logic;
        i_rst_n     : in  std_logic;

        -- ----------------------------------------------------------------
        -- Upstream (master-side) flat signals
        -- ----------------------------------------------------------------
        m_awaddr    : in  std_logic_vector(31 downto 0);
        m_awprot    : in  std_logic_vector(2 downto 0);
        m_awvalid   : in  std_logic;
        m_awready   : out std_logic;

        m_wdata     : in  std_logic_vector(31 downto 0);
        m_wstrb     : in  std_logic_vector(3 downto 0);
        m_wvalid    : in  std_logic;
        m_wready    : out std_logic;

        m_bresp     : out std_logic_vector(1 downto 0);
        m_bvalid    : out std_logic;
        m_bready    : in  std_logic;

        m_araddr    : in  std_logic_vector(31 downto 0);
        m_arprot    : in  std_logic_vector(2 downto 0);
        m_arvalid   : in  std_logic;
        m_arready   : out std_logic;

        m_rdata     : out std_logic_vector(31 downto 0);
        m_rresp     : out std_logic_vector(1 downto 0);
        m_rvalid    : out std_logic;
        m_rready    : in  std_logic;

        -- ----------------------------------------------------------------
        -- Register outputs (for cocotb to verify register state)
        -- ----------------------------------------------------------------
        reg_version : out std_logic_vector(31 downto 0);
        reg_val     : out std_logic_vector(31 downto 0)
    );
end entity axion_axi_lite_filter_wrap;

architecture rtl of axion_axi_lite_filter_wrap is

    -- Internal record buses
    signal up_m2s       : t_axi_lite_m2s;
    signal up_s2m       : t_axi_lite_s2m;
    signal mid_m2s      : t_axi_lite_m2s;  -- filter DN = register UP
    signal mid_s2m      : t_axi_lite_s2m;

begin

    ---------------------------------------------------------------------------
    -- Assemble upstream M2S from flat inputs
    ---------------------------------------------------------------------------
    up_m2s.awaddr  <= m_awaddr;
    up_m2s.awprot  <= m_awprot;
    up_m2s.awvalid <= m_awvalid;
    up_m2s.wdata   <= m_wdata;
    up_m2s.wstrb   <= m_wstrb;
    up_m2s.wvalid  <= m_wvalid;
    up_m2s.bready  <= m_bready;
    up_m2s.araddr  <= m_araddr;
    up_m2s.arprot  <= m_arprot;
    up_m2s.arvalid <= m_arvalid;
    up_m2s.rready  <= m_rready;

    ---------------------------------------------------------------------------
    -- Disassemble upstream S2M to flat outputs
    ---------------------------------------------------------------------------
    m_awready <= up_s2m.awready;
    m_wready  <= up_s2m.wready;
    m_bresp   <= up_s2m.bresp;
    m_bvalid  <= up_s2m.bvalid;
    m_arready <= up_s2m.arready;
    m_rdata   <= up_s2m.rdata;
    m_rresp   <= up_s2m.rresp;
    m_rvalid  <= up_s2m.rvalid;

    ---------------------------------------------------------------------------
    -- Filter DUT
    ---------------------------------------------------------------------------
    u_filter : entity axion_common.axion_axi_lite_filter
        generic map (
            G_ADDR_BEGIN => std_logic_vector(to_unsigned(G_ADDR_BEGIN_INT, 32)),
            G_ADDR_END   => std_logic_vector(to_unsigned(G_ADDR_END_INT,   32))
        )
        port map (
            i_clk   => i_clk,
            i_rst_n => i_rst_n,
            UP_M2S  => up_m2s,
            UP_S2M  => up_s2m,
            DN_M2S  => mid_m2s,
            DN_S2M  => mid_s2m
        );

    ---------------------------------------------------------------------------
    -- Register slave (downstream of filter)
    ---------------------------------------------------------------------------
    u_reg : entity axion_common.axi_test_axion_reg
        generic map (
            BASE_ADDR => x"00004000"
        )
        port map (
            axi_aclk    => i_clk,
            axi_aresetn => i_rst_n,
            axi_m2s     => mid_m2s,
            axi_s2m     => mid_s2m,
            version     => reg_version,
            val         => reg_val
        );

end architecture rtl;
