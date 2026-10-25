// SPDX-License-Identifier: Apache-2.0
// qm_sequencer.sv - experiment cycle controller (synchronous, clk_sys).
//
// What one experiment cycle is
//   The atoms are first prepared with the pump and repump beams and the
//   photon source switched on. Then the controller waits for a herald: a
//   detector pulse announcing that a photon is on its way to the memory.
//   After the herald, beams and source are switched off, a read-in (write)
//   control pulse stores the photon, a read-out (read) control pulse
//   retrieves it after the storage time, and the beams are restored for the
//   next preparation. All delays are configured relative to the herald.
//
// Division of labour with Path A (qm_herald_latch)
//   The fast reaction to the herald (beams off within nanoseconds, HERALD_FWD)
//   is done without any clock by herald-clocked latches. This sequencer is
//   never in that path. It only
//   * arms / disarms the latches (arm) and clears them (clr_*), always from
//     clk_sys flops and with the ordering rules listed in qm_herald_latch,
//   * decides from the synchronized `fired` flag whether an attempt started
//     (that flag is the single source of truth shared with Path A),
//   * pairs the attempt with the serdes timestamp of the herald edge,
//   * schedules the read-in / read-out control pulses relative to that
//     timestamp with 1 ns resolution (emitted by qm_pulse_unit),
//   * drives the slow, clock-quantized off / restore events (`on`),
//   * enforces the minimum state-preparation time before re-arming.
//
// States (encoding in qm_pkg::state_t, visible in STATUS[3:0])
//   IDLE    run_en = 0. All channels off, latches held in clear.
//   PREP    Channels on, latches held in clear. Stays at least T_PREP cycles
//           so the atoms are prepared before the next herald can be taken.
//           On exit the configuration is snapshotted.
//   REL     Three cycles: latch clears released while arm is still low, and
//           time for the registered check of the snapshot.
//   ARMED   arm = 1. The next herald sets the latches and starts an attempt.
//           The sequencer waits until both the synchronized `fired` flag and
//           the serdes timestamp of the edge have arrived.
//   ACTIVE  Attempt in progress: control pulses are scheduled, off / restore
//           events run, and the attempt ends at T_END.
//   ABORT   One cycle: cancel pulses, clear latches, then PREP or IDLE.
//
// Transitions
//   IDLE   -> PREP    run_en = 1
//   PREP   -> IDLE    run_en = 0
//   PREP   -> REL     PREP has lasted T_PREP + 1 cycles
//   REL    -> ARMED   third REL cycle, snapshot valid
//   REL    -> PREP    third REL cycle, snapshot invalid (never arm with it)
//   ARMED  -> ACTIVE  fired_s and a candidate edge: herald accepted
//   ARMED  -> ABORT   accepted, but the read-in pulse can no longer be emitted
//                     in full (late); or fired_s without a serdes edge (no-edge)
//   ACTIVE -> PREP    T_END reached (normal end of the attempt)
//   REL, ARMED, ACTIVE -> ABORT   run_en = 0 or host abort
//   ABORT  -> PREP if run_en = 1, else IDLE
//   A host abort therefore restarts the cycle; only run_en = 0 stops it.
//   abort_req has no effect in IDLE, PREP and ABORT.
//
// Edge accounting (checked in the testbench)
//   Every serdes edge raises ev_edge. It is either rejected at once (ev_rej)
//   or becomes the pending candidate, which later ends as accepted (ev_acc)
//   or as a race (ev_race), hence
//     cnt_edge == cnt_acc + cnt_rej + cnt_race + (candidate pending ? 1 : 0)
//   A candidate still pending when ARMED is left through ABORT is discarded
//   without any of these strobes, so the identity does not hold after such
//   an abort.

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
  // The host may rewrite registers at any time; a change takes effect at the
  // next PREP exit. cfg_t_prep is the exception: PREP reads it directly.
  // imm_act feeds the Path A output LUTs (qm_core) and therefore only changes
  // at PREP exit, while arm is low.
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
  // now_ns is the phys ns (qm_pkg) of bit 0 of the current clk_sys cycle,
  // truncated to the 32-bit scheduling timebase. Herald timestamps and pulse
  // start times are in the same frame, so they can be compared directly.
  logic [NS_W-1:0] now_ns;
  assign now_ns = NS_W'(now_cyc << 3);

  // due(t): has phys ns t been reached at the start of this cycle? Valid as
  // long as t lies within 2^31 ns of now; qm_cfg_check keeps every offset
  // in use below 2^31 ns. A time already in the past is due at once, so an event
  // whose offset is shorter than the herald-to-ACTIVE latency happens in
  // the first ACTIVE cycle, later than programmed.
  function automatic logic due(input logic [NS_W-1:0] t);
    logic [NS_W-1:0] d;
    d   = now_ns - t;
    due = !d[NS_W-1];             // (now - t) >= 0, wrap-safe
  endfunction

  // ------------------------------------------------------------- state
  // timer: PREP counts preparation cycles (saturating), REL counts its three
  // cycles, ACTIVE counts cycles since the herald was accepted.
  logic [31:0]       timer;
  logic [NS_W-1:0]   arm_lim;     // arm time minus guard band
  logic [63:0]       cand_ts;     // candidate herald timestamp (phys ns)
  logic [NS_W-1:0]   cand_rd;     // cand_ts + D_READIN
  logic [7:0]        cand_age;    // cycles the candidate has waited for fired_s
  logic [7:0]        noedge_age;  // cycles fired_s has waited for a candidate
  logic [N_KILL-1:0] restored;

  // Absolute event times of the active cycle, computed once on accept so
  // that every compare in S_ACTIVE is a single subtraction against now.
  logic [N_KILL-1:0][NS_W-1:0] t_off_abs, t_rest_abs;
  logic [NS_W-1:0]             t_end_abs;

  // Edge qualifies as the firing edge if it is not clearly before arm.
  // The timestamp arrives several cycles after the edge itself (input serdes
  // pipeline), so an edge seen in ARMED may physically precede arm. Edges
  // timestamped earlier than arm_lim are rejected. An edge in the guard band
  // just before the nominal arm time may still have fired the latch, so it
  // becomes a candidate and fired_s decides (accept or race). While a
  // candidate is pending, further edges are rejected.
  logic edge_qual;
  assign edge_qual = edge_valid && (state == S_ARMED) && !cand_pending &&
                     ($signed(NS_W'(edge_ns) - arm_lim) >= 0);

  // Late check: the read-in edge must lie after the first word that can
  // still be produced once p_en rises next cycle. first_base is registered
  // and equals ((now_cyc + 1 + OUT_LAT_CYC) * 8) in the cycle it is used.
  // An earlier start would give a truncated or missing read-in pulse. Only
  // read-in is checked: read-out starts T_STORE later.
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
        // Run disabled: everything off and held in clear.
        S_IDLE: begin
          arm <= 1'b0;  clr_kill <= '1;  clr_fired <= 1'b1;  on <= '0;  p_en <= 1'b0;
          if (run_en) begin
            state <= S_PREP;
            timer <= '0;
          end
        end

        // State preparation: all channels on, latches held in clear, so a
        // herald now has no effect. PREP lasts T_PREP + 1 cycles; arm rises
        // three REL cycles later. After a completed attempt, the next herald
        // can therefore be taken T_PREP + 4 cycles after T_END is detected.
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
        // Channels stay on from PREP. With an invalid snapshot the sequencer
        // returns to PREP and takes a new snapshot there, so it does not arm
        // until the host has written a consistent configuration.
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
            // arm rises at the next clock edge, i.e. at phys ns now_ns + 8.
            state        <= S_ARMED;
            arm          <= 1'b1;
            arm_lim      <= now_ns + NS_W'(8) - NS_W'(GUARD_NS);
            cand_pending <= 1'b0;
            noedge_age   <= '0;
          end
        end

        // Waiting for a herald. A herald edge reaches the sequencer twice,
        // through two paths with different latencies:
        //   fired_s   - the latch fired (Path A), via a 3-flop synchronizer;
        //   edge_valid / edge_ns - the serdes timestamp, via the input
        //               pipeline (qm_edge_capture).
        // The herald is accepted only when both are present. Each may wait
        // up to CONFIRM_CYC cycles for the other:
        //   fired_s, no candidate -> no-edge: the latch fired but the serdes
        //                            saw nothing (pulse shorter than one
        //                            sample, or clock stopped). Abort.
        //   candidate, no fired_s -> race: the serdes saw an edge that did
        //                            not set the latch (just before arm, or
        //                            too short for the flop). Drop the
        //                            candidate and stay armed.
        // The latches cannot be cleared here (rule 2), so fired_s stays high
        // once set and the attempt must leave through ACTIVE or ABORT.
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
            // The latch has fired: disarm so that later heralds cannot affect
            // Path A. The immediate channels are already off.
            arm <= 1'b0;
            // Accept only a registered candidate; an edge arriving in this
            // very cycle is accepted one cycle later (noedge_age < CONFIRM).
            if (cand_pending) begin
              // Herald accepted. All times of this attempt are fixed now,
              // relative to the herald timestamp cand_ts (phys ns of the
              // first serdes sample at which the herald was high):
              //   read-in  pulse starts at cand_ts + D_READIN
              //   read-out pulse starts at cand_ts + D_READIN + T_STORE
              //   both pulses are W_CTRL ns wide
              //   channel i off at cand_ts + T_OFF[i], back on at
              //   cand_ts + T_REST[i]; attempt ends at cand_ts + T_END.
              // The 32-bit times wrap; acc_ts keeps the full 64-bit stamp.
              // ev_acc pushes acc_ts into the timestamp FIFO, even if the
              // attempt is then aborted as late.
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
                // Hand the pulse times to qm_pulse_unit. It drives each
                // output high for phys ns in [start, start + width), so the
                // sequencer does nothing at the pulse times themselves.
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

        // Attempt in progress. arm is low, so further heralds are rejected
        // and cannot affect Path A. The control pulses run on their own in
        // qm_pulse_unit. Off / restore events and the end of the attempt are
        // compared at the start of each cycle and change at the next clock
        // edge, so they are on the 8 ns grid: 8 to 15 ns after the programmed
        // phys-ns time, and never earlier. Unlike the control pulses, this
        // path is not latency-compensated.
        S_ACTIVE: begin
          arm   <= 1'b0;
          timer <= timer + 1;
          // HERALD_FWD (Path A `fired`) went high at the herald. Clear it
          // FWD_W + 1 cycles after the accept, so it is longer than FWD_W by
          // the herald-to-accept latency.
          if (timer >= 32'(c_fwd_w)) clr_fired <= 1'b1;

          // Per channel:
          //   immediate (c_imm = 1): switched off at the herald by its kill
          //     flop (Path A); T_OFF is not used.
          //   delayed   (c_imm = 0): the output LUT ignores the kill flop;
          //     on[i] drops at T_OFF.
          //   both: at T_REST the kill flop is cleared (safe, arm is low) and
          //     on[i] is set again. Restore takes priority over off, and each
          //     channel is restored once. It stays on until the next herald;
          //     clr_kill is released in the next REL.
          for (int i = 0; i < N_KILL; i++) begin
            if (!restored[i] && due(t_rest_abs[i])) begin
              restored[i] <= 1'b1;
              clr_kill[i] <= 1'b1;   // safe: arm is low
              on[i]       <= 1'b1;
            end else if (!c_imm[i] && !restored[i] && due(t_off_abs[i])) begin
              on[i] <= 1'b0;
            end
          end

          // qm_cfg_check guarantees that both pulses and all restores lie
          // within T_END. At T_END the attempt is complete and PREP starts
          // the preparation for the next herald.
          if (!run_en || abort_req) begin
            state <= S_ABORT;
            p_en  <= 1'b0;                 // cancel pending pulses immediately
            // (words already in the output pipeline, about OUT_LAT_CYC
            // cycles, are still emitted)
          end else if (due(t_end_abs)) begin
            ev_done <= 1'b1;
            p_en    <= 1'b0;
            state   <= S_PREP;
            timer   <= '0;
          end
        end

        // Return all outputs to a safe state in one cycle. Clearing the
        // latches restores the immediate channels and ends HERALD_FWD. With
        // run_en = 1 the channels stay on and the cycle restarts in PREP.
        // ev_abort is raised for every abort, so late and no-edge aborts
        // count in CNT_ABORT as well as in CNT_LATE / CNT_NOEDGE.
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
