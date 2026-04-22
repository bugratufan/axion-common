////////////////////////////////////////////////////////////////////////////////
// tb_axion_common_pkg_wrap.sv
//
// Thin combinational wrapper that exposes axion_common_pkg constants,
// function outputs and struct metadata on ports so the cocotb testbench
// can inspect them without needing to read internal symbols.
//
// DUT for: tb_axion_common_pkg_cocotb.py
//
// Copyright (c) 2024 Bugra Tufan
// MIT License
////////////////////////////////////////////////////////////////////////////////

module tb_axion_common_pkg_wrap
    import axion_common_pkg::*;
(
    // Simulation heartbeat (required by cocotb/Verilator)
    input  logic        clk,

    // ------------------------------------------------------------------
    // Input: response code under test (for function verification)
    // ------------------------------------------------------------------
    input  logic [1:0]  i_resp,

    // ------------------------------------------------------------------
    // Outputs: AXI4-Lite constants
    // ------------------------------------------------------------------
    output logic [31:0] o_data_width,
    output logic [31:0] o_addr_width,
    output logic [31:0] o_strb_width,

    output logic [1:0]  o_resp_okay,
    output logic [1:0]  o_resp_exokay,
    output logic [1:0]  o_resp_slverr,
    output logic [1:0]  o_resp_decerr,

    // ------------------------------------------------------------------
    // Outputs: utility function results (combinational, driven by i_resp)
    // ------------------------------------------------------------------
    output logic        o_resp_is_ok,
    output logic        o_resp_is_error,

    // ------------------------------------------------------------------
    // Outputs: sampled fields from C_AXI_LITE_M2S_INIT
    // ------------------------------------------------------------------
    output logic        o_m2s_awvalid_init,
    output logic        o_m2s_rready_init,

    // ------------------------------------------------------------------
    // Outputs: sampled fields from C_AXI_LITE_S2M_INIT
    // ------------------------------------------------------------------
    output logic        o_s2m_bvalid_init,
    output logic        o_s2m_rvalid_init,
    output logic [1:0]  o_s2m_bresp_init,
    output logic [1:0]  o_s2m_rresp_init,

    // ------------------------------------------------------------------
    // Outputs: packed struct bit widths
    // ------------------------------------------------------------------
    output logic [31:0] o_m2s_width,
    output logic [31:0] o_s2m_width
);

    // ------------------------------------------------------------------
    // Constants
    // ------------------------------------------------------------------
    assign o_data_width  = C_AXI_DATA_WIDTH;
    assign o_addr_width  = C_AXI_ADDR_WIDTH;
    assign o_strb_width  = C_AXI_STRB_WIDTH;

    assign o_resp_okay   = C_AXI_RESP_OKAY;
    assign o_resp_exokay = C_AXI_RESP_EXOKAY;
    assign o_resp_slverr = C_AXI_RESP_SLVERR;
    assign o_resp_decerr = C_AXI_RESP_DECERR;

    // ------------------------------------------------------------------
    // Utility functions (purely combinational)
    // ------------------------------------------------------------------
    assign o_resp_is_ok    = f_axi_resp_is_ok(i_resp);
    assign o_resp_is_error = f_axi_resp_is_error(i_resp);

    // ------------------------------------------------------------------
    // Init constant fields
    // ------------------------------------------------------------------
    assign o_m2s_awvalid_init = C_AXI_LITE_M2S_INIT.awvalid;
    assign o_m2s_rready_init  = C_AXI_LITE_M2S_INIT.rready;

    assign o_s2m_bvalid_init  = C_AXI_LITE_S2M_INIT.bvalid;
    assign o_s2m_rvalid_init  = C_AXI_LITE_S2M_INIT.rvalid;
    assign o_s2m_bresp_init   = C_AXI_LITE_S2M_INIT.bresp;
    assign o_s2m_rresp_init   = C_AXI_LITE_S2M_INIT.rresp;

    // ------------------------------------------------------------------
    // Struct bit widths
    // awaddr(32)+awvalid(1)+awprot(3)+wdata(32)+wstrb(4)+wvalid(1)
    // +bready(1)+araddr(32)+arvalid(1)+arprot(3)+rready(1) = 111
    //
    // awready(1)+wready(1)+bresp(2)+bvalid(1)+arready(1)
    // +rdata(32)+rresp(2)+rvalid(1) = 41
    // ------------------------------------------------------------------
    assign o_m2s_width = $bits(t_axi_lite_m2s);
    assign o_s2m_width = $bits(t_axi_lite_s2m);

endmodule : tb_axion_common_pkg_wrap
