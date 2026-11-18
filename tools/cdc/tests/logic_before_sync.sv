// expect: CDC-SYNC-LOGIC
// Two source bits combined before the synchronizer: the XOR can glitch.
module t (input logic src_clk_i, src_rst_ni, dst_clk_i, dst_rst_ni, src_a_i, src_b_i, output logic dst_y_o);
  logic a_q, b_q, s1, s2;
  always_ff @(posedge src_clk_i or negedge src_rst_ni) if (!src_rst_ni) {a_q, b_q} <= 0; else {a_q, b_q} <= {src_a_i, src_b_i};
  always_ff @(posedge dst_clk_i or negedge dst_rst_ni) if (!dst_rst_ni) {s2, s1} <= 0; else {s2, s1} <= {s1, a_q ^ b_q};
  assign dst_y_o = s2;
endmodule
