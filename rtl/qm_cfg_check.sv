// SPDX-License-Identifier: Apache-2.0
// qm_cfg_check.sv - registered consistency check of one cycle definition.
// A cycle definition must fit inside its active window.
//
// Two pipeline stages (timing: the 33-bit sum followed by a 33-bit compare
// was a clk_sys critical path after place & route):
//   stage 1: sum = d_readin + t_store + w_ctrl, and the per-channel
//            comparisons, each one carry chain, in parallel
//   stage 2: sum > t_end, OR of all conditions
// The result lags the inputs by two clocks. Callers only use it on stable
// (snapshotted) values: qm_sequencer evaluates the snapshot check two cycles
// after taking the snapshot (end of S_REL), so arming time is unchanged.

import qm_pkg::*;

module qm_cfg_check
(
  input  logic                    clk,
  input  logic [N_KILL-1:0]       imm,
  input  logic [31:0]             d_readin,
  input  logic [31:0]             t_store,
  input  logic [15:0]             w_ctrl,
  input  logic [N_KILL-1:0][31:0] t_off,
  input  logic [N_KILL-1:0][31:0] t_rest,
  input  logic [31:0]             t_end,
  output logic                    err
);

  logic [32:0] sum_q;
  logic [32:0] t_end_q;
  logic        chan_err_q;

  always_ff @(posedge clk) begin
    logic e;
    // stage 1
    sum_q   <= 33'(d_readin) + 33'(t_store) + 33'(w_ctrl);
    t_end_q <= 33'(t_end);
    e = t_end[31];
    for (int i = 0; i < N_KILL; i++)
      if (t_rest[i] > t_end || (!imm[i] && t_off[i] > t_rest[i]))
        e = 1'b1;
    chan_err_q <= e;
    // stage 2
    err <= (sum_q > t_end_q) || chan_err_q;
  end

endmodule
