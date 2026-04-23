////////////////////////////////////////////////////////////////////////////////
// Axion Common Package - SystemVerilog
//
// AXI4-Lite bus type definitions and utility functions
//
// Copyright (c) 2024 Bugra Tufan
// MIT License
////////////////////////////////////////////////////////////////////////////////

package axion_common_pkg;

    ////////////////////////////////////////////////////////////////////////////
    // AXI4-Lite Constants
    ////////////////////////////////////////////////////////////////////////////
    localparam int C_AXI_DATA_WIDTH = 32;
    localparam int C_AXI_ADDR_WIDTH = 32;
    localparam int C_AXI_STRB_WIDTH = C_AXI_DATA_WIDTH / 8;

    // AXI Response codes
    localparam logic [1:0] C_AXI_RESP_OKAY   = 2'b00;
    localparam logic [1:0] C_AXI_RESP_EXOKAY = 2'b01;
    localparam logic [1:0] C_AXI_RESP_SLVERR = 2'b10;
    localparam logic [1:0] C_AXI_RESP_DECERR = 2'b11;

    ////////////////////////////////////////////////////////////////////////////
    // AXI4-Lite Master to Slave signals (M2S)
    // Signals driven by master, received by slave
    ////////////////////////////////////////////////////////////////////////////
    typedef struct packed {
        // Write Address Channel
        logic [C_AXI_ADDR_WIDTH-1:0] awaddr;
        logic                        awvalid;
        logic [2:0]                  awprot;

        // Write Data Channel
        logic [C_AXI_DATA_WIDTH-1:0] wdata;
        logic [C_AXI_STRB_WIDTH-1:0] wstrb;
        logic                        wvalid;

        // Write Response Channel
        logic                        bready;

        // Read Address Channel
        logic [C_AXI_ADDR_WIDTH-1:0] araddr;
        logic                        arvalid;
        logic [2:0]                  arprot;

        // Read Data Channel
        logic                        rready;
    } t_axi_lite_m2s;

    ////////////////////////////////////////////////////////////////////////////
    // AXI4-Lite Slave to Master signals (S2M)
    // Signals driven by slave, received by master
    ////////////////////////////////////////////////////////////////////////////
    typedef struct packed {
        // Write Address Channel
        logic                        awready;

        // Write Data Channel
        logic                        wready;

        // Write Response Channel
        logic [1:0]                  bresp;
        logic                        bvalid;

        // Read Address Channel
        logic                        arready;

        // Read Data Channel
        logic [C_AXI_DATA_WIDTH-1:0] rdata;
        logic [1:0]                  rresp;
        logic                        rvalid;
    } t_axi_lite_s2m;

    ////////////////////////////////////////////////////////////////////////////
    // Array types for multiple slaves/masters
    ////////////////////////////////////////////////////////////////////////////
    typedef t_axi_lite_m2s t_axi_lite_m2s_array[];
    typedef t_axi_lite_s2m t_axi_lite_s2m_array[];

    ////////////////////////////////////////////////////////////////////////////
    // Initial/Default values
    // All fields default to 0; bresp/rresp default to C_AXI_RESP_OKAY (2'b00)
    ////////////////////////////////////////////////////////////////////////////
    localparam t_axi_lite_m2s C_AXI_LITE_M2S_INIT = '0;
    localparam t_axi_lite_s2m C_AXI_LITE_S2M_INIT = '0;

    ////////////////////////////////////////////////////////////////////////////
    // Utility Functions
    ////////////////////////////////////////////////////////////////////////////

    // Check if AXI response is OK
    function automatic logic f_axi_resp_is_ok(input logic [1:0] resp);
        return (resp == C_AXI_RESP_OKAY) || (resp == C_AXI_RESP_EXOKAY);
    endfunction : f_axi_resp_is_ok

    // Check if AXI response is error
    function automatic logic f_axi_resp_is_error(input logic [1:0] resp);
        return (resp == C_AXI_RESP_SLVERR) || (resp == C_AXI_RESP_DECERR);
    endfunction : f_axi_resp_is_error

endpackage : axion_common_pkg
