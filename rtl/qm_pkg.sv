// SPDX-License-Identifier: Apache-2.0
// qm_pkg.sv - shared constants for the quantum-memory herald controller.
//
// Time units used throughout the design
//   * "cycle"  : one period of clk_sys (125 MHz, 8 ns).
//   * "ns"     : one serdes bit (1 Gb/s DDR, 8 bits per clk_sys cycle).
//                All experiment timing registers are in ns and use a 32-bit
//                wrap-safe timebase (wraps every 4.29 s; no event is ever
//                scheduled more than 2^31 ns ahead).
//
// Physical time frame ("phys ns")
//   phys_ns = now_cyc * 8 + bit, where now_cyc is the free-running cycle
//   counter value during the clk_sys cycle in question. The input and
//   output serdes pipelines are compensated by IN_LAT_CYC / OUT_LAT_CYC so
//   that a herald sampled at phys ns T produces a control edge at phys ns
//   T + D. Pad/buffer insertion delays are NOT part of this frame; they are
//   a constant offset that must be measured on hardware (docs/03).

package qm_pkg;

  localparam int unsigned SERDES_W = 8;   // bits per clk_sys cycle
  localparam int unsigned NS_W     = 32;  // scheduling timebase width

  // Path A channels driven by herald-clocked kill flops.
  localparam int unsigned N_KILL   = 3;
  localparam int unsigned CH_PUMP   = 0;  // D1 optical pumping SOA enable
  localparam int unsigned CH_REPUMP = 1;  // D2 repumping SOA enable
  localparam int unsigned CH_SOURCE = 2;  // SPDC source (Pockels cell) enable

  // Register map (byte addresses, 32-bit registers).
  localparam logic [7:0] A_ID         = 8'h00; // RO 'QMC1'
  localparam logic [7:0] A_CTRL       = 8'h04; // RW [0] run_en [1] abort (W1P) [2] clr_cnt (W1P)
  localparam logic [7:0] A_STATUS     = 8'h08; // RO see qm_regs
  localparam logic [7:0] A_CHCFG      = 8'h0C; // RW [2:0] immediate mask, [10:8] polarity, [11] fwd pol,
                                               //    [12] ctrl pol, [16] merge readout into CTRL_A
  localparam logic [7:0] A_T_PREP     = 8'h10; // RW cycles, minimum state-preparation time
  localparam logic [7:0] A_D_READIN   = 8'h14; // RW ns, herald -> read-in control trigger
  localparam logic [7:0] A_T_STORE    = 8'h18; // RW ns, read-in -> read-out
  localparam logic [7:0] A_W_CTRL     = 8'h1C; // RW ns, control trigger width
  localparam logic [7:0] A_T_OFF0     = 8'h20; // RW ns, herald -> off (only if channel not immediate)
  localparam logic [7:0] A_T_OFF1     = 8'h24;
  localparam logic [7:0] A_T_OFF2     = 8'h28;
  localparam logic [7:0] A_T_REST0    = 8'h2C; // RW ns, herald -> restore (channel back on)
  localparam logic [7:0] A_T_REST1    = 8'h30;
  localparam logic [7:0] A_T_REST2    = 8'h34;
  localparam logic [7:0] A_T_END      = 8'h38; // RW ns, herald -> end of active window
  localparam logic [7:0] A_FWD_W      = 8'h3C; // RW cycles, width of HERALD_FWD pulse
  localparam logic [7:0] A_CNT_RAW    = 8'h40; // RO herald edges (async Gray counter, all states)
  localparam logic [7:0] A_CNT_EDGE   = 8'h44; // RO herald edges seen by serdes capture
  localparam logic [7:0] A_CNT_ACC    = 8'h48; // RO accepted heralds (experiment started)
  localparam logic [7:0] A_CNT_REJ    = 8'h4C; // RO edges rejected (not armed / busy)
  localparam logic [7:0] A_CNT_RACE   = 8'h50; // RO edges seen while armed that did not fire the latch
  localparam logic [7:0] A_CNT_ABORT  = 8'h54; // RO aborted cycles
  localparam logic [7:0] A_CNT_NOEDGE = 8'h58; // RO latch fired but no serdes edge (pulse too short?)
  localparam logic [7:0] A_CNT_DONE   = 8'h5C; // RO completed storage/retrieval cycles
  localparam logic [7:0] A_LAST_TS_LO = 8'h60; // RO last accepted herald, phys ns [31:0] (latches HI)
  localparam logic [7:0] A_LAST_TS_HI = 8'h64; // RO                         [63:32]
  localparam logic [7:0] A_FIFO_STAT  = 8'h68; // RO [15:0] level, [31:16] overflow count
  localparam logic [7:0] A_FIFO_LO    = 8'h6C; // RO head timestamp [31:0] (latches HI)
  localparam logic [7:0] A_FIFO_HI    = 8'h70; // RO head timestamp [63:32], read pops
  localparam logic [7:0] A_CNT_LATE   = 8'h74; // RO cycles aborted because a pulse was scheduled too late

  localparam logic [31:0] ID_VALUE = 32'h514D_4331; // "QMC1"

  // Sequencer states (exported in STATUS[3:0]).
  typedef enum logic [3:0] {
    S_IDLE   = 4'd0,  // run disabled, all beams off, latches held clear
    S_PREP   = 4'd1,  // beams on, latches clear, wait T_PREP
    S_REL    = 4'd2,  // release latch clears while arm is low (safe)
    S_ARMED  = 4'd3,  // arm high, waiting for herald
    S_ACTIVE = 4'd4,  // herald accepted: storage / retrieval sequence
    S_ABORT  = 4'd5   // cancel sequence, restore outputs
  } state_t;

endpackage
