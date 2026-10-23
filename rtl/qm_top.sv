// SPDX-License-Identifier: Apache-2.0
// qm_top.sv - board top for Sinara Kasli 2.0 + DIO-MCX (2238) on EEM0/EEM1.
//
// DIO-MCX channel map (bank direction set by the card's DIP switches):
//   bank 0 (EEM0 d0..d3, ch 0..3)  INPUT : ch0 HERALD (SPAD, via 50 ohm term.)
//   bank 1 (EEM0 d4..d7, ch 4..7)  OUTPUT: ch4 PUMP_EN, ch5 REPUMP_EN,
//                                          ch6 SOURCE_EN, ch7 HERALD_FWD
//   bank 2 (EEM1 d0..d3, ch 8..11) OUTPUT: ch8 CTRL_A, ch9 CTRL_B,
//                                          ch10 DIAG_ARMED, ch11 DIAG_ACTIVE
//   bank 3 (EEM1 d4..d7)           unused, set to INPUT
//
// Signal polarity at the MCX connectors: active high, "1" = beam/source ON
// for ch4..6 (inverted per channel by CHCFG if a driver needs it).

import qm_pkg::*;

module qm_top
#(
  // Serdes pipeline latencies in clk_sys cycles. PLACEHOLDERS for the
  // hardware build: the loopback calibration (docs/03) measures them.
  parameter int unsigned IN_LAT_CYC   = 1,
  parameter int unsigned OUT_LAT_CYC  = 3,
  parameter int unsigned CLKS_PER_BIT = 125
) (
  input  logic clk125_p,         // Kasli GTP reference clock, 125 MHz
  input  logic clk125_n,

  input  logic herald_p,         // EEM0 d0 (clock-capable pair)
  input  logic herald_n,

  output logic pump_p,           // EEM0 d4
  output logic pump_n,
  output logic repump_p,         // EEM0 d5
  output logic repump_n,
  output logic source_p,         // EEM0 d6
  output logic source_n,
  output logic fwd_p,            // EEM0 d7
  output logic fwd_n,

  output logic ctrl_a_p,         // EEM1 d0
  output logic ctrl_a_n,
  output logic ctrl_b_p,         // EEM1 d1
  output logic ctrl_b_n,
  output logic armed_p,          // EEM1 d2
  output logic armed_n,
  output logic active_p,         // EEM1 d3
  output logic active_n,

  input  logic uart_rx,          // FT4232H UART (host -> FPGA)
  output logic uart_tx,
  output logic [2:0] user_led,
  output logic error_led
);

  // ---------------------------------------------------- clocks and reset
  logic clk, clk_fast, locked;
  qm_clocking u_clk (.clk_in_p(clk125_p), .clk_in_n(clk125_n),
                     .clk_sys(clk), .clk_fast, .locked);

  // Reset held for 64 cycles after MMCM lock; synchronous to clk.
  logic       locked_s;
  logic [6:0] por;
  logic       rst;
  qm_sync #(.W(1), .STAGES(2)) u_lock_sync (.clk, .d(locked), .q(locked_s));
  always_ff @(posedge clk) begin
    if (!locked_s)      por <= '0;
    else if (!por[6])   por <= por + 1;
  end
  assign rst = !por[6];

  // ---------------------------------------------------------- herald in
  logic                herald_async;
  logic [SERDES_W-1:0] herald_word;
  qm_in_serdes u_herald (.pad_p(herald_p), .pad_n(herald_n), .clk_fast, .clk_div(clk),
                         .rst, .async_o(herald_async), .word(herald_word));

  // --------------------------------------------------------------- core
  logic [N_KILL-1:0]   kill_out;
  logic                fwd_out, diag_armed, diag_active;
  logic [SERDES_W-1:0] ctrl_a_word, ctrl_b_word;
  logic [2:0]          led;

  qm_core #(.IN_LAT_CYC(IN_LAT_CYC), .OUT_LAT_CYC(OUT_LAT_CYC),
            .CLKS_PER_BIT(CLKS_PER_BIT)) u_core (
    .clk, .rst,
    .herald_async, .herald_word,
    .kill_out, .fwd_out,
    .ctrl_a_word, .ctrl_b_word,
    .diag_armed, .diag_active, .led,
    .uart_rxd(uart_rx), .uart_txd(uart_tx)
  );

  // ------------------------------------------------------------ outputs
  qm_diff_out u_pump   (.i(kill_out[CH_PUMP]),   .pad_p(pump_p),   .pad_n(pump_n));
  qm_diff_out u_repump (.i(kill_out[CH_REPUMP]), .pad_p(repump_p), .pad_n(repump_n));
  qm_diff_out u_source (.i(kill_out[CH_SOURCE]), .pad_p(source_p), .pad_n(source_n));
  qm_diff_out u_fwd    (.i(fwd_out),             .pad_p(fwd_p),    .pad_n(fwd_n));
  qm_diff_out u_armed  (.i(diag_armed),          .pad_p(armed_p),  .pad_n(armed_n));
  qm_diff_out u_active (.i(diag_active),         .pad_p(active_p), .pad_n(active_n));

  qm_out_serdes u_ctrl_a (.word(ctrl_a_word), .clk_fast, .clk_div(clk), .rst,
                          .pad_p(ctrl_a_p), .pad_n(ctrl_a_n));
  qm_out_serdes u_ctrl_b (.word(ctrl_b_word), .clk_fast, .clk_div(clk), .rst,
                          .pad_p(ctrl_b_p), .pad_n(ctrl_b_n));

  assign user_led  = led;
  assign error_led = led[2];

endmodule
