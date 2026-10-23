// SPDX-License-Identifier: Apache-2.0
// qm_sequencer.sv - experiment cycle controller (synchronous, clk_sys).
//
// The sequencer never sits in the herald -> immediate-output path. It
//   * arms / disarms the herald-clocked latches (arm, clr_*),
//   * decides from the synchronized `fired` flag whether an attempt started
//     (that flag is the single source of truth shared with Path A),
//   * pairs the attempt with the serdes timestamp of the herald edge,
//   * schedules the read-in / read-out control triggers relative to that
//     timestamp with 1 ns resolution,
//   * drives the slow (clock-quantized) off / restore events,
//   * enforces the minimum state-preparation time before re-arming.
//
// Edge accounting invariant (checked in the testbench):
//   cnt_edge == cnt_acc + cnt_rej + cnt_race + (candidate pending ? 1 : 0)

import qm_pkg::*;

module qm_sequencer
#(
  parameter int unsigned OUT_LAT_CYC = 3,
  parameter int unsigned CONFIRM_CYC = 8,  // max skew between fired_s and serdes edge
  parameter int unsigned GUARD_NS    = 2   // edges this close before arm may still fire
) (
  input  logic              clk,
  input  logic              rst,
  input  logic [63:0]       now_cyc,

  // control / configuration (from qm_regs, snapshotted before arming)
  input  logic              run_en,
  input  logic              abort_req,     // one-cycle strobe
  input  logic [N_KILL-1:0] cfg_imm,       // 1 = channel switched off by Path A
  input  logic [31:0]       cfg_t_prep,    // cycles
  input  logic [31:0]       cfg_d_readin,  // ns
  input  logic [31:0]       cfg_t_store,   // ns
  input  logic [15:0]       cfg_w_ctrl,    // ns
  input  logic [N_KILL-1:0][31:0] cfg_t_off,
  input  logic [N_KILL-1:0][31:0] cfg_t_rest,
  input  logic [31:0]       cfg_t_end,     // ns
  input  logic [15:0]       cfg_fwd_w,     // cycles

  // Path B inputs
  input  logic              edge_valid,
  input  logic [63:0]       edge_ns,
  input  logic              fired_s,       // synchronized Path A `fired`

  // to Path A latches (registered, glitch free)
  output logic              arm,
  output logic [N_KILL-1:0] clr_kill,
  output logic              clr_fired,
  output logic [N_KILL-1:0] on,            // synchronous enable per channel
  output logic [N_KILL-1:0] imm_act,       // cfg_imm snapshot in force this cycle

  // control-pulse scheduling (consumed by qm_pulse_unit)
  output logic              p_en,
  output logic [NS_W-1:0]   p_readin_start,
  output logic [NS_W-1:0]   p_readout_start,
  output logic [15:0]       p_width,

  // status / statistics strobes
  output logic [3:0]        state,         // state_t encoding
  output logic              cfg_err,
  output logic              ev_edge,
  output logic              ev_acc,
  output logic              ev_rej,
  output logic              ev_race,
  output logic              ev_abort,
  output logic              ev_noedge,
  output logic              ev_late,
  output logic              ev_done,
  output logic [63:0]       acc_ts,        // phys ns of accepted herald
  output logic              cand_pending
);

  // ---------------------------------------------------------------- config
  // Working copy, captured when leaving PREP so timing is stable per cycle.
  logic [N_KILL-1:0] c_imm;
  assign imm_act = c_imm;
  logic [31:0]       c_d_readin, c_t_store, c_t_end;
  logic [15:0]       c_w_ctrl, c_fwd_w;
  logic [N_KILL-1:0][31:0] c_t_off;
  logic [N_KILL-1:0][31:0] c_t_rest;

  // Consistency checks, registered to keep them off the critical path:
  // cfg_err reports the host-visible registers (status / LED); c_err checks
  // the frozen snapshot and gates arming at the end of S_REL.
  logic c_err;
  qm_cfg_check u_chk_cfg (.clk, .imm(cfg_imm), .d_readin(cfg_d_readin), .t_store(cfg_t_store),
                          .w_ctrl(cfg_w_ctrl), .t_off(cfg_t_off), .t_rest(cfg_t_rest),
                          .t_end(cfg_t_end), .err(cfg_err));
  qm_cfg_check u_chk_snap (.clk, .imm(c_imm), .d_readin(c_d_readin), .t_store(c_t_store),
                           .w_ctrl(c_w_ctrl), .t_off(c_t_off), .t_rest(c_t_rest),
                           .t_end(c_t_end), .err(c_err));

  // ------------------------------------------------------------ timebase
  logic [NS_W-1:0] now_ns;
  assign now_ns = NS_W'(now_cyc << 3);

  function automatic logic due(input logic [NS_W-1:0] t);
    logic [NS_W-1:0] d;
    d   = now_ns - t;
    due = !d[NS_W-1];             // (now - t) >= 0, wrap-safe
  endfunction

  // ------------------------------------------------------------- state
  logic [31:0]       timer;
  logic [NS_W-1:0]   arm_lim;     // arm time minus guard band
  logic [63:0]       cand_ts;
  logic [NS_W-1:0]   cand_rd;     // cand_ts + D_READIN
  logic [7:0]        cand_age;
  logic [7:0]        noedge_age;
  logic [N_KILL-1:0] restored;

  // Absolute event times of the active cycle, computed once on accept so
  // that every compare in S_ACTIVE is a single subtraction against now.
  logic [N_KILL-1:0][NS_W-1:0] t_off_abs, t_rest_abs;
  logic [NS_W-1:0]             t_end_abs;

  // Edge qualifies as the firing edge if it is not clearly before arm.
  logic edge_qual;
  assign edge_qual = edge_valid && (state == S_ARMED) && !cand_pending &&
                     ($signed(NS_W'(edge_ns) - arm_lim) >= 0);

  // Late check: the read-in edge must lie after the first word that can
  // still be produced once p_en rises next cycle. first_base is registered
  // and equals ((now_cyc + 1 + OUT_LAT_CYC) * 8) in the cycle it is used.
  logic [NS_W-1:0] first_base;
  logic            late_now;
  always_ff @(posedge clk) first_base <= now_ns + NS_W'((2 + OUT_LAT_CYC) * 8);
  assign late_now = $signed(cand_rd - first_base) < 0;

  always_ff @(posedge clk) begin
    ev_edge   <= 1'b0;  ev_acc  <= 1'b0;  ev_rej    <= 1'b0;  ev_race <= 1'b0;
    ev_abort  <= 1'b0;  ev_late <= 1'b0;  ev_noedge <= 1'b0;  ev_done <= 1'b0;

    if (rst) begin
      state        <= S_IDLE;
      arm          <= 1'b0;
      clr_kill     <= '1;
      clr_fired    <= 1'b1;
      on           <= '0;
      p_en         <= 1'b0;
      timer        <= '0;
      cand_pending <= 1'b0;
      restored     <= '0;
      acc_ts       <= '0;
      c_imm        <= '1;
    end else begin
      // Every serdes edge is classified exactly once.
      if (edge_valid) begin
        ev_edge <= 1'b1;
        if (!edge_qual) ev_rej <= 1'b1;
      end

      unique case (state)
        S_IDLE: begin
          arm <= 1'b0;  clr_kill <= '1;  clr_fired <= 1'b1;  on <= '0;  p_en <= 1'b0;
          if (run_en) begin
            state <= S_PREP;
            timer <= '0;
          end
        end

        S_PREP: begin
          arm <= 1'b0;  clr_kill <= '1;  clr_fired <= 1'b1;  on <= '1;  p_en <= 1'b0;
          if (timer != '1) timer <= timer + 1;
          if (!run_en) begin
            state <= S_IDLE;
          end else if (timer >= cfg_t_prep) begin
            c_imm      <= cfg_imm;
            c_d_readin <= cfg_d_readin;
            c_t_store  <= cfg_t_store;
            c_w_ctrl   <= cfg_w_ctrl;
            c_t_end    <= cfg_t_end;
            c_fwd_w    <= cfg_fwd_w;
            c_t_off    <= cfg_t_off;
            c_t_rest   <= cfg_t_rest;
            state      <= S_REL;
            timer      <= '0;
          end
        end

        // Release clears while arm is still low (rule 2 in qm_herald_latch).
        S_REL: begin
          arm <= 1'b0;  clr_kill <= '0;  clr_fired <= 1'b0;
          timer <= timer + 1;
          if (!run_en || abort_req) begin
            state <= S_ABORT;
          // c_err (two-stage qm_cfg_check) reflects the snapshot taken on
          // entry to S_REL exactly from timer == 2 on; testbench T17 fails if
          // this budget is exceeded.
          end else if (timer == 32'd2 && c_err) begin
            state <= S_PREP;               // invalid snapshot: never arm with it
            timer <= '0;
          end else if (timer == 32'd2) begin
            state        <= S_ARMED;
            arm          <= 1'b1;
            arm_lim      <= now_ns + NS_W'(8) - NS_W'(GUARD_NS);
            cand_pending <= 1'b0;
            noedge_age   <= '0;
          end
        end

        S_ARMED: begin
          // candidate bookkeeping
          if (edge_qual) begin
            cand_pending <= 1'b1;
            cand_ts      <= edge_ns;
            cand_rd      <= NS_W'(edge_ns) + c_d_readin;
            cand_age     <= '0;
          end else if (cand_pending) begin
            cand_age <= cand_age + 1;
          end

          if (!run_en || abort_req) begin
            state <= S_ABORT;
            arm   <= 1'b0;
          end else if (fired_s) begin
            arm <= 1'b0;
            // Accept only a registered candidate; an edge arriving in this
            // very cycle is accepted one cycle later (noedge_age < CONFIRM).
            if (cand_pending) begin
              cand_pending <= 1'b0;
              acc_ts       <= cand_ts;
              t_end_abs    <= NS_W'(cand_ts) + c_t_end;
              for (int i = 0; i < N_KILL; i++) begin
                t_off_abs[i]  <= NS_W'(cand_ts) + c_t_off[i];
                t_rest_abs[i] <= NS_W'(cand_ts) + c_t_rest[i];
              end
              ev_acc       <= 1'b1;
              if (late_now) begin
                ev_late <= 1'b1;
                state   <= S_ABORT;
              end else begin
                state           <= S_ACTIVE;
                timer           <= '0;
                restored        <= '0;
                p_en            <= 1'b1;
                p_readin_start  <= cand_rd;
                p_readout_start <= cand_rd + c_t_store;
                p_width         <= c_w_ctrl;
              end
            end else if (noedge_age >= 8'(CONFIRM_CYC)) begin
              ev_noedge <= 1'b1;
              state     <= S_ABORT;
            end else begin
              noedge_age <= noedge_age + 1;
            end
          end else if (cand_pending && cand_age >= 8'(CONFIRM_CYC)) begin
            // Saw an edge but the latch did not fire: the edge lost the race
            // against arm (or the pulse was too short for the latch).
            ev_race      <= 1'b1;
            cand_pending <= 1'b0;
          end
        end

        S_ACTIVE: begin
          arm   <= 1'b0;
          timer <= timer + 1;
          if (timer >= 32'(c_fwd_w)) clr_fired <= 1'b1;

          for (int i = 0; i < N_KILL; i++) begin
            if (!restored[i] && due(t_rest_abs[i])) begin
              restored[i] <= 1'b1;
              clr_kill[i] <= 1'b1;   // safe: arm is low
              on[i]       <= 1'b1;
            end else if (!c_imm[i] && !restored[i] && due(t_off_abs[i])) begin
              on[i] <= 1'b0;
            end
          end

          if (!run_en || abort_req) begin
            state <= S_ABORT;
            p_en  <= 1'b0;                 // cancel pending pulses immediately
          end else if (due(t_end_abs)) begin
            ev_done <= 1'b1;
            p_en    <= 1'b0;
            state   <= S_PREP;
            timer   <= '0;
          end
        end

        S_ABORT: begin
          arm <= 1'b0;  clr_kill <= '1;  clr_fired <= 1'b1;  p_en <= 1'b0;
          on       <= run_en ? '1 : '0;
          ev_abort <= 1'b1;
          cand_pending <= 1'b0;
          timer    <= '0;
          state    <= run_en ? S_PREP : S_IDLE;
        end

        default: state <= S_IDLE;
      endcase
    end
  end

endmodule
