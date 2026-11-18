// expect: CDC-SYNC-FANOUT
// The first (possibly metastable) stage also feeds other logic.
module t (input logic src_clk_i, src_rst_ni, dst_clk_i, dst_rst_ni, src_a_i, output logic dst_y_o, dst_z_o);
  logic a_q, s1, s2, z_q;
  always_ff @(posedge src_clk_i or negedge src_rst_ni) if (!src_rst_ni) a_q <= 0; else a_q <= src_a_i;
  always_ff @(posedge dst_clk_i or negedge dst_rst_ni) if (!dst_rst_ni) {s2, s1} <= 0; else {s2, s1} <= {s1, a_q};
  always_ff @(posedge dst_clk_i or negedge dst_rst_ni) if (!dst_rst_ni) z_q <= 0; else z_q <= ~s1;
  assign dst_y_o = s2;
  assign dst_z_o = z_q;
endmodule
