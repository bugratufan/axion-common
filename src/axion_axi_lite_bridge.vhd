--------------------------------------------------------------------------------
-- AXI4-Lite Bridge
-- 
-- Bridges a single AXI4-Lite master to multiple AXI4-Lite slaves.
-- Routes requests to all slaves and returns the first valid response.
-- 
-- Features:
--   - Generic number of slave ports
--   - Configurable address ranges per slave
--   - Timeout mechanism for unresponsive slaves
--   - Returns SLVERR if no slave responds or all respond with error
-- 
-- Operation:
--   1. Master sends request (read or write)
--   2. Bridge forwards request to all slaves
--   3. Bridge waits for response from any slave
--   4. First OKAY response is returned to master
--   5. If all slaves return error or timeout, SLVERR is returned
-- 
-- Copyright (c) 2024 Bugra Tufan
-- MIT License
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.axion_common_pkg.all;

entity axion_axi_lite_bridge is
    generic (
        -- Number of slave ports
        G_NUM_SLAVES     : positive := 2;
        
        -- Timeout counter width (timeout = 2^G_TIMEOUT_WIDTH cycles)
        G_TIMEOUT_WIDTH  : positive := 16
    );
    port (
        -- Clock and Reset
        i_clk            : in  std_logic;
        i_rst_n          : in  std_logic;
        
        -- AXI4-Lite Master Port (Upstream - connects to master)
        M_AXI_M2S        : in  t_axi_lite_m2s;
        M_AXI_S2M        : out t_axi_lite_s2m;
        
        -- AXI4-Lite Slave Ports (Downstream - connects to slaves)
        S_AXI_ARR_M2S    : out t_axi_lite_m2s_array(0 to G_NUM_SLAVES-1);
        S_AXI_ARR_S2M    : in  t_axi_lite_s2m_array(0 to G_NUM_SLAVES-1)
    );
end entity axion_axi_lite_bridge;

architecture rtl of axion_axi_lite_bridge is

    ---------------------------------------------------------------------------
    -- Types
    ---------------------------------------------------------------------------
    type t_state is (
        ST_IDLE,
        ST_WRITE_ADDR,
        ST_WRITE_DATA,
        ST_WRITE_RESP,
        ST_WRITE_COMPLETE,
        ST_READ_ADDR,
        ST_READ_RESP,
        ST_READ_COMPLETE
    );

    ---------------------------------------------------------------------------
    -- Signals
    ---------------------------------------------------------------------------
    signal state            : t_state;
    signal timeout_cnt      : unsigned(G_TIMEOUT_WIDTH-1 downto 0);
    signal timeout_flag     : std_logic;
    
    -- Registered master inputs
    signal m_awaddr_reg     : std_logic_vector(C_AXI_ADDR_WIDTH-1 downto 0);
    signal m_awprot_reg     : std_logic_vector(2 downto 0);
    signal m_wdata_reg      : std_logic_vector(C_AXI_DATA_WIDTH-1 downto 0);
    signal m_wstrb_reg      : std_logic_vector(C_AXI_STRB_WIDTH-1 downto 0);
    signal m_araddr_reg     : std_logic_vector(C_AXI_ADDR_WIDTH-1 downto 0);
    signal m_arprot_reg     : std_logic_vector(2 downto 0);
    
    -- Response tracking
    signal resp_received    : std_logic_vector(G_NUM_SLAVES-1 downto 0);
    signal resp_ok_found    : std_logic;
    signal resp_ok_index    : integer range 0 to G_NUM_SLAVES-1;
    
    -- Output registers
    signal m_axi_out        : t_axi_lite_s2m;
    signal s_axi_out        : t_axi_lite_m2s_array(0 to G_NUM_SLAVES-1);

