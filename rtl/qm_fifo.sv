// SPDX-License-Identifier: Apache-2.0
// qm_fifo.sv - small synchronous FIFO for accepted-herald timestamps.
// Overflowing pushes are dropped and counted, never silently lost.

module qm_fifo #(
  parameter int unsigned W     = 64,
  parameter int unsigned DEPTH = 64   // power of two
) (
  input  logic         clk,
  input  logic         rst,
  input  logic         push,
  input  logic [W-1:0] din,
  input  logic         pop,
  output logic [W-1:0] dout,         // head, valid when level != 0
  output logic [15:0]  level,
  output logic [15:0]  overflows
);

  localparam int unsigned AW = $clog2(DEPTH);

  logic [W-1:0]  mem [DEPTH];
  logic [AW:0]   wp, rp;
  logic          full, empty;

  assign full  = (wp - rp) == (AW+1)'(DEPTH);
  assign empty = (wp == rp);
  assign level = 16'(wp - rp);
  assign dout  = mem[rp[AW-1:0]];

  always_ff @(posedge clk) begin
    if (rst) begin
      wp        <= '0;
      rp        <= '0;
      overflows <= '0;
    end else begin
      if (push) begin
        if (!full) begin
          mem[wp[AW-1:0]] <= din;
          wp <= wp + 1;
        end else if (overflows != '1) begin
          overflows <= overflows + 1;
        end
      end
      if (pop && !empty) rp <= rp + 1;
    end
  end

endmodule
