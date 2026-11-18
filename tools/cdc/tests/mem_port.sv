// expect: CDC-MEMPORT
// A dual-clock RAM whose read address comes from the writing domain.
module t (input logic src_clk_i, dst_clk_i, src_rst_ni, dst_rst_ni, input logic [1:0] src_a_i,
          input logic [7:0] src_d_i, input logic src_we_i, output logic [7:0] dst_y_o);
  logic [7:0] mem [4];
  logic [1:0] a_q;
  logic [7:0] y_q;
  always_ff @(posedge src_clk_i) begin if (src_we_i) mem[src_a_i] <= src_d_i; a_q <= src_a_i; end
  always_ff @(posedge dst_clk_i) y_q <= mem[a_q];
  assign dst_y_o = y_q;
endmodule
