// SPDX-License-Identifier: Apache-2.0
// qm_edge_capture.sv - Path B: herald timestamping from the input serdes.
//
// The input serdes samples the herald at 1 GS/s and delivers 8 samples per
// clk_sys cycle (bit 0 = earliest). A rising edge is a 0->1 transition
// between consecutive samples, including across word boundaries. The
// timestamp resolution is therefore 1 ns (quantization RMS 289 ps). This is
// clock-based timestamping, not a TDC; see docs/02 for the TDC upgrade.
//
// Timestamps are in the phys-ns frame: the word processed in the cycle with
// counter value now_cyc covers samples taken IN_LAT_CYC cycles earlier.

import qm_pkg::*;

module qm_edge_capture
#(
  parameter int unsigned IN_LAT_CYC = 3
) (
  input  logic                clk,
  input  logic                rst,
  input  logic [SERDES_W-1:0] word,      // bit 0 earliest
  input  logic [63:0]         now_cyc,

  output logic                edge_valid, // one-cycle strobe
  output logic [63:0]         edge_ns     // phys ns of first edge in word
);

  logic                prev_last;
  logic [SERDES_W-1:0] rise;
  logic [2:0]          first;
  logic                any;

  always_comb begin
    rise[0] = word[0] & ~prev_last;
    for (int b = 1; b < SERDES_W; b++) rise[b] = word[b] & ~word[b-1];
    any   = |rise;
    first = '0;
    for (int b = SERDES_W - 1; b >= 0; b--) if (rise[b]) first = 3'(b);
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      prev_last  <= 1'b0;
      edge_valid <= 1'b0;
      edge_ns    <= '0;
    end else begin
      prev_last  <= word[SERDES_W-1];
      edge_valid <= any;
      edge_ns    <= ((now_cyc - 64'(IN_LAT_CYC)) << 3) | 64'(first);
    end
  end

endmodule
