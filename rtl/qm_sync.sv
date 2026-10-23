// SPDX-License-Identifier: Apache-2.0
// qm_sync.sv - multi-flop synchronizer for single-bit (or Gray-coded) signals.
// ASYNC_REG keeps the flops in one slice and tells the tools they sample an
// asynchronous input; the XDC adds max-delay constraints on the input nets.
// SHREG_EXTRACT = "NO": the stages must stay flip-flops. Yosys' xilinx_srl
// ignores ASYNC_REG and packed 3-stage chains into SRL16E (found in the
// openXC7 netlist), so the open flow also runs synth_xilinx -nosrl.

module qm_sync #(
  parameter int unsigned W      = 1,
  parameter int unsigned STAGES = 3
) (
  input  logic         clk,
  input  logic [W-1:0] d,
  output logic [W-1:0] q
);

  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) logic [W-1:0] s [STAGES];

  always_ff @(posedge clk) begin
    s[0] <= d;
    for (int i = 1; i < STAGES; i++) s[i] <= s[i-1];
  end

  assign q = s[STAGES-1];

endmodule
