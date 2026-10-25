// SPDX-License-Identifier: Apache-2.0
// qm_sequencer.sv - experiment cycle controller (synchronous, clk_sys).
//
// One experiment: prepare the atoms (beams and photon source on), wait for a
// herald (detector pulse: "a photon is on its way to the memory"), switch
// beams off, fire a write pulse (read-in, stores the photon) and later a read
// pulse (read-out, retrieves it), restore the beams, prepare again.
//
// The fast reaction to the herald (beams off within ns) is done without any
// clock by qm_herald_latch (Path A). This FSM only arms and clears those
// latches and does everything that can wait a few clock cycles.
//
// ===========================================================================
// Notation
// ===========================================================================
//   t0     herald rising edge at the input (asynchronous, any time).
//   ts     serdes timestamp of that edge = first 1 ns sample with the herald
//          high, t0 < ts <= t0 + 1 ns. ALL programmed times are offsets
//          from ts, not from t0:  t_write = ts + D_READIN,
//          t_read = t_write + T_STORE, t_off[i] = ts + T_OFF[i],
//          t_rest[i] = ts + T_REST[i], t_end = ts + T_END.
//   cycle  one clk_sys period, 8 ns. Cycle k covers phys ns [8k, 8k + 8).
//   c0     the cycle in which t0 falls.
//
//   Kind   ASYNC  hardware event without clock (Path A flip-flops)
//          TRANS  synchronous FSM state transition
//          STAY   synchronous action, FSM stays in its state
//          PULSE  output bits produced by qm_pulse_unit; FSM not involved
//
// Every output of this FSM is a register: what the code assigns while in
// state X during cycle k is visible in cycle k + 1, together with the new
// state. "Cycle" columns below give the cycle in which the effect is
// visible, as observed in testbench T3 (IN_LAT_CYC = 1 in qm_top, the
// OUT_LAT_CYC parameter of this module = 4). They shift with the real serdes
// latencies.
//
// ===========================================================================
// Normal experiment, step by step
// ===========================================================================
//
// Before the herald
//  #  When                 Kind   State          What changes
//  1  run_en = 1           TRANS  IDLE -> PREP   timer <= 0
//  2  every PREP cycle     STAY   PREP           on = all 1 (channels on), clr_kill = clr_fired
//                                                = 1 (latches held clear), arm = 0, timer + 1.
//                                                A herald here changes no output; its
//                                                serdes edge counts as rejected.
//  3  timer == T_PREP      TRANS  PREP -> REL    cfg_* copied to c_* (snapshot), timer <= 0.
//     (PREP lasted                               From now on this cycle uses only c_*.
//      T_PREP + 1 cycles)
//  4  from 2nd REL cycle   STAY   REL            clr_kill = clr_fired = 0 (clears released;
//                                                arm still 0, so a herald still has no effect).
//  5  REL, timer == 2      TRANS  REL -> ARMED   arm = 1 from the next clock edge, phys
//                                                now_ns + 8. arm_lim = that time - GUARD_NS.
//  -  ARMED                STAY   ARMED          nothing changes until a herald arrives.
//
// The herald (T3: t0 is 3.2 ns into c0, ts = t0 + 0.8 ns)
//  #  When  Cycle          Kind   State          What changes
//  6  t0    c0             ASYNC  ARMED          kill flops and `fired` set (they are clocked
//                                                by the herald, CE = arm). Immediate channels
//                                                switch off, HERALD_FWD rises. The FSM sees
//                                                none of this yet; see "Why not at t0".
//  7  ts+12 c0+2           STAY   ARMED          edge_valid, edge_ns = ts from the serdes
//                                                (c0 + IN_LAT_CYC + 1). Edge qualifies:
//                                                cand_ts <= ts, cand_rd <= t_write,
//                                                cand_pending <= 1 (visible in c0+3).
//  8  ts+20 c0+3           TRANS  ARMED ->       fired_s = 1 (3-flop synchronizer) and
//                                 ACTIVE         cand_pending = 1: herald accepted. The values
//                                                in the box below are written; visible c0+4.
//
//     Written on accept (last ARMED cycle), constant for the rest of ACTIVE:
//       acc_ts          <= ts (64 bit)  -> LAST_TS register and timestamp FIFO
//       p_readin_start  <= t_write
//       p_readout_start <= t_read
//       p_width         <= W_CTRL
//       p_en            <= 1            -> qm_pulse_unit starts comparing
//       t_off_abs[i]    <= t_off[i],  t_rest_abs[i] <= t_rest[i],  t_end_abs <= t_end
//       arm <= 0, timer <= 0, restored <= 0, ev_acc
//
// During ACTIVE (T3: D_READIN 270, T_STORE 160, W_CTRL 10, T_REST 560/560/520,
// T_END 600, FWD_W 4, all channels immediate)
//  #  When      Cycle      Kind   State          What changes
//  9  FWD_W+1   c0+9       STAY   ACTIVE         clr_fired = 1 -> `fired` cleared (ASYNC
//     cycles                                     clear), HERALD_FWD ends.
//     after accept
// 10  t_off[i]  -          STAY   ACTIVE         delayed channels only (c_imm[i] = 0):
//                                                on[i] = 0, channel switches off. Immediate
//                                                channels: nothing (already off since t0).
// 11  t_write   -          PULSE  ACTIVE         no FSM action. CTRL_A goes high at t_write
//                                                for W_CTRL ns. T3: words of phys
//                                                [ts+268, ts+276) = 11111100 and
//                                                [ts+276, ts+284) = 00001111 (bit 0 earliest),
//                                                computed from p_* OUT_LAT_CYC cycles earlier
//                                                (ctrl_a_word register: c0+33, c0+34).
//     t_read    -          PULSE  ACTIVE         same for CTRL_B (CTRL_A too if merged).
// 12  t_rest[i] c0+67      STAY   ACTIVE         clr_kill[i] = 1, on[i] = 1, restored[i] = 1:
//               (ch 2),                          channel back on (kill flop cleared).
//               c0+72
// 13  t_end     c0+77      TRANS  ACTIVE -> PREP ev_done, p_en = 0, timer <= 0.
//
// Back to the next herald
// 14  +T_PREP+1 c0+328     TRANS  PREP -> REL    step 3 with a new snapshot
//     cycles
//     +3 cycles c0+331     TRANS  REL -> ARMED   step 5. In T3, ARMED again at ts + 2644 ns.
//
// Why the FSM does not change state at t0
//   The herald is asynchronous. Path A reacts at t0 without a clock. The FSM
//   learns of it only through two delayed, synchronous paths, and waits until
//   both have arrived:
//     fired_s    `fired` after a 3-flop synchronizer (metastability).
//                c0+3 in T3; one cycle later if t0 is too close to a clock edge.
//     edge_ns    the timestamp ts, after the input serdes pipeline.
//   Deciding from fired_s means the FSM, the counters and the pulses follow
//   the same `fired` flag that switched the beams off.
//
// Programmed time vs. the cycle in which it happens
//   t_write, t_read  exact to 1 ns. The FSM writes the start time once, at
//       accept. qm_pulse_unit compares every output word with it, so the
//       edge is placed at bit (t mod 8) of the word for phys [8k, 8k + 8).
//       That word is computed OUT_LAT_CYC cycles before it leaves the pin,
//       so t_write must lie far enough after accept (exception E5).
//   t_off, t_rest, t_end  quantized to 8 ns. due(t) is checked at the start
//       of every cycle (now_ns = 8k); the first cycle with 8k >= t executes
//       the action, and the register output changes at 8(k + 1). The effect
//       is therefore 8 to 15 ns after t, never earlier (T3: always +12 ns),
//       and it is not latency-compensated. If t has already passed when
//       ACTIVE begins, the action runs in the first ACTIVE cycle.
//
// ===========================================================================
// Exceptional paths
// ===========================================================================
//  E1  Host abort or run_en = 0, in REL, ARMED or ACTIVE: -> ABORT. Ignored
//      in IDLE, PREP and ABORT. ABORT goes to PREP if run_en = 1, so an abort
//      restarts the cycle; only run_en = 0 stops it (-> IDLE). From ACTIVE,
//      p_en drops at once, but output words already computed (about
//      OUT_LAT_CYC cycles) still leave the pin. A candidate pending in ARMED
//      is discarded without ev_acc / ev_rej / ev_race.
//  E2  Invalid snapshot (c_err at REL, timer == 2): REL -> PREP, no ABORT and
//      no counter. PREP takes a fresh snapshot, so the FSM never arms until
//      the host has written a consistent configuration.
//  E3  No timestamp (no-edge): fired_s = 1 but no candidate for
//      CONFIRM_CYC + 1 cycles. The latch fired, the serdes saw nothing (pulse
//      shorter than one sample, or clock stopped). ev_noedge, ARMED -> ABORT.
//  E4  Race: candidate but fired_s stays 0 for CONFIRM_CYC + 1 cycles. The
//      edge did not set the latch (just before arm, or too short for the
//      flop). ev_race, candidate dropped, FSM stays ARMED. While a candidate
//      is pending, further edges are rejected; if one of them fires the
//      latch, it is accepted with the earlier candidate's timestamp.
//  E5  Late: on accept, t_write is before the first output word that can
//      still be produced (first_base). The pulse would be truncated or
//      missing. ev_acc (timestamp still in FIFO) and ev_late, ARMED -> ABORT.
//      T3: first_base = ts + 60 ns, so D_READIN >= 60 ns passes.
//  ABORT lasts one cycle: arm = 0, clr_* = 1 (latches cleared: immediate
//  channels on again, HERALD_FWD ends), p_en = 0, on = run_en ? all 1 : 0,
//  ev_abort. E3 and E5 therefore also count in CNT_ABORT.
//
// Edge accounting (checked in the testbench): every serdes edge raises
// ev_edge and ends as exactly one of ev_rej (not ARMED, candidate already
// pending, or before arm_lim), ev_acc or ev_race:
//   cnt_edge == cnt_acc + cnt_rej + cnt_race + (candidate pending ? 1 : 0)
// The exception is a candidate discarded by E1.

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
  // Working copy, captured when leaving PREP (step 3) so timing is stable per
  // cycle. Host writes take effect at the next snapshot; cfg_t_prep is read
  // directly by PREP. imm_act feeds the Path A output LUTs (qm_core).
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
  // now_ns: phys ns at the start of the current cycle (8k), 32-bit wrapping.
  logic [NS_W-1:0] now_ns;
  assign now_ns = NS_W'(now_cyc << 3);

  // due(t) = "t has been reached at the start of this cycle". Wrap-safe for
  // t within 2^31 ns of now (qm_cfg_check keeps offsets below 2^31).
  function automatic logic due(input logic [NS_W-1:0] t);
    logic [NS_W-1:0] d;
    d   = now_ns - t;
    due = !d[NS_W-1];             // (now - t) >= 0, wrap-safe
  endfunction

  // ------------------------------------------------------------- state
  logic [31:0]       timer;       // PREP: prep cycles, REL: 0..2, ACTIVE: cycles since accept
  logic [NS_W-1:0]   arm_lim;     // arm time minus guard band
  logic [63:0]       cand_ts;     // timestamp ts of the candidate edge
  logic [NS_W-1:0]   cand_rd;     // cand_ts + D_READIN
  logic [7:0]        cand_age;    // cycles the candidate has waited for fired_s (E4)
  logic [7:0]        noedge_age;  // cycles fired_s has waited for a candidate (E3)
  logic [N_KILL-1:0] restored;

  // Absolute event times of the active cycle, computed once on accept so
  // that every compare in S_ACTIVE is a single subtraction against now.
  logic [N_KILL-1:0][NS_W-1:0] t_off_abs, t_rest_abs;
  logic [NS_W-1:0]             t_end_abs;

  // Edge qualifies as the firing edge if it is not clearly before arm.
  // The timestamp arrives cycles after the edge, so an edge reported in
  // ARMED may physically precede arm: edges before arm_lim are rejected.
  // Edges in the GUARD_NS band may still have fired the latch; fired_s
  // decides (step 8 or E4).
  logic edge_qual;
  assign edge_qual = edge_valid && (state == S_ARMED) && !cand_pending &&
                     ($signed(NS_W'(edge_ns) - arm_lim) >= 0);

  // Late check: the read-in edge must lie after the first word that can
  // still be produced once p_en rises next cycle. first_base is registered
  // and equals ((now_cyc + 1 + OUT_LAT_CYC) * 8) in the cycle it is used.
  // (E5; only read-in is checked, read-out is T_STORE later.)
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
        // Step 1. Run disabled: channels off, latches held clear.
        S_IDLE: begin
          arm <= 1'b0;  clr_kill <= '1;  clr_fired <= 1'b1;  on <= '0;  p_en <= 1'b0;
          if (run_en) begin
            state <= S_PREP;
            timer <= '0;
          end
        end

        // Step 2: prepare for T_PREP + 1 cycles. Step 3: snapshot, -> REL.
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

        // Step 4: release clears while arm is still low (rule 2 in
        // qm_herald_latch). Step 5: arm in the third REL cycle (or E2).
        S_REL: begin
          arm <= 1'b0;  clr_kill <= '0;  clr_fired <= 1'b0;
          timer <= timer + 1;
          if (!run_en || abort_req) begin
            state <= S_ABORT;
          // c_err (two-stage qm_cfg_check) reflects the snapshot taken on
          // entry to S_REL exactly from timer == 2 on; testbench T17 fails if
          // this budget is exceeded.
          end else if (timer == 32'd2 && c_err) begin
            state <= S_PREP;               // E2: invalid snapshot, never arm with it
            timer <= '0;
          end else if (timer == 32'd2) begin
            state        <= S_ARMED;
            arm          <= 1'b1;
            arm_lim      <= now_ns + NS_W'(8) - NS_W'(GUARD_NS);
            cand_pending <= 1'b0;
            noedge_age   <= '0;
          end
        end

        // Steps 7 and 8. The herald itself (step 6) already happened in Path A;
        // this state collects its two delayed reports, the timestamp
        // (edge_valid) and the latch flag (fired_s), and accepts when both are
        // present. Exceptions E1, E3, E4, E5.
        S_ARMED: begin
          // Step 7: register the timestamp as candidate
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
            arm <= 1'b0;                   // latch fired: disarm
            // Accept only a registered candidate; an edge arriving in this
            // very cycle is accepted one cycle later (noedge_age < CONFIRM).
            if (cand_pending) begin
              // Step 8: accept. Fix all times of this experiment (see box).
              cand_pending <= 1'b0;
              acc_ts       <= cand_ts;
              t_end_abs    <= NS_W'(cand_ts) + c_t_end;
              for (int i = 0; i < N_KILL; i++) begin
                t_off_abs[i]  <= NS_W'(cand_ts) + c_t_off[i];
                t_rest_abs[i] <= NS_W'(cand_ts) + c_t_rest[i];
              end
              ev_acc       <= 1'b1;
              if (late_now) begin
                ev_late <= 1'b1;           // E5
                state   <= S_ABORT;
              end else begin
                // Hand the pulse times to qm_pulse_unit (step 11).
                state           <= S_ACTIVE;
                timer           <= '0;
                restored        <= '0;
                p_en            <= 1'b1;
                p_readin_start  <= cand_rd;
                p_readout_start <= cand_rd + c_t_store;
                p_width         <= c_w_ctrl;
              end
            end else if (noedge_age >= 8'(CONFIRM_CYC)) begin
              ev_noedge <= 1'b1;           // E3
              state     <= S_ABORT;
            end else begin
              noedge_age <= noedge_age + 1;
            end
          end else if (cand_pending && cand_age >= 8'(CONFIRM_CYC)) begin
            // E4: saw an edge but the latch did not fire: the edge lost the
            // race against arm (or the pulse was too short for the latch).
            ev_race      <= 1'b1;
            cand_pending <= 1'b0;
          end
        end

        // Steps 9 to 13. The FSM stays here until t_end; the write and read
        // pulses (step 11) need no action, qm_pulse_unit produces them from
        // p_* written at accept. Exception E1.
        S_ACTIVE: begin
          arm   <= 1'b0;
          timer <= timer + 1;
          if (timer >= 32'(c_fwd_w)) clr_fired <= 1'b1;   // step 9: end HERALD_FWD

          // Steps 10 and 12, per channel. Restore wins over off, once.
          for (int i = 0; i < N_KILL; i++) begin
            if (!restored[i] && due(t_rest_abs[i])) begin
              restored[i] <= 1'b1;         // step 12
              clr_kill[i] <= 1'b1;   // safe: arm is low
              on[i]       <= 1'b1;
            end else if (!c_imm[i] && !restored[i] && due(t_off_abs[i])) begin
              on[i] <= 1'b0;               // step 10, delayed channels only
            end
          end

          if (!run_en || abort_req) begin
            state <= S_ABORT;
            p_en  <= 1'b0;                 // cancel pending pulses immediately
          end else if (due(t_end_abs)) begin
            ev_done <= 1'b1;               // step 13: experiment complete
            p_en    <= 1'b0;
            state   <= S_PREP;
            timer   <= '0;
          end
        end

        // One cycle: return everything to a safe state (see "ABORT lasts").
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