begin

    ---------------------------------------------------------------------------
    -- Main State Machine
    ---------------------------------------------------------------------------
    p_fsm : process(i_clk)
        variable v_all_resp_received : std_logic;
        variable v_any_ok            : std_logic;
        variable v_ok_index          : integer range 0 to G_NUM_SLAVES-1;
    begin
        if rising_edge(i_clk) then
            if i_rst_n = '0' then
                state           <= ST_IDLE;
                timeout_cnt     <= (others => '0');
                timeout_flag    <= '0';
                resp_received   <= (others => '0');
                resp_ok_found   <= '0';
                resp_ok_index   <= 0;
                m_awaddr_reg    <= (others => '0');
                m_awprot_reg    <= (others => '0');
                m_wdata_reg     <= (others => '0');
                m_wstrb_reg     <= (others => '0');
                m_araddr_reg    <= (others => '0');
                m_arprot_reg    <= (others => '0');
                m_axi_out       <= C_AXI_LITE_S2M_INIT;
                
                for i in 0 to G_NUM_SLAVES-1 loop
                    s_axi_out(i) <= C_AXI_LITE_M2S_INIT;
                end loop;
                
            else
                -- Default: clear single-cycle signals
                m_axi_out.awready <= '0';
                m_axi_out.wready  <= '0';
                m_axi_out.arready <= '0';
                
                -- Timeout counter
                if state /= ST_IDLE then
                    if timeout_cnt = (timeout_cnt'range => '1') then
                        timeout_flag <= '1';
                    else
                        timeout_cnt <= timeout_cnt + 1;
                    end if;
                else
                    timeout_cnt  <= (others => '0');
                    timeout_flag <= '0';
                end if;

                case state is
                    -----------------------------------------------------------
                    -- IDLE: Wait for master request
                    -----------------------------------------------------------
                    when ST_IDLE =>
                        m_axi_out.bvalid <= '0';
                        m_axi_out.rvalid <= '0';
                        resp_received    <= (others => '0');
                        resp_ok_found    <= '0';
                        timeout_cnt      <= (others => '0');
                        timeout_flag     <= '0';
                        
                        -- Clear slave outputs
                        for i in 0 to G_NUM_SLAVES-1 loop
                            s_axi_out(i).awvalid <= '0';
                            s_axi_out(i).wvalid  <= '0';
                            s_axi_out(i).arvalid <= '0';
                            s_axi_out(i).bready  <= '0';
                            s_axi_out(i).rready  <= '0';
                        end loop;
                        
                        -- Check for write request
                        if M_AXI_M2S.awvalid = '1' then
                            -- Register write address
                            m_awaddr_reg        <= M_AXI_M2S.awaddr;
                            m_awprot_reg        <= M_AXI_M2S.awprot;
                            m_axi_out.awready   <= '1';
                            
                            -- Forward to all slaves
                            for i in 0 to G_NUM_SLAVES-1 loop
                                s_axi_out(i).awaddr  <= M_AXI_M2S.awaddr;
                                s_axi_out(i).awprot  <= M_AXI_M2S.awprot;
                                s_axi_out(i).awvalid <= '1';
                                -- Also forward write data if available
                                if M_AXI_M2S.wvalid = '1' then
                                    s_axi_out(i).wdata  <= M_AXI_M2S.wdata;
                                    s_axi_out(i).wstrb  <= M_AXI_M2S.wstrb;
                                    s_axi_out(i).wvalid <= '1';
                                    s_axi_out(i).bready <= '1';
                                end if;
                            end loop;
                            
                            -- If write data is also valid, register it
                            if M_AXI_M2S.wvalid = '1' then
                                m_wdata_reg       <= M_AXI_M2S.wdata;
                                m_wstrb_reg       <= M_AXI_M2S.wstrb;
                                m_axi_out.wready  <= '1';
                            end if;
                            
                            state <= ST_WRITE_ADDR;
                            
                        -- Check for read request
                        elsif M_AXI_M2S.arvalid = '1' then
                            -- Register read address
                            m_araddr_reg        <= M_AXI_M2S.araddr;
                            m_arprot_reg        <= M_AXI_M2S.arprot;
                            m_axi_out.arready   <= '1';
                            
                            -- Forward to all slaves
                            for i in 0 to G_NUM_SLAVES-1 loop
                                s_axi_out(i).araddr  <= M_AXI_M2S.araddr;
                                s_axi_out(i).arprot  <= M_AXI_M2S.arprot;
                                s_axi_out(i).arvalid <= '1';
                                s_axi_out(i).rready  <= '1';
                            end loop;
                            
                            state <= ST_READ_ADDR;
                        end if;

                    -----------------------------------------------------------
                    -- WRITE_ADDR: Wait for slave awready, then send data
                    -----------------------------------------------------------
                    when ST_WRITE_ADDR =>
                        -- Check which slaves accepted address
                        for i in 0 to G_NUM_SLAVES-1 loop
                            if S_AXI_ARR_S2M(i).awready = '1' then
                                s_axi_out(i).awvalid <= '0';
                            end if;
                        end loop;
                        
                        -- Check if master has write data ready
                        if M_AXI_M2S.wvalid = '1' then
                            m_wdata_reg       <= M_AXI_M2S.wdata;
                            m_wstrb_reg       <= M_AXI_M2S.wstrb;
                            m_axi_out.wready  <= '1';
                            
                            -- Forward write data to all slaves
                            for i in 0 to G_NUM_SLAVES-1 loop
                                s_axi_out(i).wdata  <= M_AXI_M2S.wdata;
                                s_axi_out(i).wstrb  <= M_AXI_M2S.wstrb;
                                s_axi_out(i).wvalid <= '1';
                                s_axi_out(i).bready <= '1';
                            end loop;
                            
                            state <= ST_WRITE_DATA;
                        end if;
                        
                        -- Timeout handling
                        if timeout_flag = '1' then
                            m_axi_out.bresp  <= C_AXI_RESP_SLVERR;
                            m_axi_out.bvalid <= '1';
                            state <= ST_IDLE;
                        end if;

                    -----------------------------------------------------------
                    -- WRITE_DATA: Wait for slave wready
                    -----------------------------------------------------------
                    when ST_WRITE_DATA =>
                        -- Check which slaves accepted data
                        for i in 0 to G_NUM_SLAVES-1 loop
                            if S_AXI_ARR_S2M(i).wready = '1' then
                                s_axi_out(i).wvalid <= '0';
                            end if;
                        end loop;
                        
                        -- Move to response phase when at least one slave accepted
                        v_all_resp_received := '0';
                        for i in 0 to G_NUM_SLAVES-1 loop
                            if S_AXI_ARR_S2M(i).wready = '1' or s_axi_out(i).wvalid = '0' then
                                v_all_resp_received := '1';
                            end if;
                        end loop;
                        
                        if v_all_resp_received = '1' then
                            resp_received <= (others => '0');
                            state <= ST_WRITE_RESP;
                        end if;
                        
                        -- Timeout handling
                        if timeout_flag = '1' then
                            m_axi_out.bresp  <= C_AXI_RESP_SLVERR;
                            m_axi_out.bvalid <= '1';
                            state <= ST_IDLE;
                        end if;

                    -----------------------------------------------------------
                    -- WRITE_RESP: Wait for slave response
                    -----------------------------------------------------------
                    when ST_WRITE_RESP =>
                        -- Track responses from all slaves
                        v_any_ok  := '0';
                        v_ok_index := 0;
                        
                        for i in 0 to G_NUM_SLAVES-1 loop
                            if S_AXI_ARR_S2M(i).bvalid = '1' then
                                resp_received(i) <= '1';
                                s_axi_out(i).bready <= '0';
                                
                                -- Check for OKAY response
                                if f_axi_resp_is_ok(S_AXI_ARR_S2M(i).bresp) then
                                    v_any_ok   := '1';
                                    v_ok_index := i;
                                end if;
                            end if;
                        end loop;
                        
                        -- If we got an OK response, return it immediately
                        if v_any_ok = '1' then
                            m_axi_out.bresp  <= C_AXI_RESP_OKAY;
                            m_axi_out.bvalid <= '1';
                            state <= ST_WRITE_COMPLETE;
                            
                        -- Check if all slaves responded (all with error)
                        else
                            v_all_resp_received := '1';
                            for i in 0 to G_NUM_SLAVES-1 loop
                                if resp_received(i) = '0' and S_AXI_ARR_S2M(i).bvalid = '0' then
                                    v_all_resp_received := '0';
                                end if;
                            end loop;
                            
                            if v_all_resp_received = '1' then
                                -- All responded with error
                                m_axi_out.bresp  <= C_AXI_RESP_SLVERR;
                                m_axi_out.bvalid <= '1';
                                state <= ST_WRITE_COMPLETE;
                            end if;
                        end if;
                        
                        -- Timeout handling
                        if timeout_flag = '1' then
                            m_axi_out.bresp  <= C_AXI_RESP_SLVERR;
                            m_axi_out.bvalid <= '1';
                            state <= ST_WRITE_COMPLETE;
                        end if;

                    -----------------------------------------------------------
                    -- WRITE_COMPLETE: Wait for master bready handshake
                    -----------------------------------------------------------
                    when ST_WRITE_COMPLETE =>
                        -- Keep bvalid high until master accepts with bready
                        if M_AXI_M2S.bready = '1' then
                            m_axi_out.bvalid <= '0';
                            state <= ST_IDLE;
                        end if;

                    -----------------------------------------------------------
                    -- READ_ADDR: Wait for slave arready
                    -----------------------------------------------------------
                    when ST_READ_ADDR =>
                        -- Check which slaves accepted address
                        for i in 0 to G_NUM_SLAVES-1 loop
                            if S_AXI_ARR_S2M(i).arready = '1' then
                                s_axi_out(i).arvalid <= '0';
                            end if;
                        end loop;
                        
                        -- Check if any slave accepted
                        v_all_resp_received := '0';
                        for i in 0 to G_NUM_SLAVES-1 loop
                            if S_AXI_ARR_S2M(i).arready = '1' or s_axi_out(i).arvalid = '0' then
                                v_all_resp_received := '1';
                            end if;
                        end loop;
                        
                        if v_all_resp_received = '1' then
                            resp_received <= (others => '0');
                            state <= ST_READ_RESP;
                        end if;
                        
                        -- Timeout handling
                        if timeout_flag = '1' then
                            m_axi_out.rresp  <= C_AXI_RESP_SLVERR;
                            m_axi_out.rdata  <= (others => '0');
                            m_axi_out.rvalid <= '1';
                            state <= ST_IDLE;
                        end if;

                    -----------------------------------------------------------
                    -- READ_RESP: Wait for slave response
                    -----------------------------------------------------------
                    when ST_READ_RESP =>
                        -- Track responses from all slaves
                        v_any_ok   := '0';
                        v_ok_index := 0;
                        
                        for i in 0 to G_NUM_SLAVES-1 loop
                            if S_AXI_ARR_S2M(i).rvalid = '1' then
                                resp_received(i) <= '1';
                                s_axi_out(i).rready <= '0';
                                
                                -- Check for OKAY response
                                if f_axi_resp_is_ok(S_AXI_ARR_S2M(i).rresp) then
                                    v_any_ok   := '1';
                                    v_ok_index := i;
                                end if;
                            end if;
                        end loop;
                        
                        -- If we got an OK response, return it immediately
                        if v_any_ok = '1' then
                            m_axi_out.rdata  <= S_AXI_ARR_S2M(v_ok_index).rdata;
                            m_axi_out.rresp  <= C_AXI_RESP_OKAY;
                            m_axi_out.rvalid <= '1';
                            state <= ST_READ_COMPLETE;
                            
                        -- Check if all slaves responded (all with error)
                        else
                            v_all_resp_received := '1';
                            for i in 0 to G_NUM_SLAVES-1 loop
                                if resp_received(i) = '0' and S_AXI_ARR_S2M(i).rvalid = '0' then
                                    v_all_resp_received := '0';
                                end if;
                            end loop;
                            
                            if v_all_resp_received = '1' then
                                -- All responded with error
                                m_axi_out.rdata  <= (others => '0');
                                m_axi_out.rresp  <= C_AXI_RESP_SLVERR;
                                m_axi_out.rvalid <= '1';
                                state <= ST_READ_COMPLETE;
                            end if;
                        end if;
                        
                        -- Timeout handling
                        if timeout_flag = '1' then
                            m_axi_out.rdata  <= (others => '0');
                            m_axi_out.rresp  <= C_AXI_RESP_SLVERR;
                            m_axi_out.rvalid <= '1';
                            state <= ST_READ_COMPLETE;
                        end if;

                    -----------------------------------------------------------
                    -- READ_COMPLETE: Wait for master rready handshake
                    -----------------------------------------------------------
                    when ST_READ_COMPLETE =>
                        -- Keep rvalid high until master accepts with rready
                        if M_AXI_M2S.rready = '1' then
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
