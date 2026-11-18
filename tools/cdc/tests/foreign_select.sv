// expect: CDC-MUXSEL
// A FIFO-style read mux whose select comes from the writing domain.
module t (input logic src_clk_i, src_rst_ni, dst_clk_i, dst_rst_ni, input logic [1:0] src_idx_i,
          input logic [7:0] src_d_i, output logic [7:0] dst_y_o);
  logic [3:0][7:0] data_q;
  logic [1:0] idx_q;
  logic [7:0] y_q;
  always_ff @(posedge src_clk_i or negedge src_rst_ni)
    if (!src_rst_ni) begin data_q <= '0; idx_q <= '0; end
    else begin data_q[src_idx_i] <= src_d_i; idx_q <= src_idx_i; end
  always_ff @(posedge dst_clk_i or negedge dst_rst_ni) if (!dst_rst_ni) y_q <= '0; else y_q <= data_q[idx_q];
  assign dst_y_o = y_q;
endmodule
