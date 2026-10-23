// SPDX-License-Identifier: Apache-2.0
// qm_pulse_unit.sv - 1 ns resolution pulse for one output serdes word.
//
// For each bit b of the word that will be emitted at phys ns base+b, the
// output is high when (base + b - start) mod 2^32 < width. The modular
// subtraction makes the comparison wrap-safe; the caller must deassert `en`
// within 2^32 ns of `start`, which the sequencer guarantees (it drops `en`
// at the end of every active window).
//
// Two pipeline stages (subtract, then compare) so that each clk_sys cycle
// contains a single 32-bit carry chain. `word` reflects the inputs sampled
// two clock edges earlier; the caller offsets `base` accordingly.
// `base` must be a multiple of 8, so base + b is a concatenation, not an add.

import qm_pkg::*;

module qm_pulse_unit
(
  input  logic                clk,
  input  logic                rst,
  input  logic                en,
  input  logic [NS_W-1:0]     start,   // phys ns of the rising edge
  input  logic [15:0]         width,   // ns
  /* verilator lint_off UNUSEDSIGNAL */  // base[2:0] is always 0
  input  logic [NS_W-1:0]     base,    // phys ns of bit 0 of the word being produced
  /* verilator lint_on UNUSEDSIGNAL */
  output logic [SERDES_W-1:0] word
);

  logic [NS_W-1:0] rel [SERDES_W];
  logic            en_q;
  logic [15:0]     width_q;

  always_ff @(posedge clk) begin
    if (rst) begin
      en_q <= 1'b0;
      word <= '0;
    end else begin
      en_q    <= en;
      width_q <= width;
      for (int b = 0; b < SERDES_W; b++) begin
        rel[b]  <= {base[NS_W-1:3], 3'(b)} - start;
        word[b] <= en_q && (rel[b] < NS_W'(width_q));
      end
    end
  end

endmodule
