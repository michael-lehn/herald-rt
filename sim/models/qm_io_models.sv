// SPDX-License-Identifier: Apache-2.0
// qm_io_models.sv - behavioral (simulation-only) models of the vendor
// wrappers in rtl/vendor/xilinx7/qm_xilinx7_io.sv.
//
// The models are ideal: zero buffer delay, perfect 1 ns sampling instants.
// They verify the logic, not the electrical timing.
//
// Model latencies (the testbench sets IN_LAT_CYC = 1, OUT_LAT_CYC = 3):
//   input : samples of window k (phys ns 8k .. 8k+7) appear on `word` at
//           clk_div edge k+1; qm_edge_capture registers them at edge k+2.
//   output: `word` as seen at clk_div edge m (the value of cycle m-1) is
//           driven during phys ns 8m .. 8m+7.
// The real ISERDESE2/OSERDESE2 latencies differ and must be calibrated.

`timescale 1ps/1ps
/* verilator lint_off BLKSEQ */
/* verilator lint_off UNUSEDSIGNAL */

module qm_clocking (
  input  logic clk_in_p,
  input  logic clk_in_n,
  output logic clk_sys,
  output logic clk_fast,
  output logic locked
);
  assign clk_sys = clk_in_p;
  initial begin
    clk_fast = 1'b0;
    locked   = 1'b0;
    repeat (20) @(posedge clk_in_p);
    locked = 1'b1;
  end
  always @(posedge clk_in_p) begin
    repeat (4) begin
      clk_fast = 1'b1; #1000;
      clk_fast = 1'b0; #1000;
    end
  end
endmodule

module qm_in_serdes (
  input  logic       pad_p,
  input  logic       pad_n,
  input  logic       clk_fast,
  input  logic       clk_div,
  input  logic       rst,
  output logic       async_o,
  output logic [7:0] word
);
  logic [7:0] acc;
  logic [7:0] samp;

  assign async_o = pad_p;

  always @(posedge clk_div) begin
    word <= rst ? 8'h00 : acc;
    for (int b = 0; b < 8; b++) begin
      samp[b] = pad_p;
      if (b < 7) #1000;
    end
    acc = samp;
  end
endmodule

module qm_out_serdes (
  input  logic [7:0] word,
  input  logic       clk_fast,
  input  logic       clk_div,
  input  logic       rst,
  output logic       pad_p,
  output logic       pad_n
);
  logic [7:0] w;
  initial pad_p = 1'b0;
  assign pad_n = ~pad_p;
  always @(posedge clk_div) begin
    w = rst ? 8'h00 : word;
    for (int b = 0; b < 8; b++) begin
      pad_p = w[b];
      if (b < 7) #1000;
    end
  end
endmodule

module qm_diff_out (
  input  logic i,
  output logic pad_p,
  output logic pad_n
);
  assign pad_p = i;
  assign pad_n = ~i;
endmodule
