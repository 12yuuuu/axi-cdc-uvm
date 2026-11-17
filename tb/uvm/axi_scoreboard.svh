// Copyright 2026 Kuan-Yu Liu
// SPDX-License-Identifier: Apache-2.0
//
`uvm_analysis_imp_decl(_src)
`uvm_analysis_imp_decl(_dst)

// Transaction-level scoreboard. Two checks:
//
// 1. Bridge check: every transaction finished on the source side must be
//    the same, field by field and beat by beat, as the one finished on the
//    destination side. The DUT keeps the order of every channel, so the k-th
//    write (read) finished at dst must equal the k-th write (read) finished
//    at src. The dst side always finishes first (the response travels back
//    through the bridge), so dst transactions wait in a queue.
//
// 2. End-to-end data check: a reference memory is updated by every write
//    finished at src; every read finished at src must return what the
//    reference memory holds for its active byte lanes (never-written bytes
//    read as 0, same as the slave model).
//
// At the end of the test both queues must be empty: nothing lost, nothing
// duplicated, nothing extra.
class axi_scoreboard extends uvm_scoreboard;
  `uvm_component_utils(axi_scoreboard)

  uvm_analysis_imp_src #(axi_seq_item, axi_scoreboard) src_imp;
  uvm_analysis_imp_dst #(axi_seq_item, axi_scoreboard) dst_imp;

  axi_seq_item dst_wr_q[$];   // finished at dst, waiting for src
  axi_seq_item dst_rd_q[$];
  bit [7:0]    ref_mem [addr_t];

  int unsigned n_wr_ok, n_wr_bad, n_rd_ok, n_rd_bad, n_beat_ok, n_beat_bad;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    src_imp = new("src_imp", this);
    dst_imp = new("dst_imp", this);
  endfunction

  function void write_dst(axi_seq_item t);
    if (t.kind == AXI_WRITE) dst_wr_q.push_back(t);
    else                     dst_rd_q.push_back(t);
  endfunction

  function void write_src(axi_seq_item t);
    axi_seq_item exp;
    string       d;
    // ---- 1. bridge check
    if (t.kind == AXI_WRITE) begin
      if (dst_wr_q.size() == 0) begin
        `uvm_error("SB_EXTRA", {"write finished at src but never seen at dst: ", t.convert2string()})
        n_wr_bad++;
      end else begin
        exp = dst_wr_q.pop_front();
        d = t.diff(exp);
        if (d == "") n_wr_ok++;
        else begin
          n_wr_bad++;
          `uvm_error("SB_WRITE", $sformatf("src/dst write differ:%s\n  src: %s\n  dst: %s",
                                           d, t.convert2string(), exp.convert2string()))
        end
      end
      update_ref(t);
    end else begin
      if (dst_rd_q.size() == 0) begin
        `uvm_error("SB_EXTRA", {"read finished at src but never seen at dst: ", t.convert2string()})
        n_rd_bad++;
      end else begin
        exp = dst_rd_q.pop_front();
        d = t.diff(exp);
        if (d == "") n_rd_ok++;
        else begin
          n_rd_bad++;
          `uvm_error("SB_READ", $sformatf("src/dst read differ:%s\n  src: %s\n  dst: %s",
                                          d, t.convert2string(), exp.convert2string()))
        end
      end
      // ---- 2. end-to-end data check
      check_read_data(t);
    end
  endfunction

  function void update_ref(axi_seq_item t);
    addr_t       base;
    int unsigned lo, hi;
    if (t.resp.size() != 1 || t.resp[0] !== axi_pkg::RESP_OKAY) return;
    foreach (t.data[i]) begin
      t.beat_lanes(i, lo, hi);
      base = axi_seq_item::calc_beat_addr(t.addr, t.size, t.len, t.burst, i) & ~addr_t'(SW - 1);
      for (int unsigned b = lo; b <= hi; b++)
        if (t.strb[i][b]) ref_mem[base + addr_t'(b)] = t.data[i][8*b +: 8];
    end
  endfunction

  function void check_read_data(axi_seq_item t);
    addr_t       base;
    int unsigned lo, hi;
    bit [7:0]    exp;
    bit          beat_ok;
    foreach (t.rdata[i]) begin
      t.beat_lanes(i, lo, hi);
      base = axi_seq_item::calc_beat_addr(t.addr, t.size, t.len, t.burst, i) & ~addr_t'(SW - 1);
      beat_ok = 1'b1;
      for (int unsigned b = lo; b <= hi; b++) begin
        exp = ref_mem.exists(base + addr_t'(b)) ? ref_mem[base + addr_t'(b)] : 8'h00;
        if (t.rdata[i][8*b +: 8] !== exp) beat_ok = 1'b0;
      end
      if (beat_ok) n_beat_ok++;
      else begin
        n_beat_bad++;
        `uvm_error("SB_DATA", $sformatf("read id %0h addr %h beat %0d: got %h, reference memory says otherwise (lanes %0d..%0d)",
                                        t.id, t.addr, i, t.rdata[i], lo, hi))
      end
    end
  endfunction

  function void check_phase(uvm_phase phase);
    if (dst_wr_q.size() || dst_rd_q.size())
      `uvm_error("SB_MISSING", $sformatf("finished at dst but never at src: %0d writes, %0d reads",
                                         dst_wr_q.size(), dst_rd_q.size()))
  endfunction

  function void report_phase(uvm_phase phase);
    `uvm_info("SB", $sformatf("bridge check: writes %0d ok / %0d bad, reads %0d ok / %0d bad; data check: %0d beats ok / %0d bad",
                              n_wr_ok, n_wr_bad, n_rd_ok, n_rd_bad, n_beat_ok, n_beat_bad), UVM_NONE)
    if (n_wr_ok + n_rd_ok == 0)
      `uvm_error("SB_EMPTY", "scoreboard compared nothing")
  endfunction
endclass
