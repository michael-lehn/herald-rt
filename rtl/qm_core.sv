// SPDX-License-Identifier: Apache-2.0
// qm_core.sv - vendor-independent controller core.
//
//            herald_async ──► qm_herald_latch ──► kill[] ──► (LUT) ──► pump/repump/source
//                 │                  │  fired ─────────────► (LUT) ──► herald_fwd
//                 │                  ▼
//   herald_word ──┴─► qm_edge_capture ──► qm_sequencer ──► qm_pulse_unit ──► ctrl words
//                                              ▲   │
//                         uart ◄──► qm_regs ───┘   └──► arm / clr (back to the latch)
//
// Everything left of the latch outputs is clock-free (Path A). Everything
// that touches clk is Path B and can only *arm* or *clear* Path A.

import qm_pkg::*;

module qm_core
#(
  parameter int unsigned IN_LAT_CYC   = 3,
  parameter int unsigned OUT_LAT_CYC  = 3,
  parameter int unsigned CLKS_PER_BIT = 125   // 1 Mbaud at 125 MHz
) (
  input  logic                clk,
  input  logic                rst,

  // herald, both views of the same input pin
  input  logic                herald_async,    // Path A: straight from the input buffer
  input  logic [SERDES_W-1:0] herald_word,     // Path B: 1 GS/s samples, bit 0 earliest

  // Path A outputs (combinational from latch state, no clock in the path)
  output logic [N_KILL-1:0]   kill_out,        // to pump / repump / source drivers
  output logic                fwd_out,         // gated herald copy for external DDG/PPG

  // timed outputs (to output serdes)
  output logic [SERDES_W-1:0] ctrl_a_word,     // read-in (+ read-out if merged)
  output logic [SERDES_W-1:0] ctrl_b_word,     // read-out

  // diagnostics (clock-quantized)
  output logic                diag_armed,
  output logic                diag_active,
  output logic [2:0]          led,

  input  logic                uart_rxd,
  output logic                uart_txd
);

  localparam int unsigned SCHED_LAT = OUT_LAT_CYC + 1;  // + qm_pulse_unit pipeline stage

  // ------------------------------------------------------------ timebase
  logic [63:0] now_cyc;
  always_ff @(posedge clk) begin
    if (rst) now_cyc <= '0;
    else     now_cyc <= now_cyc + 1;
  end

  // ------------------------------------------------------------ host bus
  logic        bus_we, bus_re;
  logic [7:0]  bus_addr;
  logic [31:0] bus_wdata, bus_rdata;

  qm_uart_bridge #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_uart (
    .clk, .rst, .rxd_async(uart_rxd), .txd(uart_txd),
    .we(bus_we), .re(bus_re), .addr(bus_addr), .wdata(bus_wdata), .rdata(bus_rdata)
  );

  // --------------------------------------------------------------- config
  logic              run_en, abort_req;
  logic [N_KILL-1:0] cfg_imm, cfg_pol;
  logic              cfg_fwd_pol, cfg_ctrl_pol, cfg_merge;
  logic [31:0]       cfg_t_prep, cfg_d_readin, cfg_t_store, cfg_t_end;
  logic [15:0]       cfg_w_ctrl, cfg_fwd_w;
  logic [N_KILL-1:0][31:0] cfg_t_off;
  logic [N_KILL-1:0][31:0] cfg_t_rest;

  // ---------------------------------------------------------------- Path A
  logic              arm, clr_fired;
  logic [N_KILL-1:0] clr_kill, kill, on, imm_act;
  logic              fired;
  logic [3:0]        raw_gray;

  // Dedicated flop for the async reset of the herald-domain edge counter.
  logic rst_h;
  always_ff @(posedge clk) rst_h <= rst;

  qm_herald_latch u_latch (
    .herald(herald_async), .rst_async(rst_h),
    .arm, .clr_kill, .clr_fired,
    .kill, .fired, .raw_gray
  );

  // One LUT per output. `on`, `imm_act` and the polarities are static while
  // the latch can fire, so the only transition at herald time is from kill.
  for (genvar i = 0; i < N_KILL; i++) begin : g_out
    assign kill_out[i] = cfg_pol[i] ^ (on[i] & ~(kill[i] & imm_act[i]));
  end
  assign fwd_out = cfg_fwd_pol ^ fired;

  // ---------------------------------------------------------------- Path B
  logic [N_KILL-1:0] kill_s;
  logic              fired_s;
  logic [3:0]        raw_gray_s, raw_bin_s, raw_bin_q;

  qm_sync #(.W(N_KILL + 1), .STAGES(3)) u_sync_state (.clk, .d({kill, fired}), .q({kill_s, fired_s}));
  qm_sync #(.W(4),          .STAGES(3)) u_sync_raw   (.clk, .d(raw_gray), .q(raw_gray_s));

  always_comb begin
    for (int b = 0; b < 4; b++) raw_bin_s[b] = ^(raw_gray_s >> b);
  end
  always_ff @(posedge clk) begin
    if (rst) raw_bin_q <= '0;
    else     raw_bin_q <= raw_bin_s;
  end

  logic        edge_valid;
  logic [63:0] edge_ns;

  qm_edge_capture #(.IN_LAT_CYC(IN_LAT_CYC)) u_cap (
    .clk, .rst, .word(herald_word), .now_cyc, .edge_valid, .edge_ns
  );

  logic [3:0]      state;
  logic            cfg_err, cand_pending;
  logic            ev_edge, ev_acc, ev_rej, ev_race, ev_abort, ev_noedge, ev_late, ev_done;
  logic [63:0]     acc_ts;
  logic            p_en;
  logic [NS_W-1:0] p_readin_start, p_readout_start;
  logic [15:0]     p_width;

  qm_sequencer #(.OUT_LAT_CYC(SCHED_LAT)) u_seq (
    .clk, .rst, .now_cyc,
    .run_en, .abort_req, .cfg_imm, .cfg_t_prep, .cfg_d_readin, .cfg_t_store, .cfg_w_ctrl,
    .cfg_t_off, .cfg_t_rest, .cfg_t_end, .cfg_fwd_w,
    .edge_valid, .edge_ns, .fired_s,
    .arm, .clr_kill, .clr_fired, .on, .imm_act,
    .p_en, .p_readin_start, .p_readout_start, .p_width,
    .state, .cfg_err,
    .ev_edge, .ev_acc, .ev_rej, .ev_race, .ev_abort, .ev_noedge, .ev_late, .ev_done,
    .acc_ts, .cand_pending
  );

  qm_regs u_regs (
    .clk, .rst,
    .we(bus_we), .re(bus_re), .addr(bus_addr), .wdata(bus_wdata), .rdata(bus_rdata),
    .run_en, .abort_req, .cfg_imm, .cfg_pol, .cfg_fwd_pol, .cfg_ctrl_pol, .cfg_merge,
    .cfg_t_prep, .cfg_d_readin, .cfg_t_store, .cfg_w_ctrl, .cfg_t_off, .cfg_t_rest,
    .cfg_t_end, .cfg_fwd_w,
    .state, .cfg_err, .arm, .kill_s, .fired_s, .cand_pending,
    .raw_delta(raw_bin_s - raw_bin_q),
    .ev_edge, .ev_acc, .ev_rej, .ev_race, .ev_abort, .ev_noedge, .ev_late, .ev_done,
    .acc_ts
  );

  // ------------------------------------------------------- control pulses
  // Inputs sampled by the pulse units in cycle n are emitted at phys ns
  // (n + SCHED_LAT) * 8. OUT_LAT_CYC covers the first pulse-unit register,
  // the output register below and the output serdes; qm_pulse_unit adds one
  // more pipeline stage. base_ns is a registered counter that tracks
  // (now_cyc + SCHED_LAT) * 8, so no wide adder sits in front of the units.
  logic [NS_W-1:0]     base_ns;
  logic [SERDES_W-1:0] w_in, w_out;

  always_ff @(posedge clk) begin
    if (rst) base_ns <= NS_W'(SCHED_LAT * 8);
    else     base_ns <= base_ns + NS_W'(8);
  end

  qm_pulse_unit u_p_in  (.clk, .rst, .en(p_en), .start(p_readin_start),  .width(p_width),
                         .base(base_ns), .word(w_in));
  qm_pulse_unit u_p_out (.clk, .rst, .en(p_en), .start(p_readout_start), .width(p_width),
                         .base(base_ns), .word(w_out));

  always_ff @(posedge clk) begin
    if (rst) begin
      ctrl_a_word <= '0;
      ctrl_b_word <= '0;
    end else begin
      ctrl_a_word <= {SERDES_W{cfg_ctrl_pol}} ^ (w_in | (cfg_merge ? w_out : '0));
      ctrl_b_word <= {SERDES_W{cfg_ctrl_pol}} ^ w_out;
    end
  end

  // ---------------------------------------------------------- diagnostics
  logic [26:0] hb;
  always_ff @(posedge clk) begin
    if (rst) begin
      hb          <= '0;
      diag_armed  <= 1'b0;
      diag_active <= 1'b0;
    end else begin
      hb          <= hb + 1;
      diag_armed  <= arm;
      diag_active <= (state == S_ACTIVE);
    end
  end
  assign led = {cfg_err, hb[26], run_en};

endmodule
