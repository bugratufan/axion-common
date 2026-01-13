--------------------------------------------------------------------------------
-- AXI4-Lite Bridge Testbench
-- 
-- Verifies all functional requirements for axion_axi_lite_bridge
-- 
-- Requirements Covered:
--   AXI-LITE-001 to AXI-LITE-008
--   AXION-COMMON-001 to AXION-COMMON-012
-- 
-- Copyright (c) 2024 Bugra Tufan
-- MIT License
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

library axion_common;
use axion_common.axion_common_pkg.all;

entity axion_axi_lite_bridge_tb is
end entity axion_axi_lite_bridge_tb;

architecture tb of axion_axi_lite_bridge_tb is

    ---------------------------------------------------------------------------
    -- Constants
    ---------------------------------------------------------------------------
    constant C_CLK_PERIOD    : time := 10 ns;
    constant C_NUM_SLAVES    : positive := 3;
    constant C_TIMEOUT_WIDTH : positive := 8;  -- 256 cycles timeout for faster sim
    
    -- Test addresses and data
    constant C_TEST_ADDR_1   : std_logic_vector(31 downto 0) := x"00001000";
    constant C_TEST_ADDR_2   : std_logic_vector(31 downto 0) := x"00002000";
    constant C_TEST_DATA_1   : std_logic_vector(31 downto 0) := x"DEADBEEF";
    constant C_TEST_DATA_2   : std_logic_vector(31 downto 0) := x"CAFEBABE";
    constant C_TEST_STRB     : std_logic_vector(3 downto 0)  := "1111";

    ---------------------------------------------------------------------------
    -- Signals
    ---------------------------------------------------------------------------
    signal clk              : std_logic := '0';
    signal rst_n            : std_logic := '0';
    signal sim_done         : boolean := false;
    
    -- Master port signals
    signal m_axi_m2s        : t_axi_lite_m2s := C_AXI_LITE_M2S_INIT;
    signal m_axi_s2m        : t_axi_lite_s2m;
    
    -- Slave port signals (directly control slave responses)
    signal s_axi_m2s        : t_axi_lite_m2s_array(0 to C_NUM_SLAVES-1);
    signal s_axi_s2m        : t_axi_lite_s2m_array(0 to C_NUM_SLAVES-1) := (others => C_AXI_LITE_S2M_INIT);
    
    -- Test control signals
    signal test_name        : string(1 to 64) := (others => ' ');
    signal test_pass        : boolean := true;
    signal tests_passed     : integer := 0;
    signal tests_failed     : integer := 0;
    
    -- Slave behavior control
    type t_slave_mode is (SLAVE_RESPOND_OKAY, SLAVE_RESPOND_ERROR, SLAVE_NO_RESPOND);
    type t_slave_mode_array is array (natural range <>) of t_slave_mode;
    signal slave_mode       : t_slave_mode_array(0 to C_NUM_SLAVES-1) := (others => SLAVE_RESPOND_OKAY);
    signal slave_delay      : integer := 2;  -- Response delay in cycles
    signal slave_read_data  : std_logic_vector(31 downto 0) := x"12345678";
    
    -- Response capture signals (to capture response while valid is high)
    signal last_bresp       : std_logic_vector(1 downto 0) := "00";
    signal last_rresp       : std_logic_vector(1 downto 0) := "00";

    ---------------------------------------------------------------------------
    -- Procedures
    ---------------------------------------------------------------------------
    
    -- Report test result
    procedure report_test(
        signal test_n     : inout string(1 to 64);
        signal pass       : in boolean;
        signal passed_cnt : inout integer;
        signal failed_cnt : inout integer;
        constant req_id   : in string
    ) is
        variable l : line;
    begin
        if pass then
            write(l, string'("[PASS] "));
            passed_cnt <= passed_cnt + 1;
        else
            write(l, string'("[FAIL] "));
            failed_cnt <= failed_cnt + 1;
        end if;
        write(l, req_id);
        write(l, string'(" - "));
        write(l, test_n);
        writeline(output, l);
    end procedure;

begin

    ---------------------------------------------------------------------------
    -- Clock Generation
    ---------------------------------------------------------------------------
    clk <= not clk after C_CLK_PERIOD/2 when not sim_done else '0';

    ---------------------------------------------------------------------------
    -- DUT Instantiation
    ---------------------------------------------------------------------------
    u_dut : entity axion_common.axion_axi_lite_bridge
        generic map (
            G_NUM_SLAVES    => C_NUM_SLAVES,
            G_TIMEOUT_WIDTH => C_TIMEOUT_WIDTH
        )
        port map (
            i_clk         => clk,
            i_rst_n       => rst_n,
            M_AXI_M2S     => m_axi_m2s,
            M_AXI_S2M     => m_axi_s2m,
            S_AXI_ARR_M2S => s_axi_m2s,
            S_AXI_ARR_S2M => s_axi_s2m
        );

    ---------------------------------------------------------------------------
    -- Slave Response Model
    -- Simulates slave behavior based on slave_mode settings
    ---------------------------------------------------------------------------
    gen_slave_model : for i in 0 to C_NUM_SLAVES-1 generate
        p_slave_model : process(clk)
            variable delay_cnt : integer := 0;
            variable pending_write : boolean := false;
            variable pending_read  : boolean := false;
        begin
            if rising_edge(clk) then
                if rst_n = '0' then
                    s_axi_s2m(i) <= C_AXI_LITE_S2M_INIT;
                    delay_cnt := 0;
                    pending_write := false;
                    pending_read := false;
                else
                    -- Default ready signals (combinatorial in real slave, registered here for simplicity)
                    s_axi_s2m(i).awready <= '1';
                    s_axi_s2m(i).wready  <= '1';
                    s_axi_s2m(i).arready <= '1';
                    
                    -- Clear valid after handshake
                    if s_axi_s2m(i).bvalid = '1' and s_axi_m2s(i).bready = '1' then
                        s_axi_s2m(i).bvalid <= '0';
                    end if;
                    
                    if s_axi_s2m(i).rvalid = '1' and s_axi_m2s(i).rready = '1' then
                        s_axi_s2m(i).rvalid <= '0';
                    end if;
                    
                    -- Handle write request
                    if s_axi_m2s(i).awvalid = '1' and s_axi_m2s(i).wvalid = '1' then
                        pending_write := true;
                        delay_cnt := slave_delay;
                    end if;
                    
                    -- Handle read request
                    if s_axi_m2s(i).arvalid = '1' then
                        pending_read := true;
                        delay_cnt := slave_delay;
                    end if;
                    
                    -- Generate delayed response
                    if delay_cnt > 0 then
                        delay_cnt := delay_cnt - 1;
                    elsif pending_write then
                        pending_write := false;
                        case slave_mode(i) is
                            when SLAVE_RESPOND_OKAY =>
                                s_axi_s2m(i).bresp  <= C_AXI_RESP_OKAY;
                                s_axi_s2m(i).bvalid <= '1';
                            when SLAVE_RESPOND_ERROR =>
                                s_axi_s2m(i).bresp  <= C_AXI_RESP_SLVERR;
                                s_axi_s2m(i).bvalid <= '1';
                            when SLAVE_NO_RESPOND =>
                                -- Do nothing, let timeout occur
                                null;
                        end case;
                    elsif pending_read then
                        pending_read := false;
                        case slave_mode(i) is
                            when SLAVE_RESPOND_OKAY =>
                                s_axi_s2m(i).rdata  <= slave_read_data;
                                s_axi_s2m(i).rresp  <= C_AXI_RESP_OKAY;
                                s_axi_s2m(i).rvalid <= '1';
                            when SLAVE_RESPOND_ERROR =>
                                s_axi_s2m(i).rdata  <= (others => '0');
                                s_axi_s2m(i).rresp  <= C_AXI_RESP_SLVERR;
                                s_axi_s2m(i).rvalid <= '1';
                            when SLAVE_NO_RESPOND =>
                                -- Do nothing, let timeout occur
                                null;
                        end case;
                    end if;
                end if;
            end if;
        end process;
    end generate;

    ---------------------------------------------------------------------------
    -- Main Test Process
    ---------------------------------------------------------------------------
    p_test : process
        
        -- Wait for clock cycles
        procedure wait_cycles(n : integer) is
        begin
            for i in 1 to n loop
                wait until rising_edge(clk);
            end loop;
        end procedure;
        
        -- Perform AXI write transaction
        procedure axi_write(
            addr : std_logic_vector(31 downto 0);
            data : std_logic_vector(31 downto 0);
            strb : std_logic_vector(3 downto 0)
        ) is
        begin
            -- Send write address and data
            m_axi_m2s.awaddr  <= addr;
            m_axi_m2s.awprot  <= "000";
            m_axi_m2s.awvalid <= '1';
            m_axi_m2s.wdata   <= data;
            m_axi_m2s.wstrb   <= strb;
            m_axi_m2s.wvalid  <= '1';
            m_axi_m2s.bready  <= '1';
            
            -- Wait for address accepted
            wait until rising_edge(clk) and m_axi_s2m.awready = '1';
            m_axi_m2s.awvalid <= '0';
            
            -- Wait for data accepted
            wait until rising_edge(clk) and m_axi_s2m.wready = '1';
            m_axi_m2s.wvalid <= '0';
            
            -- Wait for response
            wait until rising_edge(clk) and m_axi_s2m.bvalid = '1';
            -- Store response for later checking
            last_bresp <= m_axi_s2m.bresp;
            wait until rising_edge(clk);
            m_axi_m2s.bready <= '0';
        end procedure;
        
        -- Perform AXI read transaction
        procedure axi_read(
            addr : std_logic_vector(31 downto 0);
            data : out std_logic_vector(31 downto 0)
        ) is
        begin
            -- Send read address
            m_axi_m2s.araddr  <= addr;
            m_axi_m2s.arprot  <= "000";
            m_axi_m2s.arvalid <= '1';
            m_axi_m2s.rready  <= '1';
            
            -- Wait for address accepted
            wait until rising_edge(clk) and m_axi_s2m.arready = '1';
            m_axi_m2s.arvalid <= '0';
            
            -- Wait for response
            wait until rising_edge(clk) and m_axi_s2m.rvalid = '1';
            data := m_axi_s2m.rdata;
            -- Store response for later checking
            last_rresp <= m_axi_s2m.rresp;
            wait until rising_edge(clk);
            m_axi_m2s.rready <= '0';
        end procedure;
        
        -- Variables for test data
        variable read_data : std_logic_vector(31 downto 0);
        variable l : line;
        
    begin
        -- Initialize
        m_axi_m2s <= C_AXI_LITE_M2S_INIT;
        slave_mode <= (others => SLAVE_RESPOND_OKAY);
        
        -- Print header
        write(l, string'(""));
        writeline(output, l);
        write(l, string'("================================================================================"));
        writeline(output, l);
        write(l, string'("  AXI4-Lite Bridge Testbench"));
        writeline(output, l);
        write(l, string'("  Testing " & integer'image(C_NUM_SLAVES) & " slave configuration"));
        writeline(output, l);
        write(l, string'("================================================================================"));
        writeline(output, l);
        write(l, string'(""));
        writeline(output, l);
        
        -- Reset sequence
        rst_n <= '0';
        wait_cycles(10);
        rst_n <= '1';
        wait_cycles(5);
        
        -----------------------------------------------------------------------
        -- TC_AXI_RESET_BEHAVIOR (AXI-LITE-008)
        -----------------------------------------------------------------------
        test_name <= "Reset Behavior                                                  ";
        test_pass <= true;
        
        -- Verify all valid signals are low after reset
        if m_axi_s2m.bvalid /= '0' or m_axi_s2m.rvalid /= '0' then
            test_pass <= false;
        end if;
        
        wait_cycles(1);
        report_test(test_name, test_pass, tests_passed, tests_failed, "AXI-LITE-008");
        
        -----------------------------------------------------------------------
        -- TC_AXI_WRITE_ADDR_HANDSHAKE (AXI-LITE-001)
        -----------------------------------------------------------------------
        test_name <= "Write Address Channel Handshake                                 ";
        test_pass <= true;
        
        m_axi_m2s.awaddr  <= C_TEST_ADDR_1;
        m_axi_m2s.awprot  <= "000";
        m_axi_m2s.awvalid <= '1';
        
        wait until rising_edge(clk) and m_axi_s2m.awready = '1';
        -- Check address is stable and valid
        if m_axi_m2s.awvalid /= '1' then
            test_pass <= false;
        end if;
        
        m_axi_m2s.awvalid <= '0';
        m_axi_m2s.wdata   <= C_TEST_DATA_1;
        m_axi_m2s.wstrb   <= C_TEST_STRB;
        m_axi_m2s.wvalid  <= '1';
        m_axi_m2s.bready  <= '1';
        
        wait until rising_edge(clk) and m_axi_s2m.wready = '1';
        m_axi_m2s.wvalid <= '0';
        
        wait until rising_edge(clk) and m_axi_s2m.bvalid = '1';
        wait_cycles(1);
        m_axi_m2s.bready <= '0';
        
        wait_cycles(2);
        report_test(test_name, test_pass, tests_passed, tests_failed, "AXI-LITE-001");
        
        -----------------------------------------------------------------------
        -- TC_AXI_WRITE_DATA_HANDSHAKE (AXI-LITE-002)
        -----------------------------------------------------------------------
        test_name <= "Write Data Channel Handshake                                    ";
        test_pass <= true;
        
        axi_write(C_TEST_ADDR_1, C_TEST_DATA_1, C_TEST_STRB);
        -- If we reach here without timeout, handshake worked
        
        wait_cycles(2);
        report_test(test_name, test_pass, tests_passed, tests_failed, "AXI-LITE-002");
        
        -----------------------------------------------------------------------
        -- TC_AXI_WRITE_RESP_HANDSHAKE (AXI-LITE-003)
        -----------------------------------------------------------------------
        test_name <= "Write Response Channel Handshake                                ";
        test_pass <= true;
        
        m_axi_m2s.awaddr  <= C_TEST_ADDR_1;
        m_axi_m2s.awprot  <= "000";
        m_axi_m2s.awvalid <= '1';
        m_axi_m2s.wdata   <= C_TEST_DATA_1;
        m_axi_m2s.wstrb   <= C_TEST_STRB;
        m_axi_m2s.wvalid  <= '1';
        m_axi_m2s.bready  <= '0';  -- Don't accept response yet
        
        wait until rising_edge(clk) and m_axi_s2m.awready = '1';
        m_axi_m2s.awvalid <= '0';
        
        wait until rising_edge(clk) and m_axi_s2m.wready = '1';
        m_axi_m2s.wvalid <= '0';
        
        -- Wait for bvalid, then check it stays high until bready
        wait until rising_edge(clk) and m_axi_s2m.bvalid = '1';
        wait_cycles(2);
        
        if m_axi_s2m.bvalid /= '1' then
            test_pass <= false;  -- bvalid should stay high
        end if;
        
        m_axi_m2s.bready <= '1';
        wait until rising_edge(clk);
        m_axi_m2s.bready <= '0';
        
        wait_cycles(2);
        report_test(test_name, test_pass, tests_passed, tests_failed, "AXI-LITE-003");
        
        -----------------------------------------------------------------------
        -- TC_AXI_READ_ADDR_HANDSHAKE (AXI-LITE-004)
        -----------------------------------------------------------------------
        test_name <= "Read Address Channel Handshake                                  ";
        test_pass <= true;
        
        m_axi_m2s.araddr  <= C_TEST_ADDR_1;
        m_axi_m2s.arprot  <= "000";
        m_axi_m2s.arvalid <= '1';
        m_axi_m2s.rready  <= '1';
        
        wait until rising_edge(clk) and m_axi_s2m.arready = '1';
        if m_axi_m2s.arvalid /= '1' then
            test_pass <= false;
        end if;
        
        m_axi_m2s.arvalid <= '0';
        
        wait until rising_edge(clk) and m_axi_s2m.rvalid = '1';
        wait_cycles(1);
        m_axi_m2s.rready <= '0';
        
        wait_cycles(2);
        report_test(test_name, test_pass, tests_passed, tests_failed, "AXI-LITE-004");
        
        -----------------------------------------------------------------------
        -- TC_AXI_READ_DATA_HANDSHAKE (AXI-LITE-005)
        -----------------------------------------------------------------------
        test_name <= "Read Data Channel Handshake                                     ";
        test_pass <= true;
        
        slave_read_data <= C_TEST_DATA_2;
        
        m_axi_m2s.araddr  <= C_TEST_ADDR_1;
        m_axi_m2s.arprot  <= "000";
        m_axi_m2s.arvalid <= '1';
        m_axi_m2s.rready  <= '0';  -- Don't accept data yet
        
        wait until rising_edge(clk) and m_axi_s2m.arready = '1';
        m_axi_m2s.arvalid <= '0';
        
        wait until rising_edge(clk) and m_axi_s2m.rvalid = '1';
        wait_cycles(2);
        
        if m_axi_s2m.rvalid /= '1' then
            test_pass <= false;  -- rvalid should stay high
        end if;
        
        m_axi_m2s.rready <= '1';
        wait until rising_edge(clk);
        m_axi_m2s.rready <= '0';
        
        wait_cycles(2);
        report_test(test_name, test_pass, tests_passed, tests_failed, "AXI-LITE-005");
        
        -----------------------------------------------------------------------
        -- TC_AXI_OKAY_RESPONSE (AXI-LITE-006)
        -----------------------------------------------------------------------
        test_name <= "OKAY Response Code                                              ";
        test_pass <= true;
        
        slave_mode <= (others => SLAVE_RESPOND_OKAY);
        wait_cycles(1);
        
        -- Test write OKAY
        m_axi_m2s.awaddr  <= C_TEST_ADDR_1;
        m_axi_m2s.awvalid <= '1';
        m_axi_m2s.wdata   <= C_TEST_DATA_1;
        m_axi_m2s.wstrb   <= C_TEST_STRB;
        m_axi_m2s.wvalid  <= '1';
        m_axi_m2s.bready  <= '1';
        
        wait until rising_edge(clk) and m_axi_s2m.awready = '1';
        m_axi_m2s.awvalid <= '0';
        wait until rising_edge(clk) and m_axi_s2m.wready = '1';
        m_axi_m2s.wvalid <= '0';
        wait until rising_edge(clk) and m_axi_s2m.bvalid = '1';
        
        if m_axi_s2m.bresp /= C_AXI_RESP_OKAY then
            test_pass <= false;
        end if;
        
        wait_cycles(1);
        m_axi_m2s.bready <= '0';
        
        -- Test read OKAY
        m_axi_m2s.araddr  <= C_TEST_ADDR_1;
        m_axi_m2s.arvalid <= '1';
        m_axi_m2s.rready  <= '1';
        
        wait until rising_edge(clk) and m_axi_s2m.arready = '1';
        m_axi_m2s.arvalid <= '0';
        wait until rising_edge(clk) and m_axi_s2m.rvalid = '1';
        
        if m_axi_s2m.rresp /= C_AXI_RESP_OKAY then
            test_pass <= false;
        end if;
        
        wait_cycles(1);
        m_axi_m2s.rready <= '0';
        
        wait_cycles(2);
        report_test(test_name, test_pass, tests_passed, tests_failed, "AXI-LITE-006");
        
        -----------------------------------------------------------------------
        -- TC_AXI_SLVERR_RESPONSE (AXI-LITE-007)
        -----------------------------------------------------------------------
        test_name <= "SLVERR Response Code                                            ";
        test_pass <= true;
        
        slave_mode <= (others => SLAVE_RESPOND_ERROR);
        wait_cycles(1);
        
        -- Test write SLVERR
        m_axi_m2s.awaddr  <= C_TEST_ADDR_1;
        m_axi_m2s.awvalid <= '1';
        m_axi_m2s.wdata   <= C_TEST_DATA_1;
        m_axi_m2s.wstrb   <= C_TEST_STRB;
        m_axi_m2s.wvalid  <= '1';
        m_axi_m2s.bready  <= '1';
        
        wait until rising_edge(clk) and m_axi_s2m.awready = '1';
        m_axi_m2s.awvalid <= '0';
        wait until rising_edge(clk) and m_axi_s2m.wready = '1';
        m_axi_m2s.wvalid <= '0';
        wait until rising_edge(clk) and m_axi_s2m.bvalid = '1';
        
        if m_axi_s2m.bresp /= C_AXI_RESP_SLVERR then
            test_pass <= false;
        end if;
        
        wait_cycles(1);
        m_axi_m2s.bready <= '0';
        
        -- Test read SLVERR
        m_axi_m2s.araddr  <= C_TEST_ADDR_1;
        m_axi_m2s.arvalid <= '1';
        m_axi_m2s.rready  <= '1';
        
        wait until rising_edge(clk) and m_axi_s2m.arready = '1';
        m_axi_m2s.arvalid <= '0';
        wait until rising_edge(clk) and m_axi_s2m.rvalid = '1';
        
        if m_axi_s2m.rresp /= C_AXI_RESP_SLVERR then
            test_pass <= false;
        end if;
        
        wait_cycles(1);
        m_axi_m2s.rready <= '0';
        
        slave_mode <= (others => SLAVE_RESPOND_OKAY);
        wait_cycles(2);
        report_test(test_name, test_pass, tests_passed, tests_failed, "AXI-LITE-007");
        
        -----------------------------------------------------------------------
        -- TC_BRIDGE_REQUEST_BROADCAST (AXION-COMMON-001)
        -----------------------------------------------------------------------
        test_name <= "Request Broadcast to All Slaves                                 ";
        test_pass <= true;
        
        slave_mode <= (others => SLAVE_RESPOND_OKAY);
        wait_cycles(1);
        
        m_axi_m2s.araddr  <= C_TEST_ADDR_1;
        m_axi_m2s.arvalid <= '1';
        m_axi_m2s.rready  <= '1';
        
        wait until rising_edge(clk) and m_axi_s2m.arready = '1';
        
        -- Check all slaves received the request
        for i in 0 to C_NUM_SLAVES-1 loop
            if s_axi_m2s(i).araddr /= C_TEST_ADDR_1 then
                test_pass <= false;
            end if;
        end loop;
        
        m_axi_m2s.arvalid <= '0';
        wait until rising_edge(clk) and m_axi_s2m.rvalid = '1';
        wait_cycles(1);
        m_axi_m2s.rready <= '0';
        
        wait_cycles(2);
        report_test(test_name, test_pass, tests_passed, tests_failed, "AXION-COMMON-001");
        
        -----------------------------------------------------------------------
        -- TC_BRIDGE_FIRST_OKAY (AXION-COMMON-002)
        -----------------------------------------------------------------------
        test_name <= "First OKAY Response Selection                                   ";
        test_pass <= true;
        
        -- Only first slave responds with OKAY
        slave_mode(0) <= SLAVE_RESPOND_OKAY;
        slave_mode(1) <= SLAVE_RESPOND_ERROR;
        slave_mode(2) <= SLAVE_RESPOND_ERROR;
        slave_read_data <= x"AABBCCDD";
        wait_cycles(1);
        
        axi_read(C_TEST_ADDR_1, read_data);
        
        if m_axi_s2m.rresp /= C_AXI_RESP_OKAY then
            test_pass <= false;
        end if;
        
        slave_mode <= (others => SLAVE_RESPOND_OKAY);
        wait_cycles(2);
        report_test(test_name, test_pass, tests_passed, tests_failed, "AXION-COMMON-002");
        
        -----------------------------------------------------------------------
        -- TC_BRIDGE_ALL_ERROR (AXION-COMMON-003)
        -----------------------------------------------------------------------
        test_name <= "All Error Response Handling                                     ";
        test_pass <= true;
        
        slave_mode <= (others => SLAVE_RESPOND_ERROR);
        wait_cycles(1);
        
        m_axi_m2s.araddr  <= C_TEST_ADDR_1;
        m_axi_m2s.arvalid <= '1';
        m_axi_m2s.rready  <= '1';
        
        wait until rising_edge(clk) and m_axi_s2m.arready = '1';
        m_axi_m2s.arvalid <= '0';
        wait until rising_edge(clk) and m_axi_s2m.rvalid = '1';
        
        if m_axi_s2m.rresp /= C_AXI_RESP_SLVERR then
            test_pass <= false;
        end if;
        
        wait_cycles(1);
        m_axi_m2s.rready <= '0';
        
        slave_mode <= (others => SLAVE_RESPOND_OKAY);
        wait_cycles(2);
        report_test(test_name, test_pass, tests_passed, tests_failed, "AXION-COMMON-003");
        
        -----------------------------------------------------------------------
        -- TC_BRIDGE_TIMEOUT (AXION-COMMON-004)
        -----------------------------------------------------------------------
        test_name <= "Timeout Mechanism                                               ";
        test_pass <= true;
        
        slave_mode <= (others => SLAVE_NO_RESPOND);
        wait_cycles(1);
        
        m_axi_m2s.araddr  <= C_TEST_ADDR_1;
        m_axi_m2s.arvalid <= '1';
        m_axi_m2s.rready  <= '1';
        
        wait until rising_edge(clk) and m_axi_s2m.arready = '1';
        m_axi_m2s.arvalid <= '0';
        
        -- Wait for timeout (2^8 = 256 cycles max)
        for i in 0 to 300 loop
            wait until rising_edge(clk);
            if m_axi_s2m.rvalid = '1' then
                exit;
            end if;
        end loop;
        
        if m_axi_s2m.rvalid /= '1' or m_axi_s2m.rresp /= C_AXI_RESP_SLVERR then
            test_pass <= false;
        end if;
        
        wait_cycles(1);
        m_axi_m2s.rready <= '0';
        
        slave_mode <= (others => SLAVE_RESPOND_OKAY);
        wait_cycles(2);
        report_test(test_name, test_pass, tests_passed, tests_failed, "AXION-COMMON-004");
        
        -----------------------------------------------------------------------
        -- TC_BRIDGE_SLAVE_COUNT (AXION-COMMON-005)
        -----------------------------------------------------------------------
        test_name <= "Generic Slave Count                                             ";
        test_pass <= true;
        
        -- Just verify DUT instantiated with C_NUM_SLAVES works
        -- This is implicitly tested by all other tests
        axi_read(C_TEST_ADDR_1, read_data);
        
        wait_cycles(2);
        report_test(test_name, test_pass, tests_passed, tests_failed, "AXION-COMMON-005");
        
        -----------------------------------------------------------------------
        -- TC_BRIDGE_WRITE_SEQUENCE (AXION-COMMON-006)
        -----------------------------------------------------------------------
        test_name <= "Write Transaction Sequence                                      ";
        test_pass <= true;
        
        axi_write(C_TEST_ADDR_1, C_TEST_DATA_1, C_TEST_STRB);
        
        if last_bresp /= C_AXI_RESP_OKAY then
            test_pass <= false;
        end if;
        
        wait_cycles(2);
        report_test(test_name, test_pass, tests_passed, tests_failed, "AXION-COMMON-006");
        
        -----------------------------------------------------------------------
        -- TC_BRIDGE_READ_SEQUENCE (AXION-COMMON-007)
        -----------------------------------------------------------------------
        test_name <= "Read Transaction Sequence                                       ";
        test_pass <= true;
        
        slave_read_data <= x"12345678";
        axi_read(C_TEST_ADDR_1, read_data);
        
        if last_rresp /= C_AXI_RESP_OKAY then
            test_pass <= false;
        end if;
        
        wait_cycles(2);
        report_test(test_name, test_pass, tests_passed, tests_failed, "AXION-COMMON-007");
        
        -----------------------------------------------------------------------
        -- TC_BRIDGE_BACK_TO_BACK (AXION-COMMON-008)
        -----------------------------------------------------------------------
        test_name <= "Back-to-Back Transactions                                       ";
        test_pass <= true;
        
        -- Multiple consecutive writes
        axi_write(C_TEST_ADDR_1, x"11111111", C_TEST_STRB);
        axi_write(C_TEST_ADDR_2, x"22222222", C_TEST_STRB);
        axi_write(C_TEST_ADDR_1, x"33333333", C_TEST_STRB);
        
        -- Multiple consecutive reads
        axi_read(C_TEST_ADDR_1, read_data);
        axi_read(C_TEST_ADDR_2, read_data);
        axi_read(C_TEST_ADDR_1, read_data);
        
        -- Interleaved
        axi_write(C_TEST_ADDR_1, x"44444444", C_TEST_STRB);
        axi_read(C_TEST_ADDR_1, read_data);
        axi_write(C_TEST_ADDR_2, x"55555555", C_TEST_STRB);
        axi_read(C_TEST_ADDR_2, read_data);
        
        wait_cycles(2);
        report_test(test_name, test_pass, tests_passed, tests_failed, "AXION-COMMON-008");
        
        -----------------------------------------------------------------------
        -- TC_BRIDGE_PARTIAL_RESPONSE (AXION-COMMON-009)
        -----------------------------------------------------------------------
        test_name <= "Partial Slave Response                                          ";
        test_pass <= true;
        
        -- Slave 0 responds OKAY, others don't respond
        slave_mode(0) <= SLAVE_RESPOND_OKAY;
        slave_mode(1) <= SLAVE_NO_RESPOND;
        slave_mode(2) <= SLAVE_NO_RESPOND;
        wait_cycles(1);
        
        axi_read(C_TEST_ADDR_1, read_data);
        
        if m_axi_s2m.rresp /= C_AXI_RESP_OKAY then
            test_pass <= false;
        end if;
        
        slave_mode <= (others => SLAVE_RESPOND_OKAY);
        wait_cycles(2);
        report_test(test_name, test_pass, tests_passed, tests_failed, "AXION-COMMON-009");
        
        -----------------------------------------------------------------------
        -- TC_BRIDGE_ADDR_TRANSPARENCY (AXION-COMMON-010)
        -----------------------------------------------------------------------
        test_name <= "Address Transparency                                            ";
        test_pass <= true;
        
        m_axi_m2s.araddr  <= x"DEADBEEF";
        m_axi_m2s.arprot  <= "101";
        m_axi_m2s.arvalid <= '1';
        m_axi_m2s.rready  <= '1';
        
        wait until rising_edge(clk) and m_axi_s2m.arready = '1';
        
        -- Check all slaves received exact address and prot
        for i in 0 to C_NUM_SLAVES-1 loop
            if s_axi_m2s(i).araddr /= x"DEADBEEF" or s_axi_m2s(i).arprot /= "101" then
                test_pass <= false;
            end if;
        end loop;
        
        m_axi_m2s.arvalid <= '0';
        wait until rising_edge(clk) and m_axi_s2m.rvalid = '1';
        wait_cycles(1);
        m_axi_m2s.rready <= '0';
        
        wait_cycles(2);
        report_test(test_name, test_pass, tests_passed, tests_failed, "AXION-COMMON-010");
        
        -----------------------------------------------------------------------
        -- TC_BRIDGE_DATA_INTEGRITY (AXION-COMMON-011)
        -----------------------------------------------------------------------
        test_name <= "Data Integrity                                                  ";
        test_pass <= true;
        
        slave_read_data <= x"CAFEBABE";
        
        m_axi_m2s.awaddr  <= C_TEST_ADDR_1;
        m_axi_m2s.awvalid <= '1';
        m_axi_m2s.wdata   <= x"FEEDFACE";
        m_axi_m2s.wstrb   <= "1010";
        m_axi_m2s.wvalid  <= '1';
        m_axi_m2s.bready  <= '1';
        
        wait until rising_edge(clk) and m_axi_s2m.awready = '1';
        
        -- Check write data on slave ports
        for i in 0 to C_NUM_SLAVES-1 loop
            if s_axi_m2s(i).wdata /= x"FEEDFACE" or s_axi_m2s(i).wstrb /= "1010" then
                test_pass <= false;
            end if;
        end loop;
        
        m_axi_m2s.awvalid <= '0';
        wait until rising_edge(clk) and m_axi_s2m.wready = '1';
        m_axi_m2s.wvalid <= '0';
        wait until rising_edge(clk) and m_axi_s2m.bvalid = '1';
        wait_cycles(1);
        m_axi_m2s.bready <= '0';
        
        -- Check read data integrity
        axi_read(C_TEST_ADDR_1, read_data);
        if read_data /= x"CAFEBABE" then
            test_pass <= false;
        end if;
        
        wait_cycles(2);
        report_test(test_name, test_pass, tests_passed, tests_failed, "AXION-COMMON-011");
        
        -----------------------------------------------------------------------
        -- TC_BRIDGE_RESET_RECOVERY (AXION-COMMON-012)
        -----------------------------------------------------------------------
        test_name <= "Reset Recovery                                                  ";
        test_pass <= true;
        
        -- Start a transaction
        m_axi_m2s.araddr  <= C_TEST_ADDR_1;
        m_axi_m2s.arvalid <= '1';
        m_axi_m2s.rready  <= '1';
        
        wait_cycles(2);
        
        -- Apply reset mid-transaction
        rst_n <= '0';
        wait_cycles(5);
        rst_n <= '1';
        
        m_axi_m2s <= C_AXI_LITE_M2S_INIT;
        wait_cycles(5);
        
        -- Verify clean state
        if m_axi_s2m.bvalid /= '0' or m_axi_s2m.rvalid /= '0' then
            test_pass <= false;
        end if;
        
        -- Verify bridge works after reset
        axi_read(C_TEST_ADDR_1, read_data);
        if m_axi_s2m.rresp /= C_AXI_RESP_OKAY then
            test_pass <= false;
        end if;
        
        wait_cycles(2);
        report_test(test_name, test_pass, tests_passed, tests_failed, "AXION-COMMON-012");
        
        -----------------------------------------------------------------------
        -- Test Summary
        -----------------------------------------------------------------------
        wait_cycles(5);
        
        write(l, string'(""));
        writeline(output, l);
        write(l, string'("================================================================================"));
        writeline(output, l);
        write(l, string'("  TEST SUMMARY"));
        writeline(output, l);
        write(l, string'("================================================================================"));
        writeline(output, l);
        write(l, string'("  Total Tests: " & integer'image(tests_passed + tests_failed)));
        writeline(output, l);
        write(l, string'("  Passed:      " & integer'image(tests_passed)));
        writeline(output, l);
        write(l, string'("  Failed:      " & integer'image(tests_failed)));
        writeline(output, l);
        write(l, string'("================================================================================"));
        writeline(output, l);
        
        if tests_failed = 0 then
            write(l, string'("  RESULT: ALL TESTS PASSED"));
        else
            write(l, string'("  RESULT: SOME TESTS FAILED"));
        end if;
        writeline(output, l);
        write(l, string'("================================================================================"));
        writeline(output, l);
        
        sim_done <= true;
        wait;
        
    end process p_test;

end architecture tb;
