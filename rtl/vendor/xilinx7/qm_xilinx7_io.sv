// SPDX-License-Identifier: Apache-2.0
// qm_xilinx7_io.sv - all AMD/Xilinx 7-series primitives used by the design.
//
// Every vendor primitive is confined to this file. sim/models/qm_io_models.sv
// provides behavioral models with identical module names and ports.
//
// Items that MUST be verified on hardware (docs/03, calibration):
//   * ISERDESE2 bit order. This wrapper assumes Q8 holds the earliest
//     sample, so it maps word[0] = Q8. A wrong assumption shows up as a
//     timestamp error of up to 7 ns in the loopback calibration.
//   * ISERDESE2 / OSERDESE2 pipeline latency in CLKDIV cycles. It enters
//     the parameters IN_LAT_CYC / OUT_LAT_CYC of qm_top. The loopback
//     calibration measures the sum.
//   * Whether the DIO-MCX inverts any LVDS pair (p/n swap) on the EEM.

// --------------------------------------------------------------- clocking
// 125 MHz GTP reference clock -> MMCM -> clk_sys (125 MHz) and clk_fast
// (500 MHz, DDR serdes bit clock, 1 Gb/s). Both on BUFG, phase aligned.
module qm_clocking (
  input  logic clk_in_p,
  input  logic clk_in_n,
  output logic clk_sys,
  output logic clk_fast,
  output logic locked
);
  logic clk_in, clk_in_bufg, fb, fb_bufg, c0, c1;

  IBUFDS_GTE2 u_ibuf (.I(clk_in_p), .IB(clk_in_n), .CEB(1'b0), .O(clk_in), .ODIV2());
  BUFG        u_bufg_in (.I(clk_in), .O(clk_in_bufg));

  MMCME2_BASE #(
    .CLKIN1_PERIOD    (8.000),
    .DIVCLK_DIVIDE    (1),
    .CLKFBOUT_MULT_F  (8.000),   // VCO 1000 MHz
    .CLKOUT0_DIVIDE_F (8.000),   // 125 MHz
    .CLKOUT1_DIVIDE   (2),       // 500 MHz
    .CLKOUT0_PHASE    (0.0),
    .CLKOUT1_PHASE    (0.0)
  ) u_mmcm (
    .CLKIN1(clk_in_bufg), .CLKFBIN(fb_bufg), .CLKFBOUT(fb), .CLKFBOUTB(),
    .CLKOUT0(c0), .CLKOUT0B(), .CLKOUT1(c1), .CLKOUT1B(),
    .CLKOUT2(), .CLKOUT2B(), .CLKOUT3(), .CLKOUT3B(), .CLKOUT4(), .CLKOUT5(), .CLKOUT6(),
    .LOCKED(locked), .PWRDWN(1'b0), .RST(1'b0)
  );

  BUFG u_bufg_fb   (.I(fb), .O(fb_bufg));
  BUFG u_bufg_sys  (.I(c0), .O(clk_sys));
  BUFG u_bufg_fast (.I(c1), .O(clk_fast));
endmodule

// ------------------------------------------------- herald input (A and B)
// One LVDS input feeds both paths:
//   async_o : ISERDESE2 combinational output O (bypass of D), to Path A
//   word    : 8 samples per clk_div cycle at 1 GS/s, to Path B
// The bypass keeps the Path A route free of any register.
module qm_in_serdes (
  input  logic       pad_p,
  input  logic       pad_n,
  input  logic       clk_fast,
  input  logic       clk_div,
  input  logic       rst,       // synchronous to clk_div
  output logic       async_o,
  output logic [7:0] word       // bit 0 = earliest sample
);
  logic d;
  logic [8:1] q;

  IBUFDS #(.DIFF_TERM("TRUE"), .IBUF_LOW_PWR("FALSE")) u_ibuf (.I(pad_p), .IB(pad_n), .O(d));

  ISERDESE2 #(
    .DATA_RATE         ("DDR"),
    .DATA_WIDTH        (8),
    .INTERFACE_TYPE    ("NETWORKING"),
    .IOBDELAY          ("NONE"),
    .NUM_CE            (1),
    .OFB_USED          ("FALSE"),
    .SERDES_MODE       ("MASTER"),
    .DYN_CLKDIV_INV_EN ("FALSE"),
    .DYN_CLK_INV_EN    ("FALSE")
  ) u_iserdes (
    // Unused inputs are left open (unisim default = 0). nextpnr-xilinx cannot
    // route constant ties to the ILOGIC clock-inverter pins (OCLKB, CLKDIVP).
    .D(d), .DDLY(), .OFB(),
    .CLK(clk_fast), .CLKB(~clk_fast), .CLKDIV(clk_div), .CLKDIVP(),
    .OCLK(), .OCLKB(),
    .CE1(1'b1), .CE2(1'b1), .RST(rst), .BITSLIP(1'b0),
    .DYNCLKDIVSEL(), .DYNCLKSEL(),
    .SHIFTIN1(), .SHIFTIN2(),
    .O(async_o),
    .Q1(q[1]), .Q2(q[2]), .Q3(q[3]), .Q4(q[4]), .Q5(q[5]), .Q6(q[6]), .Q7(q[7]), .Q8(q[8]),
    .SHIFTOUT1(), .SHIFTOUT2()
  );

  for (genvar b = 0; b < 8; b++) begin : g_order
    assign word[b] = q[8 - b];
  end
endmodule

// ----------------------------------------------------- timed LVDS output
module qm_out_serdes (
  input  logic [7:0] word,      // bit 0 transmitted first
  input  logic       clk_fast,
  input  logic       clk_div,
  input  logic       rst,       // synchronous to clk_div
  output logic       pad_p,
  output logic       pad_n
);
  logic oq;

  OSERDESE2 #(
    .DATA_RATE_OQ   ("DDR"),
    .DATA_RATE_TQ   ("SDR"),
    .DATA_WIDTH     (8),
    .TRISTATE_WIDTH (1),
    .SERDES_MODE    ("MASTER"),
    .INIT_OQ        (1'b0),
    .SRVAL_OQ       (1'b0)
  ) u_oserdes (
    .CLK(clk_fast), .CLKDIV(clk_div), .RST(rst),
    .D1(word[0]), .D2(word[1]), .D3(word[2]), .D4(word[3]),
    .D5(word[4]), .D6(word[5]), .D7(word[6]), .D8(word[7]),
    .OCE(1'b1), .TCE(1'b0), .T1(1'b0), .T2(1'b0), .T3(1'b0), .T4(1'b0),
    .TBYTEIN(1'b0), .SHIFTIN1(1'b0), .SHIFTIN2(1'b0),
    .OQ(oq), .OFB(), .TQ(), .TFB(), .TBYTEOUT(), .SHIFTOUT1(), .SHIFTOUT2()
  );

  OBUFDS u_obuf (.I(oq), .O(pad_p), .OB(pad_n));
endmodule

// ----------------------------------------------- untimed LVDS input/output
module qm_diff_out (
  input  logic i,
  output logic pad_p,
  output logic pad_n
);
  OBUFDS u_obuf (.I(i), .O(pad_p), .OB(pad_n));
endmodule
