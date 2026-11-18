// expect: CDC-SYNC-DEPTH
// Only one synchronizer stage before the signal is used.
module t (input logic src_clk_i, src_rst_ni, dst_clk_i, dst_rst_ni, src_a_i, dst_b_i, output logic dst_y_o);
  logic a_q, s1, y_q;
  always_ff @(posedge src_clk_i or negedge src_rst_ni) if (!src_rst_ni) a_q <= 0; else a_q <= src_a_i;
  always_ff @(posedge dst_clk_i or negedge dst_rst_ni) if (!dst_rst_ni) s1 <= 0; else s1 <= a_q;
  always_ff @(posedge dst_clk_i or negedge dst_rst_ni) if (!dst_rst_ni) y_q <= 0; else y_q <= s1 & dst_b_i;
  assign dst_y_o = y_q;
endmodule
