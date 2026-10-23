// SPDX-License-Identifier: Apache-2.0
// tb_qm_top.sv - self-checking functional testbench for qm_top.
//
// Uses the behavioral I/O models (zero buffer delay, ideal 1 ns sampling),
// so it verifies FUNCTION only: ordering, persistence, arming, accounting,
// 1 ns scheduling arithmetic, clock independence of Path A. It says nothing
// about physical latency or jitter (see docs/03).
//
// All register access goes through the real UART bridge.

`timescale 1ps/1ps

module tb_qm_top;
  import qm_pkg::*;

  localparam int unsigned CPB    = 16;              // UART clocks per bit
  localparam longint      TCLK   = 8000;            // ps
  localparam longint      TBIT   = CPB * TCLK;

  // ---------------------------------------------------------------- DUT
  logic clk125 = 0, clk_run = 1;
  logic herald = 0;
  logic uart_rx = 1;
  wire  uart_tx;
  wire  pump_p, pump_n, repump_p, repump_n, source_p, source_n, fwd_p, fwd_n;
  wire  ctrl_a_p, ctrl_a_n, ctrl_b_p, ctrl_b_n, armed_p, armed_n, active_p, active_n;
  wire  [2:0] user_led;
  wire  error_led;

  always begin
    #(TCLK/2);
    if (clk_run) clk125 = ~clk125;
  end

  qm_top #(.IN_LAT_CYC(1), .OUT_LAT_CYC(3), .CLKS_PER_BIT(CPB)) dut (
    .clk125_p(clk125), .clk125_n(~clk125),
    .herald_p(herald), .herald_n(~herald),
    .pump_p, .pump_n, .repump_p, .repump_n, .source_p, .source_n, .fwd_p, .fwd_n,
    .ctrl_a_p, .ctrl_a_n, .ctrl_b_p, .ctrl_b_n, .armed_p, .armed_n, .active_p, .active_n,
    .uart_rx, .uart_tx, .user_led, .error_led
  );

  // ------------------------------------------------------------ checking
  int errors = 0;
  int checks = 0;

  task automatic check(input bit cond, input string msg);
    checks++;
    if (!cond) begin
      errors++;
      $display("[%0t] FAIL: %s", $time, msg);
    end
  endtask

  // phys-ns frame: cycle with now_cyc == n starts at t0 + n*8 ns
  longint t0;
  function automatic longint phys(input longint t);
    return t - t0;
  endfunction

  // edge recorders (absolute ps)
  longint q_pump_fall[$], q_pump_rise[$], q_rep_fall[$], q_rep_rise[$];
  longint q_src_fall[$], q_src_rise[$], q_fwd_rise[$], q_fwd_fall[$];
  longint q_ca_rise[$], q_ca_fall[$], q_cb_rise[$], q_cb_fall[$];
  always @(negedge pump_p)   q_pump_fall.push_back($time);
  always @(posedge pump_p)   q_pump_rise.push_back($time);
  always @(negedge repump_p) q_rep_fall.push_back($time);
  always @(posedge repump_p) q_rep_rise.push_back($time);
  always @(negedge source_p) q_src_fall.push_back($time);
  always @(posedge source_p) q_src_rise.push_back($time);
  always @(posedge fwd_p)    q_fwd_rise.push_back($time);
  always @(negedge fwd_p)    q_fwd_fall.push_back($time);
  always @(posedge ctrl_a_p) q_ca_rise.push_back($time);
  always @(negedge ctrl_a_p) q_ca_fall.push_back($time);
  always @(posedge ctrl_b_p) q_cb_rise.push_back($time);
  always @(negedge ctrl_b_p) q_cb_fall.push_back($time);

  task automatic clear_queues();
    q_pump_fall.delete(); q_pump_rise.delete(); q_rep_fall.delete(); q_rep_rise.delete();
    q_src_fall.delete();  q_src_rise.delete();  q_fwd_rise.delete(); q_fwd_fall.delete();
    q_ca_rise.delete();   q_ca_fall.delete();   q_cb_rise.delete();  q_cb_fall.delete();
  endtask

  // ---------------------------------------------------------------- UART
  task automatic uart_send(input logic [7:0] b);
    uart_rx = 0; #(TBIT);
    for (int i = 0; i < 8; i++) begin uart_rx = b[i]; #(TBIT); end
    uart_rx = 1; #(TBIT);
  endtask

  task automatic uart_recv(output logic [7:0] b);
    @(negedge uart_tx);
    #(TBIT + TBIT/2);
    for (int i = 0; i < 8; i++) begin b[i] = uart_tx; #(TBIT); end
  endtask

  task automatic reg_write(input logic [7:0] a, input logic [31:0] d);
    logic [7:0] ack;
    fork
      begin
        uart_send("W"); uart_send(a);
        uart_send(d[31:24]); uart_send(d[23:16]); uart_send(d[15:8]); uart_send(d[7:0]);
      end
      uart_recv(ack);
    join
    check(ack == "K", $sformatf("write ack for addr %02h", a));
  endtask

  longint rd_sent_t, rd_resp_t;
  task automatic reg_read(input logic [7:0] a, output logic [31:0] d);
    logic [7:0] b0, b1, b2, b3;
    fork
      begin uart_send("R"); uart_send(a); rd_sent_t = $time; end
      begin @(negedge uart_tx); rd_resp_t = $time; #(TBIT + TBIT/2);
            for (int i = 0; i < 8; i++) begin b3[i] = uart_tx; #(TBIT); end
            uart_recv(b2); uart_recv(b1); uart_recv(b0); end
    join
    d = {b3, b2, b1, b0};
  endtask

  // ------------------------------------------------------------- herald
  task automatic herald_pulse(input longint width);
    herald = 1; #(width); herald = 0;
  endtask

  // wait until a given phys time (ps)
  task automatic wait_phys(input longint p);
    longint d;
    d = p - phys($time);
    if (d > 0) #(d);
  endtask

  task automatic wait_armed();
    if (!armed_p) @(posedge armed_p);
  endtask

  function automatic longint ceil_ns(input longint ps);
    return ((ps + 999) / 1000) * 1000;
  endfunction

  // --------------------------------------------------- expected config
  int unsigned D_IN   = 270;
  int unsigned T_ST   = 160;
  int unsigned W_C    = 10;
  int unsigned T_R0   = 560, T_R1 = 560, T_R2 = 520;
  int unsigned T_E    = 600;
  int unsigned T_PREP = 250;
  int unsigned FWD_W  = 4;

  int unsigned T_ST_LIST[3] = '{40, 160, 500};

  // Fixed pipeline constants checked by the regression tests (cycles / ps).
  localparam int unsigned ARM_LAT_CYC   = 4;      // beams on -> ARMED, beyond T_PREP
  localparam longint      RD_RESP_PS    = 8000;   // UART: address stop bit end -> first reply start bit

  // Accepted-herald bookkeeping for the FIFO / counter checks
  longint exp_ts[$];
  int     n_done_exp = 0;

  // Configuration is snapshotted when the sequencer arms, so changes are
  // made with run disabled and take effect from the next cycle.
  task automatic run_stop();
    reg_write(A_CTRL, 32'h0);
    wait (dut.u_core.u_seq.state == S_IDLE);
  endtask
  task automatic run_start();
    reg_write(A_CTRL, 32'h1);
  endtask

  // One full accepted cycle with all timing checks.
  // phase_ps: herald rising edge offset after the clk edge that ends arming
  task automatic run_accepted_cycle(input longint phase_ps, input longint width_ps,
                                    input string tag, output longint err_ps);
    longint th, th_s, ca, cb;
    wait_armed();
    repeat (3) @(posedge clk125);
    clear_queues();
    #(phase_ps);
    th = phys($time);
    herald_pulse(width_ps);

    // immediate reaction: same timestamp in the ideal model, and before
    // the next clock edge in any case
    check(q_pump_fall.size() == 1 && phys(q_pump_fall[0]) == th,  {tag, ": pump off at herald"});
    check(q_rep_fall.size() == 1  && phys(q_rep_fall[0])  == th,  {tag, ": repump off at herald"});
    check(q_src_fall.size() == 1  && phys(q_src_fall[0])  == th,  {tag, ": source off at herald"});
    check(q_fwd_rise.size() == 1  && phys(q_fwd_rise[0])  == th,  {tag, ": fwd at herald"});

    // persistence after the pulse is gone
    #(50_000);
    check(!pump_p && !repump_p && !source_p, {tag, ": kill persists after herald pulse"});

    wait_phys(th + 64'(T_E) * 1000 + 40_000);

    th_s = ceil_ns(th);
    exp_ts.push_back(th_s / 1000);
    check(q_ca_rise.size() == 1 && q_cb_rise.size() == 1, {tag, ": one read-in and one read-out"});
    if (q_ca_rise.size() == 1 && q_cb_rise.size() == 1) begin
      ca = phys(q_ca_rise[0]);
      cb = phys(q_cb_rise[0]);
      err_ps = ca - th - 64'(D_IN) * 1000;
      check(ca == th_s + 64'(D_IN) * 1000,
            $sformatf("%s: read-in at %0d ps, expected %0d", tag, ca, th_s + 64'(D_IN) * 1000));
      check(cb == ca + 64'(T_ST) * 1000, $sformatf("%s: storage interval %0d ps", tag, cb - ca));
      check(phys(q_ca_fall[0]) - ca == 64'(W_C) * 1000, {tag, ": read-in width"});
      check(phys(q_cb_fall[0]) - cb == 64'(W_C) * 1000, {tag, ": read-out width"});
      check(ca > th && cb > ca, {tag, ": ordering herald < read-in < read-out"});
    end else begin
      err_ps = 0;
    end

    n_done_exp++;
    // restores are clock-quantized: within [T, T + 3 cycles]
    check(q_pump_rise.size() == 1 && phys(q_pump_rise[0]) >= th + 64'(T_R0) * 1000
          && phys(q_pump_rise[0]) <= th + 64'(T_R0) * 1000 + 3 * TCLK, {tag, ": pump restore"});
    check(q_rep_rise.size() == 1 && phys(q_rep_rise[0]) >= th + 64'(T_R1) * 1000
          && phys(q_rep_rise[0]) <= th + 64'(T_R1) * 1000 + 3 * TCLK, {tag, ": repump restore"});
    check(q_src_rise.size() == 1 && phys(q_src_rise[0]) >= th + 64'(T_R2) * 1000
          && phys(q_src_rise[0]) <= th + 64'(T_R2) * 1000 + 3 * TCLK, {tag, ": source restore"});
    check(q_cb_rise.size() == 0 || q_cb_rise[0] < q_pump_rise[0], {tag, ": read-out before pump restore"});
    check(q_fwd_fall.size() == 1 && q_fwd_fall[0] - q_fwd_rise[0] <= 64'(FWD_W + 8) * TCLK,
          {tag, ": fwd pulse width"});
  endtask

  // ------------------------------------------------------------ the test
  logic [31:0] r;
  longint      e, sum_e, sum_e2, t_on, t_arm;
  int          n_e;

  initial begin
    $timeformat(-9, 3, " ns", 12);

    // ---- T1: reset / initial state
    $display("[%0t] T1: reset / initial state", $time);
    wait (dut.rst == 0);
    @(posedge clk125); #1;
    t0 = $time - 64'(dut.u_core.now_cyc) * TCLK - 1;
    check(!pump_p && !repump_p && !source_p, "T1: beams off after reset");
    check(!fwd_p && !ctrl_a_p && !ctrl_b_p && !armed_p, "T1: triggers low after reset");
    reg_read(A_ID, r);
    check(r == ID_VALUE, $sformatf("T1: ID register %08h", r));
    reg_read(A_STATUS, r);
    check(r[3:0] == S_IDLE, "T1: state IDLE");

    // herald while idle: rejected, outputs untouched
    clear_queues();
    herald_pulse(10_000);
    #(100_000);
    check(q_pump_fall.size() == 0 && q_fwd_rise.size() == 0 && q_ca_rise.size() == 0,
          "T1: herald in IDLE has no effect");

    // ---- T2: configuration, initialization, preparation
    $display("[%0t] T2: configuration, initialization, preparation", $time);
    reg_write(A_T_PREP,   T_PREP);
    reg_write(A_D_READIN, D_IN);
    reg_write(A_T_STORE,  T_ST);
    reg_write(A_W_CTRL,   W_C);
    reg_write(A_T_REST0,  T_R0);
    reg_write(A_T_REST1,  T_R1);
    reg_write(A_T_REST2,  T_R2);
    reg_write(A_T_END,    T_E);
    reg_write(A_FWD_W,    FWD_W);
    reg_read(A_D_READIN, r);
    check(r == D_IN, "T2: register readback");

    clear_queues();
    fork
      reg_write(A_CTRL, 32'h1);
      begin
        @(posedge pump_p);
        t_on = $time;
        #1;
        check(repump_p && source_p, "T2: all beams on in PREP");
        #(1_000_000);                             // inside the 2 us preparation
        herald_pulse(10_000);
        #(100_000);
        check(pump_p && q_pump_fall.size() == 0 && q_ca_rise.size() == 0,
              "T2: herald during preparation rejected");
      end
      begin
        @(posedge armed_p);
        t_arm = $time;
      end
    join
    check(t_arm - t_on >= 64'(T_PREP) * TCLK, $sformatf("T2: preparation time %0d ns", (t_arm - t_on) / 1000));
    // Regression: the exact cycle count from beams-on to ARMED must not change
    // when the configuration check is pipelined.
    $display("T2: beams on -> armed = %0d cycles", (t_arm - t_on) / TCLK);
    check((t_arm - t_on) % TCLK == 0 && (t_arm - t_on) / TCLK == 64'(T_PREP + ARM_LAT_CYC),
          $sformatf("T2: arming latency %0d cycles, expected T_PREP + %0d", (t_arm - t_on) / TCLK, ARM_LAT_CYC));

    // ---- T3: one accepted herald, full timing check
    $display("[%0t] T3: one accepted herald, full timing check", $time);
    run_accepted_cycle(3_217, 10_000, "T3", e);

    // ---- T4: storage interval sweep
    $display("[%0t] T4: storage interval sweep", $time);
    foreach (T_ST_LIST[i]) begin
      T_ST = T_ST_LIST[i];
      T_E  = D_IN + T_ST + W_C + 200;
      T_R0 = T_E - 20; T_R1 = T_E - 20; T_R2 = T_E - 40;
      run_stop();
      reg_write(A_T_END, T_E);   reg_write(A_T_STORE, T_ST);
      reg_write(A_T_REST0, T_R0); reg_write(A_T_REST1, T_R1); reg_write(A_T_REST2, T_R2);
      run_start();
      run_accepted_cycle(1_500 + 64'(i) * 777, 10_000, $sformatf("T4[T_store=%0d]", T_ST), e);
    end

    // ---- T5: busy rejection - second herald during the active window
    $display("[%0t] T5: busy rejection - second herald during the active window", $time);
    begin
      longint th;
      wait_armed(); repeat (2) @(posedge clk125); #(2_345);
      clear_queues();
      th = phys($time);
      herald_pulse(10_000);
      #(30_000);
      herald_pulse(10_000);                       // 40 ns after the first edge
      wait_phys(th + 64'(T_E) * 1000 + 40_000);
      check(q_ca_rise.size() == 1 && q_cb_rise.size() == 1, "T5: second herald does not retrigger");
      check(q_pump_fall.size() == 1, "T5: no output disturbance from second herald");
      exp_ts.push_back(ceil_ns(th) / 1000);
      n_done_exp++;
    end

    // ---- T6: two heralds 25 ns apart while armed (SPAD dead time ~22 ns)
    $display("[%0t] T6: two heralds 25 ns apart while armed (SPAD dead time ~22 ns)", $time);
    begin
      longint th;
      wait_armed(); repeat (2) @(posedge clk125); #(5_100);
      clear_queues();
      th = phys($time);
      herald_pulse(8_000); #(17_000); herald_pulse(8_000);
      wait_phys(th + 64'(T_E) * 1000 + 40_000);
      check(q_ca_rise.size() == 1, "T6: closely spaced heralds give one experiment");
      if (q_ca_rise.size() == 1)
        check(phys(q_ca_rise[0]) == ceil_ns(th) + 64'(D_IN) * 1000, "T6: timed from the first herald");
      exp_ts.push_back(ceil_ns(th) / 1000);
      n_done_exp++;
    end

    // ---- T7a: 400 ps pulse between two serdes samples
    $display("[%0t] T7a: 400 ps pulse between two serdes samples", $time);
    begin
      logic [31:0] noedge0, noedge1, abort0, abort1;
      reg_read(A_CNT_NOEDGE, noedge0);
      reg_read(A_CNT_ABORT, abort0);
      wait_armed(); repeat (2) @(posedge clk125); #(2_300);
      clear_queues();
      herald_pulse(400);
      check(q_pump_fall.size() == 1, "T7a: 400 ps pulse still sets the latch (Path A)");
      #(2_000_000);
      reg_read(A_CNT_NOEDGE, noedge1);
      reg_read(A_CNT_ABORT, abort1);
      check(noedge1 == noedge0 + 1, "T7a: fired-without-edge flagged");
      check(abort1 == abort0 + 1, "T7a: cycle aborted");
      check(q_ca_rise.size() == 0, "T7a: no control pulses for unmeasured herald");
      check(pump_p && repump_p && source_p, "T7a: beams restored after abort");
    end

    // ---- T7b: 1.2 ns pulse is always sampled
    $display("[%0t] T7b: 1.2 ns pulse is always sampled", $time);
    run_accepted_cycle(4_650, 1_200, "T7b", e);

    // ---- T8: phase sweep, quantization statistics
    $display("[%0t] T8: phase sweep, quantization statistics", $time);
    sum_e = 0; sum_e2 = 0; n_e = 0;
    for (int k = 0; k < 24; k++) begin
      longint ph;
      ph = 64'($urandom_range(7_999, 1));
      if (ph % 1000 == 0) ph++;
      run_accepted_cycle(ph, 10_000, $sformatf("T8[%0d]", k), e);
      check(e > 0 && e <= 1000, $sformatf("T8[%0d]: quantization error %0d ps in (0,1000]", k, e));
      sum_e += e; sum_e2 += e * e; n_e++;
    end
    begin
      real m, s;
      m = real'(sum_e) / n_e;
      s = $sqrt(real'(sum_e2) / n_e - m * m);
      $display("T8: herald->read-in offset over %0d random phases: mean %0.1f ps, std %0.1f ps "
               , n_e, m, s);
      $display("    (ideal model: uniform in (0,1] ns, std 289 ps -> this is the Tier-1 jitter floor)");
    end

    // ---- T9: herald while the latch clears are released but arm is low
    $display("[%0t] T9: herald while the latch clears are released but arm is low", $time);
    begin
      logic [31:0] acc0, acc1;
      reg_read(A_CNT_ACC, acc0);
      reg_write(A_CTRL, 32'h3);               // abort -> PREP -> REL -> ARMED
      wait (dut.u_core.u_seq.state == S_REL);
      clear_queues();
      herald_pulse(5_000);                    // arm is still low
      wait_armed();
      #(3_000_000);
      reg_read(A_CNT_ACC, acc1);
      check(acc1 == acc0, "T9: herald before arm not accepted");
      check(q_pump_fall.size() == 0, "T9: herald before arm has no Path A effect");
    end

    // ---- T10: herald coincident with the arm edge
    $display("[%0t] T10: herald coincident with the arm edge", $time);
    begin
      logic [31:0] acc0, race0, acc1, race1;
      reg_read(A_CNT_ACC, acc0);
      reg_read(A_CNT_RACE, race0);
      // armed now; force a new cycle via abort, then hit the arm edge
      reg_write(A_CTRL, 32'h3);
      wait (dut.u_core.u_seq.state == S_REL);
      @(posedge dut.u_core.arm);
      clear_queues();
      herald_pulse(10_000);
      #(3_000_000);
      reg_read(A_CNT_ACC, acc1);
      reg_read(A_CNT_RACE, race1);
      check((acc1 - acc0) + (race1 - race0) == 1, "T10: edge at arm is either accepted or a race");
      check((acc1 != acc0) == (q_ca_rise.size() == 1), "T10: pulses iff accepted");
      if (acc1 != acc0) begin
        exp_ts.push_back(-1);                  // timestamp not predicted
        n_done_exp++;
      end
      $display("T10: arm-edge herald resolved as %s", (acc1 != acc0) ? "accepted" : "race");
    end

    // ---- T10b: herald 1.5 ns BEFORE the arm edge: serdes sees it inside the
    // guard band, the latch does not fire -> classified as a race, no action
    $display("[%0t] T10b: herald inside the guard band before arm", $time);
    begin
      logic [31:0] acc0, race0, acc1, race1;
      wait_armed();
      reg_read(A_CNT_ACC, acc0);
      reg_read(A_CNT_RACE, race0);
      reg_write(A_CTRL, 32'h3);                // abort -> PREP -> REL
      wait (dut.u_core.u_seq.state == S_REL);  // entered at edge E0; arm rises at E3
      @(posedge clk125); @(posedge clk125);
      #(TCLK - 1_500);
      clear_queues();
      herald_pulse(10_000);
      #(3_000_000);
      reg_read(A_CNT_ACC, acc1);
      reg_read(A_CNT_RACE, race1);
      check(race1 == race0 + 1 && acc1 == acc0, "T10b: pre-arm edge counted as race, not accepted");
      check(q_pump_fall.size() == 0 && q_ca_rise.size() == 0, "T10b: no reaction to pre-arm edge");
      check(armed_p, "T10b: still armed afterwards");
    end
    run_accepted_cycle(2_222, 10_000, "T10c", e);

    // ---- T11: Path A works with the clock stopped
    $display("[%0t] T11: Path A works with the clock stopped", $time);
    begin
      logic [31:0] noedge0, noedge1;
      reg_read(A_CNT_NOEDGE, noedge0);
      wait_armed(); repeat (2) @(posedge clk125);
      @(negedge clk125);
      clk_run = 0;
      #(40_000);
      clear_queues();
      herald_pulse(10_000);
      check(q_pump_fall.size() == 1 && q_src_fall.size() == 1 && q_fwd_rise.size() == 1,
            "T11: immediate reaction without any clock");
      #(200_000);
      check(!pump_p && !repump_p && !source_p && clk125 == 0, "T11: state held, clock still stopped");
      clk_run = 1;
      // the cycle counter did not advance while the clock was stopped
      @(posedge clk125); #1;
      t0 = $time - 64'(dut.u_core.now_cyc) * TCLK - 1;
      #(3_000_000);
      reg_read(A_CNT_NOEDGE, noedge1);
      check(noedge1 == noedge0 + 1, "T11: herald unseen by stopped serdes flagged as no-edge");
      check(pump_p && repump_p && source_p, "T11: recovered after clock restart");
    end

    // ---- T12: host abort during the active window
    $display("[%0t] T12: host abort during the active window", $time);
    begin
      logic [31:0] abort0, abort1;
      reg_read(A_CNT_ABORT, abort0);
      wait_armed();
      clear_queues();
      // the abort write commits ~7.6 us after it starts; put the herald
      // ~200 ns before that so the abort lands inside the active window
      fork
        reg_write(A_CTRL, 32'h3);                // run + abort
        begin #(7_400_000); herald_pulse(10_000); end
      join
      exp_ts.push_back(-1);
      #(2_000_000);
      reg_read(A_CNT_ABORT, abort1);
      check(abort1 == abort0 + 1, "T12: abort counted");
      check(q_pump_fall.size() == 1, "T12: herald was accepted before the abort");
      check(q_cb_rise.size() == 0, "T12: read-out cancelled by abort");
      check(pump_p && repump_p && source_p, "T12: abort restores beams");
      check(dut.u_core.u_seq.p_en == 0, "T12: abort cancels pulses");
    end

    // ---- T13 / T14: delayed (non-immediate) repump, inverted pump polarity
    $display("[%0t] T13 / T14: delayed (non-immediate) repump, inverted pump polarity", $time);
    begin
      longint th;
      run_stop();
      reg_write(A_T_OFF1, 100);
      reg_write(A_CHCFG, 32'h0000_0105);         // imm = pump+source, pump inverted
      run_start();
      wait_armed(); repeat (2) @(posedge clk125); #(6_006);
      check(!pump_p && repump_p, "T14: inverted pump idles low while on");
      clear_queues();
      th = phys($time);
      herald_pulse(10_000);
      check(q_pump_rise.size() == 1 && q_rep_fall.size() == 0, "T13/14: pump (inverted) reacts, repump does not");
      wait_phys(th + 64'(T_E) * 1000 + 40_000);
      check(q_rep_fall.size() == 1 && phys(q_rep_fall[0]) >= th + 100_000
            && phys(q_rep_fall[0]) <= th + 100_000 + 3 * TCLK, "T13: delayed repump off at +100 ns");
      exp_ts.push_back(ceil_ns(th) / 1000);
      n_done_exp++;
      run_stop();
      reg_write(A_CHCFG, 32'h0000_0007);
      run_start();
    end

    // ---- T15: repeated cycles, counters and invariants
    $display("[%0t] T15: repeated cycles, counters and invariants", $time);
    for (int k = 0; k < 10; k++) run_accepted_cycle(64'(k) * 731 + 123, 10_000, $sformatf("T15[%0d]", k), e);
    reg_write(A_CTRL, 32'h0);                       // stop
    #(2_000_000);
    begin
      logic [31:0] raw, edg, acc, rej, race, abrt, noedge, done, late, fstat;
      reg_read(A_CNT_RAW, raw);     reg_read(A_CNT_EDGE, edg);
      reg_read(A_CNT_ACC, acc);     reg_read(A_CNT_REJ, rej);
      reg_read(A_CNT_RACE, race);   reg_read(A_CNT_ABORT, abrt);
      reg_read(A_CNT_NOEDGE, noedge); reg_read(A_CNT_DONE, done);
      reg_read(A_CNT_LATE, late);   reg_read(A_FIFO_STAT, fstat);
      $display("counters: raw=%0d edge=%0d acc=%0d rej=%0d race=%0d abort=%0d noedge=%0d done=%0d late=%0d fifo=%0d",
               raw, edg, acc, rej, race, abrt, noedge, done, late, fstat[15:0]);
      check(edg == acc + rej + race, "T15: every serdes edge classified exactly once");
      check(raw == edg + noedge, "T15: raw edges = serdes edges + unseen (short / clock-stopped)");
      check(done == 32'(n_done_exp), $sformatf("T15: completed cycles %0d, expected %0d", done, n_done_exp));
      check(acc == done + 1, "T15: accepted = completed + one host-aborted (T12)");
      check(race == 1, "T15: exactly one race (T10b)");
      check(late == 0, "T15: no late scheduling");
      check(32'(fstat[15:0]) == acc && 32'(exp_ts.size()) == acc, "T15: one FIFO entry per accepted herald");
      reg_read(A_STATUS, r);
      check(r[3:0] == S_IDLE && !pump_p, "T15: run disabled -> IDLE, beams off");
    end

    // ---- T16: FIFO timestamps
    $display("[%0t] T16: FIFO timestamps", $time);
    begin
      logic [31:0] lo, hi;
      static int bad = 0;
      foreach (exp_ts[i]) begin
        reg_read(A_FIFO_LO, lo);
        reg_read(A_FIFO_HI, hi);
        if (exp_ts[i] >= 0 && {hi, lo} != 64'(exp_ts[i])) begin
          bad++;
          $display("FIFO[%0d] = %0d, expected %0d", i, {hi, lo}, exp_ts[i]);
        end
      end
      check(bad == 0, "T16: FIFO timestamps match herald sample times");
    end

    // ---- T17: inconsistent configuration is never armed
    $display("[%0t] T17: invalid configuration blocks arming", $time);
    begin
      int armed_seen = 0;
      reg_write(A_T_END, 100);                    // read-in at 270 ns > T_END
      fork
        begin
          run_start();
          #(10_000_000);
        end
        begin
          @(posedge armed_p);
          armed_seen = 1;
        end
      join_any
      disable fork;
      reg_read(A_STATUS, r);
      check(armed_seen == 0 && !armed_p, "T17: never armed with T_END < read-out");
      check(r[5] == 1'b1, "T17: cfg_err reported in STATUS");
      check(pump_p && repump_p && source_p, "T17: beams stay on (preparation) while blocked");
      run_stop();
      reg_write(A_T_END, T_E);
      reg_read(A_STATUS, r);
      check(r[5] == 1'b0, "T17: cfg_err clears with a valid configuration");
    end

    // ---- T18: register map read-back and invalid addresses (regression for
    // the pipelined read mux: same values, same decode, same side effects)
    $display("[%0t] T18: register map read-back", $time);
    begin
      logic [7:0]  ra [12] = '{A_CHCFG, A_T_PREP, A_D_READIN, A_T_STORE, A_W_CTRL, A_T_OFF0,
                               A_T_OFF1, A_T_OFF2, A_T_REST0, A_T_REST1, A_T_REST2, A_T_END};
      logic [31:0] rv [12] = '{32'h0001_1A05, 32'd777, 32'd301, 32'd99, 32'd0000_0011, 32'd5,
                               32'd6, 32'd7, 32'd501, 32'd502, 32'd503, 32'd600};
      logic [7:0]  bad [6] = '{8'h78, 8'h7C, 8'h80, 8'hFC, 8'h02, 8'h41};
      longint      lat;
      run_stop();
      foreach (ra[i]) reg_write(ra[i], rv[i]);
      reg_write(A_FWD_W, 32'h0000_BEEF);
      foreach (ra[i]) begin
        reg_read(ra[i], r);
        check(r == rv[i], $sformatf("T18: reg %02h read %08h, wrote %08h", ra[i], r, rv[i]));
      end
      reg_read(A_FWD_W, r);
      check(r == 32'h0000_BEEF, "T18: FWD_W keeps 16 bits");
      reg_read(A_ID, r);
      check(r == ID_VALUE, "T18: ID");
      lat = rd_resp_t - rd_sent_t;
      $display("T18: UART read reply starts %0d ps after the address byte", lat);
      check(lat == RD_RESP_PS, $sformatf("T18: read reply latency %0d ps, expected %0d", lat, RD_RESP_PS));
      foreach (bad[i]) begin
        reg_read(bad[i], r);
        check(r == 32'hDEAD_BEEF, $sformatf("T18: unmapped address %02h reads %08h", bad[i], r));
      end
      reg_read(A_CNT_DONE, r);
      check(r == 32'(n_done_exp), "T18: counter read after map test");
      begin
        logic [31:0] lo, hi;
        reg_read(A_LAST_TS_LO, lo);
        reg_read(A_LAST_TS_HI, hi);
        check({hi, lo} == 64'(exp_ts[$]), $sformatf("T18: LAST_TS %0d, expected %0d", {hi, lo}, exp_ts[$]));
      end
      reg_read(A_FIFO_STAT, r);
      check(r[15:0] == 0, "T18: FIFO empty after T16 drain");
    end

    $display("==================================================");
    $display("%0d checks, %0d errors", checks, errors);
    if (errors == 0) $display("TEST PASSED");
    else             $display("TEST FAILED");
    $display("==================================================");
    $finish;
  end

  initial begin
    #(64'd400_000_000_000);   // 400 ms
    $display("TIMEOUT");
    $display("TEST FAILED");
    $finish;
  end

  // --------------------------------------------------------- assertions
  // Asynchronous-design rules relied upon by qm_herald_latch.
  wire                c    = dut.clk;
  wire                arm  = dut.u_core.arm;
  wire [N_KILL-1:0]   clrk = dut.u_core.clr_kill;
  wire                clrf = dut.u_core.clr_fired;

  a_no_arm_with_clear: assert property (@(posedge c) disable iff (dut.rst)
                                        arm |-> (clrk == '0 && !clrf))
    else begin errors++; $display("[%0t] ASSERT: arm while a clear is active", $time); end
  a_clear_changes_unarmed: assert property (@(posedge c) disable iff (dut.rst)
                                            (clrk != $past(clrk)) |-> (!arm && !$past(arm)))
    else begin errors++; $display("[%0t] ASSERT: clear toggled while armed", $time); end
  a_pulses_only_active: assert property (@(posedge c) disable iff (dut.rst)
                                         dut.u_core.p_en |-> dut.u_core.u_seq.state == S_ACTIVE)
    else begin errors++; $display("[%0t] ASSERT: pulse enable outside ACTIVE", $time); end
  a_beams_on_when_armed: assert property (@(posedge c) disable iff (dut.rst)
                                          arm |-> dut.u_core.on == '1)
    else begin errors++; $display("[%0t] ASSERT: armed with a beam off", $time); end

endmodule
