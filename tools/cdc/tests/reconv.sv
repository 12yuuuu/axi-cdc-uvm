// expect: CDC-RECONV
// Two independent source registers, synchronized separately, then combined:
// they can arrive in different cycles.
module t (input logic src_clk_i, src_rst_ni, dst_clk_i, dst_rst_ni, src_a_i, src_b_i, output logic dst_y_o);
  logic a_q, b_q, a1, a2, b1, b2, y_q;
  always_ff @(posedge src_clk_i or negedge src_rst_ni) if (!src_rst_ni) a_q <= 0; else a_q <= src_a_i;
  always_ff @(posedge src_clk_i or negedge src_rst_ni) if (!src_rst_ni) b_q <= 0; else b_q <= src_b_i;
  always_ff @(posedge dst_clk_i or negedge dst_rst_ni) if (!dst_rst_ni) {a2, a1, b2, b1} <= 0; else {a2, a1, b2, b1} <= {a1, a_q, b1, b_q};
  always_ff @(posedge dst_clk_i or negedge dst_rst_ni) if (!dst_rst_ni) y_q <= 0; else y_q <= a2 & b2;
  assign dst_y_o = y_q;
endmodule
