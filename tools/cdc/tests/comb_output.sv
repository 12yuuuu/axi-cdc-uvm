// expect: CDC-OUTPUT
// A destination output that depends combinationally on a source register.
module t (input logic src_clk_i, src_rst_ni, dst_clk_i, dst_rst_ni, src_a_i, output logic dst_y_o);
  logic a_q;
  always_ff @(posedge src_clk_i or negedge src_rst_ni) if (!src_rst_ni) a_q <= 0; else a_q <= src_a_i;
  assign dst_y_o = ~a_q;
endmodule
