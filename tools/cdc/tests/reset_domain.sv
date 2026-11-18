// expect: CDC-RESET
// A destination register reset by the source reset.
module t (input logic src_clk_i, src_rst_ni, dst_clk_i, dst_rst_ni, dst_a_i, output logic dst_y_o);
  logic y_q;
  always_ff @(posedge dst_clk_i or negedge src_rst_ni) if (!src_rst_ni) y_q <= 0; else y_q <= dst_a_i;
  assign dst_y_o = y_q;
endmodule
