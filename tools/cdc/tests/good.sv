// expect: clean
// A 1-bit flag through a 2-FF synchronizer, a 3-bit gray pointer through
// three synchronizers (one group), a dual-clock RAM, and a FIFO-style read
// mux whose select comes from the reading domain.
module t (
  input  logic src_clk_i, src_rst_ni, dst_clk_i, dst_rst_ni,
  input  logic       src_flag_i,
  input  logic [2:0] src_ptr_i,
  input  logic [1:0] src_waddr_i, dst_raddr_i,
  input  logic [7:0] src_wdata_i,
  input  logic       src_we_i,
  output logic       dst_flag_o,
  output logic [2:0] dst_ptr_o,
  output logic [7:0] dst_rdata_o, dst_mux_o
);
  logic flag_q, f1, f2;
  always_ff @(posedge src_clk_i or negedge src_rst_ni) if (!src_rst_ni) flag_q <= 0; else flag_q <= src_flag_i;
  always_ff @(posedge dst_clk_i or negedge dst_rst_ni) if (!dst_rst_ni) {f2, f1} <= 0; else {f2, f1} <= {f1, flag_q};
  assign dst_flag_o = f2;

  logic [2:0] ptr_q, p1, p2;
  always_ff @(posedge src_clk_i or negedge src_rst_ni) if (!src_rst_ni) ptr_q <= 0; else ptr_q <= src_ptr_i;
  always_ff @(posedge dst_clk_i or negedge dst_rst_ni) if (!dst_rst_ni) begin p1 <= 0; p2 <= 0; end
                                                       else begin p1 <= ptr_q; p2 <= p1; end
  assign dst_ptr_o = p2 ^ (p2 >> 1);

  logic [7:0] mem [4];
  logic [7:0] rdata_q;
  always_ff @(posedge src_clk_i) if (src_we_i) mem[src_waddr_i] <= src_wdata_i;
  always_ff @(posedge dst_clk_i) rdata_q <= mem[dst_raddr_i];
  assign dst_rdata_o = rdata_q;

  logic [3:0][7:0] data_q;
  logic [7:0] mux_q;
  always_ff @(posedge src_clk_i or negedge src_rst_ni)
    if (!src_rst_ni) data_q <= '0; else if (src_we_i) data_q[src_waddr_i] <= src_wdata_i;
  always_ff @(posedge dst_clk_i or negedge dst_rst_ni)
    if (!dst_rst_ni) mux_q <= '0; else mux_q <= data_q[dst_raddr_i];
  assign dst_mux_o = mux_q;
endmodule
