// SPDX-License-Identifier: Apache-2.0
// qm_herald_latch.sv - Path A: clock-independent herald reaction.
//
// The herald net is used as the CLOCK of a few flip-flops. Nothing in this
// module depends on clk_sys: a herald rising edge sets the kill flops one
// clock-to-Q after the edge, and the outputs follow through one LUT. The
// state persists after the herald pulse ends because it is held in a flop,
// not in combinational logic.
//
//   kill[i]  : C = herald, CE = arm, D = 1, CLR = clr_kill[i]  (FDCE)
//   fired    : same structure, used as HERALD_FWD and as the "truth" that an
//              experiment was started (Path B reads it via a synchronizer).
//   raw_gray : Gray-coded count of every herald edge, ungated, for Path B.
//
// Asynchronous-design rules this module relies on (enforced by qm_sequencer):
//   1. arm and clr_* are outputs of clk_sys flops, so they are glitch free.
//   2. clr_* is only asserted or released while arm is low. A herald edge
//      that collides with CLR release then clocks CE=0 and cannot change Q,
//      so a recovery/removal violation is harmless.
//   3. The remaining race is a herald edge inside the setup/hold window of
//      the arm rising edge at CE. Each flop may then go metastable and
//      resolve either way, and possibly with extra settling delay.
//      - Synchronous state: consistent. Path B decides whether the attempt
//        started only from the synchronized value of `fired`, so sequencer,
//        counters, time stamps and scheduled pulses follow one decision.
//      - Physical Path A outputs: NOT guaranteed consistent. The three kill
//        flops and `fired` sample arm independently, and arm reaches them
//        with routed skew, so one herald can set some of them and not
//        others. A beam can then stay on during an accepted attempt, or
//        switch off without one until a later cycle clears it. Nothing here
//        or in Path B detects this. Open hardware issue (docs/05 §3.3); the
//        proposed single-master-flip-flop fix is not implemented.
//   4. Minimum herald high/low time at the flop is the device clock minimum
//      pulse width (7-series: see DS181 Tmpw). Shorter pulses are not
//      guaranteed to set the flop. Path B flags fired-without-edge events.
//   5. Successive herald edges must be farther apart than the herald clock
//      period that is constrained in the XDC (20 ns; SPAD dead time >= 22 ns).

import qm_pkg::*;

module qm_herald_latch
(
  input  logic              herald,       // async, active high, from input buffer
  input  logic              rst_async,    // async reset of the raw edge counter
  input  logic              arm,          // clk_sys flop output
  input  logic [N_KILL-1:0] clr_kill,     // clk_sys flop outputs, active high
  input  logic              clr_fired,    // clk_sys flop output, active high

  output logic [N_KILL-1:0] kill,         // 1 = channel forced off
  output logic              fired,        // 1 = herald accepted since last clear
  output logic [3:0]        raw_gray      // Gray-coded herald edge count
);

  for (genvar i = 0; i < N_KILL; i++) begin : g_kill
    (* DONT_TOUCH = "TRUE" *) logic q;
    always_ff @(posedge herald or posedge clr_kill[i]) begin
      if (clr_kill[i])  q <= 1'b0;
      else if (arm)     q <= 1'b1;
    end
    assign kill[i] = q;
  end

  (* DONT_TOUCH = "TRUE" *) logic fired_q;
  always_ff @(posedge herald or posedge clr_fired) begin
    if (clr_fired)  fired_q <= 1'b0;
    else if (arm)   fired_q <= 1'b1;
  end
  assign fired = fired_q;

  // Ungated edge counter in the herald domain. Only one Gray bit changes
  // per edge, so a clk_sys synchronizer sees either the old or new count.
  logic [3:0] bin_q;
  logic [3:0] bin_nx;
  assign bin_nx = bin_q + 4'd1;
  always_ff @(posedge herald or posedge rst_async) begin
    if (rst_async) begin
      bin_q    <= '0;
      raw_gray <= '0;
    end else begin
      bin_q    <= bin_nx;
      raw_gray <= bin_nx ^ (bin_nx >> 1);
    end
  end

endmodule
