--------------------------------------------------------------------------------
-- Axion Common Package
-- 
-- AXI4-Lite bus type definitions and utility functions
-- 
-- Copyright (c) 2024 Bugra Tufan
-- MIT License
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package axion_common_pkg is

    ---------------------------------------------------------------------------
    -- AXI4-Lite Constants
    ---------------------------------------------------------------------------
    constant C_AXI_DATA_WIDTH : integer := 32;
    constant C_AXI_ADDR_WIDTH : integer := 32;
    constant C_AXI_STRB_WIDTH : integer := C_AXI_DATA_WIDTH / 8;

    -- AXI Response codes
    constant C_AXI_RESP_OKAY   : std_logic_vector(1 downto 0) := "00";
    constant C_AXI_RESP_EXOKAY : std_logic_vector(1 downto 0) := "01";
    constant C_AXI_RESP_SLVERR : std_logic_vector(1 downto 0) := "10";
    constant C_AXI_RESP_DECERR : std_logic_vector(1 downto 0) := "11";

    ---------------------------------------------------------------------------
    -- AXI4-Lite Master to Slave signals (M2S)
    -- Signals driven by master, received by slave
    ---------------------------------------------------------------------------
    type t_axi_lite_m2s is record
        -- Write Address Channel
        awaddr  : std_logic_vector(C_AXI_ADDR_WIDTH-1 downto 0);
        awvalid : std_logic;
        awprot  : std_logic_vector(2 downto 0);
        
        -- Write Data Channel
        wdata   : std_logic_vector(C_AXI_DATA_WIDTH-1 downto 0);
        wstrb   : std_logic_vector(C_AXI_STRB_WIDTH-1 downto 0);
        wvalid  : std_logic;
        
        -- Write Response Channel
        bready  : std_logic;
        
        -- Read Address Channel
        araddr  : std_logic_vector(C_AXI_ADDR_WIDTH-1 downto 0);
        arvalid : std_logic;
        arprot  : std_logic_vector(2 downto 0);
        
        -- Read Data Channel
        rready  : std_logic;
    end record t_axi_lite_m2s;

    ---------------------------------------------------------------------------
    -- AXI4-Lite Slave to Master signals (S2M)
    -- Signals driven by slave, received by master
    ---------------------------------------------------------------------------
    type t_axi_lite_s2m is record
        -- Write Address Channel
        awready : std_logic;
        
        -- Write Data Channel
        wready  : std_logic;
        
        -- Write Response Channel
        bresp   : std_logic_vector(1 downto 0);
        bvalid  : std_logic;
        
        -- Read Address Channel
        arready : std_logic;
        
        -- Read Data Channel
        rdata   : std_logic_vector(C_AXI_DATA_WIDTH-1 downto 0);
        rresp   : std_logic_vector(1 downto 0);
        rvalid  : std_logic;
    end record t_axi_lite_s2m;

    ---------------------------------------------------------------------------
    -- Array types for multiple slaves/masters
    ---------------------------------------------------------------------------
    type t_axi_lite_m2s_array is array (natural range <>) of t_axi_lite_m2s;
    type t_axi_lite_s2m_array is array (natural range <>) of t_axi_lite_s2m;

    ---------------------------------------------------------------------------
    -- Initial/Default values
    ---------------------------------------------------------------------------
    constant C_AXI_LITE_M2S_INIT : t_axi_lite_m2s := (
        awaddr  => (others => '0'),
        awvalid => '0',
        awprot  => (others => '0'),
        wdata   => (others => '0'),
        wstrb   => (others => '0'),
        wvalid  => '0',
        bready  => '0',
        araddr  => (others => '0'),
        arvalid => '0',
        arprot  => (others => '0'),
        rready  => '0'
    );

    constant C_AXI_LITE_S2M_INIT : t_axi_lite_s2m := (
        awready => '0',
        wready  => '0',
        bresp   => C_AXI_RESP_OKAY,
        bvalid  => '0',
        arready => '0',
        rdata   => (others => '0'),
        rresp   => C_AXI_RESP_OKAY,
        rvalid  => '0'
    );

    ---------------------------------------------------------------------------
    -- Utility Functions
    ---------------------------------------------------------------------------
    
    -- Check if AXI response is OK
    function f_axi_resp_is_ok(resp : std_logic_vector(1 downto 0)) return boolean;
    
    -- Check if AXI response is error
    function f_axi_resp_is_error(resp : std_logic_vector(1 downto 0)) return boolean;

end package axion_common_pkg;

package body axion_common_pkg is

    function f_axi_resp_is_ok(resp : std_logic_vector(1 downto 0)) return boolean is
    begin
        return (resp = C_AXI_RESP_OKAY) or (resp = C_AXI_RESP_EXOKAY);
    end function;

    function f_axi_resp_is_error(resp : std_logic_vector(1 downto 0)) return boolean is
    begin
        return (resp = C_AXI_RESP_SLVERR) or (resp = C_AXI_RESP_DECERR);
    end function;

end package body axion_common_pkg;
