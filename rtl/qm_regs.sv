// SPDX-License-Identifier: Apache-2.0
// qm_regs.sv - configuration / status registers and statistics counters.
//
// Simple synchronous bus: a read returns data in the cycle after `re`.
// Reset values reproduce the representative 160 ns storage cycle of
// Buser et al. 2022; see docs/01 for the classification of each value.
// Every timing value must be recalibrated on the real setup (cable, driver,
// SOA, EOM and pulse-generator latencies are not part of these numbers).

import qm_pkg::*;

module qm_regs
(
  input  logic              clk,
  input  logic              rst,

  input  logic              we,
  input  logic              re,
  input  logic [7:0]        addr,
  input  logic [31:0]       wdata,
  output logic [31:0]       rdata,

  // configuration
  output logic              run_en,
  output logic              abort_req,
  output logic [N_KILL-1:0] cfg_imm,
  output logic [N_KILL-1:0] cfg_pol,
  output logic              cfg_fwd_pol,
  output logic              cfg_ctrl_pol,
  output logic              cfg_merge,
  output logic [31:0]       cfg_t_prep,
  output logic [31:0]       cfg_d_readin,
  output logic [31:0]       cfg_t_store,
  output logic [15:0]       cfg_w_ctrl,
  output logic [N_KILL-1:0][31:0] cfg_t_off,
  output logic [N_KILL-1:0][31:0] cfg_t_rest,
  output logic [31:0]       cfg_t_end,
  output logic [15:0]       cfg_fwd_w,

  // status
  input  logic [3:0]        state,         // state_t encoding
  input  logic              cfg_err,
  input  logic              arm,
  input  logic [N_KILL-1:0] kill_s,
  input  logic              fired_s,
  input  logic              cand_pending,
  input  logic [3:0]        raw_delta,    // raw herald edges since last cycle (Gray sync)
  input  logic              ev_edge,
  input  logic              ev_acc,
  input  logic              ev_rej,
  input  logic              ev_race,
  input  logic              ev_abort,
  input  logic              ev_noedge,
  input  logic              ev_late,
  input  logic              ev_done,
  input  logic [63:0]       acc_ts
);

  logic        clr_cnt;
  logic [31:0] cnt_raw, cnt_edge, cnt_acc, cnt_rej, cnt_race, cnt_abort, cnt_noedge,
               cnt_done, cnt_late;
  logic [31:0] last_hi_shadow, fifo_hi_shadow;
  logic [63:0] last_ts;

  logic        fifo_pop;
  logic [63:0] fifo_dout;
  logic [15:0] fifo_level, fifo_ovf;

  qm_fifo #(.W(64), .DEPTH(64)) u_fifo (
    .clk, .rst,
    .push(ev_acc), .din(acc_ts),
    .pop(fifo_pop), .dout(fifo_dout),
    .level(fifo_level), .overflows(fifo_ovf)
  );

  function automatic logic [31:0] bump(input logic [31:0] c, input logic inc);
    bump = (inc && c != '1) ? c + 1 : c;
  endfunction

  always_ff @(posedge clk) begin
    abort_req <= 1'b0;
    clr_cnt   <= 1'b0;

    if (rst) begin
      run_en        <= 1'b0;
      cfg_imm       <= '1;
      cfg_pol       <= '0;
      cfg_fwd_pol   <= 1'b0;
      cfg_ctrl_pol  <= 1'b0;
      cfg_merge     <= 1'b0;
      cfg_t_prep    <= 32'd250;   // 2 us minimum preparation (paper)
      cfg_d_readin  <= 32'd270;   // herald -> signal photon at memory (paper, approx.)
      cfg_t_store   <= 32'd160;   // representative storage time (paper)
      cfg_w_ctrl    <= 16'd10;    // trigger width for the pulse generator (assumption)
      cfg_t_off     <= '0;
      cfg_t_rest    <= {32'd520, 32'd560, 32'd560}; // [2]..[0], read from Fig. 4, approx.
      cfg_t_end     <= 32'd600;
      cfg_fwd_w     <= 16'd4;
      last_ts       <= '0;
    end else begin
      if (we) begin
        unique case (addr)
          A_CTRL: begin
            run_en    <= wdata[0];
            abort_req <= wdata[1];
            clr_cnt   <= wdata[2];
          end
          A_CHCFG: begin
            cfg_imm      <= wdata[N_KILL-1:0];
            cfg_pol      <= wdata[8 +: N_KILL];
            cfg_fwd_pol  <= wdata[11];
            cfg_ctrl_pol <= wdata[12];
            cfg_merge    <= wdata[16];
          end
          A_T_PREP:   cfg_t_prep    <= wdata;
          A_D_READIN: cfg_d_readin  <= wdata;
          A_T_STORE:  cfg_t_store   <= wdata;
          A_W_CTRL:   cfg_w_ctrl    <= wdata[15:0];
          A_T_OFF0:   cfg_t_off[0]  <= wdata;
          A_T_OFF1:   cfg_t_off[1]  <= wdata;
          A_T_OFF2:   cfg_t_off[2]  <= wdata;
          A_T_REST0:  cfg_t_rest[0] <= wdata;
          A_T_REST1:  cfg_t_rest[1] <= wdata;
          A_T_REST2:  cfg_t_rest[2] <= wdata;
          A_T_END:    cfg_t_end     <= wdata;
          A_FWD_W:    cfg_fwd_w     <= wdata[15:0];
          default: ;
        endcase
      end
      if (ev_acc) last_ts <= acc_ts;
    end
  end

  // counters
  always_ff @(posedge clk) begin
    if (rst || clr_cnt) begin
      cnt_raw  <= '0; cnt_edge  <= '0; cnt_acc    <= '0; cnt_rej  <= '0; cnt_race <= '0;
      cnt_abort <= '0; cnt_noedge <= '0; cnt_done <= '0; cnt_late <= '0;
    end else begin
      cnt_raw    <= cnt_raw + 32'(raw_delta);
      cnt_edge   <= bump(cnt_edge,   ev_edge);
      cnt_acc    <= bump(cnt_acc,    ev_acc);
      cnt_rej    <= bump(cnt_rej,    ev_rej);
      cnt_race   <= bump(cnt_race,   ev_race);
      cnt_abort  <= bump(cnt_abort,  ev_abort);
      cnt_noedge <= bump(cnt_noedge, ev_noedge);
      cnt_done   <= bump(cnt_done,   ev_done);
      cnt_late   <= bump(cnt_late,   ev_late);
    end
  end

  // Read path, two registered levels (timing: the single 30-way mux on the
  // UART address was the slowest clk_sys path after place & route).
  //   stage 1 (cycle after re, as before): capture the addressed value in one
  //            of four groups of eight registers (addr[6:5] / addr[4:2]); all
  //            read side effects (HI shadow latch, FIFO pop) happen here, so
  //            the sampled values and their coherence are unchanged
  //   stage 2 (one cycle later): select the group, or 0xDEADBEEF for an
  //            unmapped address
  // The UART bridge consumes rdata one cycle later and absorbs that cycle,
  // so the reply timing on the serial line is unchanged.
  // 64-bit values are read LO first, which latches HI coherently.
  logic [31:0] grp [4];
  logic [1:0]  rd_grp;
  logic        rd_valid_addr, rd_pend;

  function automatic logic mapped(input logic [7:0] a);
    mapped = (a[1:0] == 2'b00) && (a[7] == 1'b0) && (a < 8'h78);
  endfunction

  always_ff @(posedge clk) begin
    fifo_pop <= 1'b0;
    rd_pend  <= 1'b0;
    if (rst) begin
      rdata          <= '0;
      last_hi_shadow <= '0;
      fifo_hi_shadow <= '0;
      rd_grp         <= '0;
      rd_valid_addr  <= 1'b0;
    end else begin
      if (re) begin
        rd_pend       <= 1'b1;
        rd_grp        <= addr[6:5];
        rd_valid_addr <= mapped(addr);
        unique case (addr[4:2])                      // 0x00 .. 0x1C
          A_ID[4:2]:         grp[0] <= ID_VALUE;
          A_CTRL[4:2]:       grp[0] <= {31'd0, run_en};
          A_STATUS[4:2]:     grp[0] <= {20'd0, run_en, cand_pending, fired_s, kill_s, cfg_err, arm, state};
          A_CHCFG[4:2]:      grp[0] <= {15'd0, cfg_merge, 3'd0, cfg_ctrl_pol, cfg_fwd_pol,
                           3'(cfg_pol), 5'd0, 3'(cfg_imm)};
          A_T_PREP[4:2]:     grp[0] <= cfg_t_prep;
          A_D_READIN[4:2]:   grp[0] <= cfg_d_readin;
          A_T_STORE[4:2]:    grp[0] <= cfg_t_store;
          A_W_CTRL[4:2]:     grp[0] <= {16'd0, cfg_w_ctrl};
        endcase
        unique case (addr[4:2])                      // 0x20 .. 0x3C
          A_T_OFF0[4:2]:     grp[1] <= cfg_t_off[0];
          A_T_OFF1[4:2]:     grp[1] <= cfg_t_off[1];
          A_T_OFF2[4:2]:     grp[1] <= cfg_t_off[2];
          A_T_REST0[4:2]:    grp[1] <= cfg_t_rest[0];
          A_T_REST1[4:2]:    grp[1] <= cfg_t_rest[1];
          A_T_REST2[4:2]:    grp[1] <= cfg_t_rest[2];
          A_T_END[4:2]:      grp[1] <= cfg_t_end;
          A_FWD_W[4:2]:      grp[1] <= {16'd0, cfg_fwd_w};
        endcase
        unique case (addr[4:2])                      // 0x40 .. 0x5C
          A_CNT_RAW[4:2]:    grp[2] <= cnt_raw;
          A_CNT_EDGE[4:2]:   grp[2] <= cnt_edge;
          A_CNT_ACC[4:2]:    grp[2] <= cnt_acc;
          A_CNT_REJ[4:2]:    grp[2] <= cnt_rej;
          A_CNT_RACE[4:2]:   grp[2] <= cnt_race;
          A_CNT_ABORT[4:2]:  grp[2] <= cnt_abort;
          A_CNT_NOEDGE[4:2]: grp[2] <= cnt_noedge;
          A_CNT_DONE[4:2]:   grp[2] <= cnt_done;
        endcase
        unique case (addr[4:2])                      // 0x60 .. 0x7C
          A_LAST_TS_LO[4:2]: grp[3] <= last_ts[31:0];
          A_LAST_TS_HI[4:2]: grp[3] <= last_hi_shadow;
          A_FIFO_STAT[4:2]:  grp[3] <= {fifo_ovf, fifo_level};
          A_FIFO_LO[4:2]:    grp[3] <= fifo_dout[31:0];
          A_FIFO_HI[4:2]:    grp[3] <= fifo_hi_shadow;
          A_CNT_LATE[4:2]:   grp[3] <= cnt_late;
          default: grp[3] <= 32'hDEAD_BEEF;
        endcase
        // side effects: exact-address decode, same cycle as before
        if (addr == A_LAST_TS_LO) last_hi_shadow <= last_ts[63:32];
        if (addr == A_FIFO_LO)    fifo_hi_shadow <= fifo_dout[63:32];
        if (addr == A_FIFO_HI)    fifo_pop       <= 1'b1;
      end
      if (rd_pend)
        rdata <= rd_valid_addr ? grp[rd_grp] : 32'hDEAD_BEEF;
    end
  end

endmodule
