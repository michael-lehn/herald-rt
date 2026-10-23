// SPDX-License-Identifier: Apache-2.0
// qm_uart.sv - 8N1 UART and a minimal register-bus bridge for the host.
//
// Host protocol (binary, big-endian data):
//   write: 'W' addr d3 d2 d1 d0   -> reply 'K'
//   read : 'R' addr               -> reply d3 d2 d1 d0
// Other command bytes are ignored. The host interface is for configuration
// and diagnostics only; it is never in the herald reaction path.

module qm_uart_rx #(
  parameter int unsigned CLKS_PER_BIT = 125
) (
  input  logic       clk,
  input  logic       rst,
  input  logic       rxd,        // already synchronized
  output logic       valid,
  output logic [7:0] data
);
  logic [15:0] cnt;
  logic [3:0]  bitn;
  logic        busy;
  logic [7:0]  sh;

  always_ff @(posedge clk) begin
    valid <= 1'b0;
    if (rst) begin
      busy <= 1'b0;
      cnt  <= '0;
      bitn <= '0;
    end else if (!busy) begin
      if (!rxd) begin                       // start bit: sample mid-bit
        busy <= 1'b1;
        cnt  <= 16'(CLKS_PER_BIT / 2);
        bitn <= '0;
      end
    end else if (cnt != 0) begin
      cnt <= cnt - 1;
    end else begin
      cnt <= 16'(CLKS_PER_BIT - 1);
      unique case (bitn)
        4'd0:    if (rxd) busy <= 1'b0;     // false start
        4'd9:    begin busy <= 1'b0; if (rxd) begin valid <= 1'b1; data <= sh; end end
        default: sh <= {rxd, sh[7:1]};
      endcase
      bitn <= bitn + 1;
    end
  end
endmodule

module qm_uart_tx #(
  parameter int unsigned CLKS_PER_BIT = 125
) (
  input  logic       clk,
  input  logic       rst,
  input  logic       start,
  input  logic [7:0] data,
  output logic       busy,
  output logic       txd
);
  logic [15:0] cnt;
  logic [3:0]  bitn;
  logic [9:0]  sh;

  always_ff @(posedge clk) begin
    if (rst) begin
      busy <= 1'b0;
      txd  <= 1'b1;
    end else if (!busy) begin
      if (start) begin
        busy <= 1'b1;
        sh   <= {1'b1, data, 1'b0};
        bitn <= '0;
        cnt  <= '0;
      end
    end else if (cnt != 0) begin
      cnt <= cnt - 1;
    end else begin
      cnt <= 16'(CLKS_PER_BIT - 1);
      if (bitn == 4'd10) begin
        busy <= 1'b0;
        txd  <= 1'b1;
      end else begin
        txd  <= sh[0];
        sh   <= {1'b1, sh[9:1]};
        bitn <= bitn + 1;
      end
    end
  end
endmodule

module qm_uart_bridge #(
  parameter int unsigned CLKS_PER_BIT = 125
) (
  input  logic        clk,
  input  logic        rst,
  input  logic        rxd_async,
  output logic        txd,
  output logic        we,
  output logic        re,
  output logic [7:0]  addr,
  output logic [31:0] wdata,
  input  logic [31:0] rdata
);
  logic       rxd;
  logic       rx_v;
  logic [7:0] rx_d;
  logic       tx_start, tx_busy;
  logic [7:0] tx_d;

  qm_sync #(.W(1), .STAGES(2)) u_sync (.clk, .d(rxd_async), .q(rxd));
  qm_uart_rx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_rx (.clk, .rst, .rxd, .valid(rx_v), .data(rx_d));
  qm_uart_tx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_tx (.clk, .rst, .start(tx_start), .data(tx_d),
                                                  .busy(tx_busy), .txd);

  typedef enum logic [2:0] { B_CMD, B_ADDR, B_DATA, B_RD, B_TX } bstate_t;
  bstate_t     st;
  logic        is_wr;
  logic [1:0]  n;
  logic [31:0] txbuf;
  logic [2:0]  txn;
  logic        tx_from_rdata;   // first reply byte comes straight from rdata

  always_ff @(posedge clk) begin
    we       <= 1'b0;
    re       <= 1'b0;
    tx_start <= 1'b0;
    if (rst) begin
      st            <= B_CMD;
      tx_from_rdata <= 1'b0;
    end else begin
      unique case (st)
        B_CMD: if (rx_v) begin
          if (rx_d == "W" || rx_d == "R") begin
            is_wr <= (rx_d == "W");
            st    <= B_ADDR;
          end
        end
        B_ADDR: if (rx_v) begin
          addr <= rx_d;
          n    <= '0;
          if (is_wr) st <= B_DATA;
          else begin
            re <= 1'b1;
            st <= B_RD;
          end
        end
        B_DATA: if (rx_v) begin
          wdata <= {wdata[23:0], rx_d};
          n     <= n + 1;
          if (n == 2'd3) begin
            we    <= 1'b1;
            txbuf         <= {"K", 24'd0};
            txn           <= 3'd1;
            tx_from_rdata <= 1'b0;
            st    <= B_TX;
          end
        end
        B_RD: begin                         // qm_regs: stage 1 one cycle after re,
          n <= n + 1;                       // rdata valid one cycle after that
          if (n == 2'd1) begin
            txn           <= 3'd4;          // reply bytes are taken from rdata in
            tx_from_rdata <= 1'b1;          // B_TX, which absorbs the read stage
            st            <= B_TX;
          end
        end
        B_TX: begin
          if (txn == 0) st <= B_CMD;
          else if (!tx_busy && !tx_start) begin
            tx_d          <= tx_from_rdata ? rdata[31:24] : txbuf[31:24];
            txbuf         <= tx_from_rdata ? {rdata[23:0], 8'd0} : {txbuf[23:0], 8'd0};
            tx_from_rdata <= 1'b0;
            tx_start      <= 1'b1;
            txn           <= txn - 1;
          end
        end
        default: st <= B_CMD;
      endcase
    end
  end
endmodule
