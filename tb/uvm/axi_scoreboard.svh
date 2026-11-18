// Copyright 2026 Kuan-Yu Liu
// SPDX-License-Identifier: Apache-2.0
//
`uvm_analysis_imp_decl(_src)
`uvm_analysis_imp_decl(_dst)

// Transaction-level scoreboard. Three checks:
//
// 1. Bridge check: every transaction finished on the source side must be
//    the same, field by field and beat by beat (responses included), as the
//    one finished on the destination side. The DUT keeps the order of every
//    channel, so the k-th write (read) finished at dst must equal the k-th
//    write (read) finished at src. The dst side always finishes first (the
//    response travels back through the bridge), so dst transactions wait in
//    a queue. Out-of-order responses between IDs do not change this: both
//    monitors see the same B / R order, because the DUT keeps it.
//
// 2. End-to-end data check against axi_ref_model, a byte memory built with
//    its own address math (see that file): every write finished at src
//    updates it (only if the address map says OKAY); every read beat
//    finished at src must return what it holds on the active byte lanes.
//
// 3. Response check: every write response and every read beat must carry
//    the response of the address map (OKAY, or SLVERR / DECERR in the error
//    pages). Data of error beats is not checked (AXI leaves it undefined).
//
// With +TRACE_FILE=<path>, every transaction finished at src is also
// written as one line (fields + hashes of data and responses), so two runs
// can be compared transaction by transaction (tools/compare_traces.py).
//
// At the end of the test both queues must be empty: nothing lost, nothing
// duplicated, nothing extra.
class axi_scoreboard extends uvm_scoreboard;
  `uvm_component_utils(axi_scoreboard)

  uvm_analysis_imp_src #(axi_seq_item, axi_scoreboard) src_imp;
  uvm_analysis_imp_dst #(axi_seq_item, axi_scoreboard) dst_imp;

  axi_tb_cfg    cfg;
  axi_ref_model ref_model;
  axi_seq_item  dst_wr_q[$];   // finished at dst, waiting for src
  axi_seq_item  dst_rd_q[$];
  int           trace_fd;

  int unsigned n_wr_ok, n_wr_bad, n_rd_ok, n_rd_bad, n_beat_ok, n_beat_bad;
  int unsigned n_wbeat;        // write beats compared by the bridge check
  int unsigned n_resp_err;     // error responses (SLVERR/DECERR) seen as expected
  int unsigned n_resp_bad;     // responses that differ from the address map

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    string path;
    super.build_phase(phase);
    src_imp = new("src_imp", this);
    dst_imp = new("dst_imp", this);
    if (!uvm_config_db #(axi_tb_cfg)::get(this, "", "cfg", cfg))
      cfg = axi_tb_cfg::type_id::create("cfg");
    ref_model = axi_ref_model::type_id::create("ref_model");
    ref_model.cfg = cfg;
    if ($value$plusargs("TRACE_FILE=%s", path)) begin
      trace_fd = $fopen(path, "w");
      if (trace_fd == 0) `uvm_error("TRACE", {"cannot open ", path})
    end
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
        if (d == "") begin
          n_wr_ok++;
          n_wbeat += t.data.size();
        end else begin
          n_wr_bad++;
          `uvm_error("SB_WRITE", $sformatf("src/dst write differ:%s\n  src: %s\n  dst: %s",
                                           d, t.convert2string(), exp.convert2string()))
        end
      end
      check_write_resp(t);
      ref_model.write(t);
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
      // ---- 2. and 3. data and response check
      check_read(t);
    end
    if (trace_fd) $fdisplay(trace_fd, "%s", trace_line(t));
  endfunction

  function void check_write_resp(axi_seq_item t);
    axi_pkg::resp_t r = ref_model.expected_resp(t.addr);
    if (t.resp.size() != 1 || t.resp[0] !== r) begin
      n_resp_bad++;
      `uvm_error("SB_RESP", $sformatf("write id %0h addr %h: response %0d, address map says %0d",
                                      t.id, t.addr, t.resp.size() ? t.resp[0] : 2'bxx, r))
    end else if (r != axi_pkg::RESP_OKAY) n_resp_err++;
  endfunction

  function void check_read(axi_seq_item t);
    data_t          exp[];
    int unsigned    lo[], hi[];
    axi_pkg::resp_t r = ref_model.expected_resp(t.addr);
    bit             beat_ok;
    ref_model.read_expect(t, exp, lo, hi);
    if (t.rdata.size() != exp.size()) begin
      n_beat_bad++;
      `uvm_error("SB_DATA", $sformatf("read id %0h addr %h: %0d beats, expected %0d", t.id, t.addr, t.rdata.size(), exp.size()))
      return;
    end
    foreach (t.rdata[i]) begin
      if (t.resp[i] !== r) begin
        n_resp_bad++;
        `uvm_error("SB_RESP", $sformatf("read id %0h addr %h beat %0d: response %0d, address map says %0d",
                                        t.id, t.addr, i, t.resp[i], r))
        continue;
      end
      if (r != axi_pkg::RESP_OKAY) begin  // error beat: data is undefined
        n_resp_err++;
        continue;
      end
      beat_ok = 1'b1;
      for (int unsigned b = lo[i]; b <= hi[i]; b++)
        if (t.rdata[i][8*b +: 8] !== exp[i][8*b +: 8]) beat_ok = 1'b0;
      if (beat_ok) n_beat_ok++;
      else begin
        n_beat_bad++;
        `uvm_error("SB_DATA", $sformatf("read id %0h addr %h beat %0d: got %h, reference model says %h (lanes %0d..%0d)",
                                        t.id, t.addr, i, t.rdata[i], exp[i], lo[i], hi[i]))
      end
    end
  endfunction

  // 32-bit FNV-1a over a byte stream, to keep trace lines short.
  static function bit [31:0] fnv(bit [31:0] h, logic [63:0] v, int unsigned nbytes);
    for (int unsigned b = 0; b < nbytes; b++) begin
      h = h ^ 32'(v[8*b +: 8]);
      h = h * 32'h0100_0193;
    end
    return h;
  endfunction

  function string trace_line(axi_seq_item t);
    bit [31:0] hd = 32'h811c_9dc5, hr = 32'h811c_9dc5;
    if (t.kind == AXI_WRITE) begin
      foreach (t.data[i]) begin
        hd = fnv(hd, 64'(t.data[i]), SW);
        hd = fnv(hd, 64'(t.strb[i]), 1);
        hd = fnv(hd, 64'(t.wuser[i]), 1);
      end
      hr = fnv(hr, 64'(t.buser), 1);
    end else begin
      foreach (t.rdata[i]) begin
        hd = fnv(hd, 64'(t.rdata[i]), SW);
        hd = fnv(hd, 64'(t.ruser[i]), 1);
      end
    end
    foreach (t.resp[i]) hr = fnv(hr, 64'(t.resp[i]), 1);
    return $sformatf("%s id=%h addr=%h len=%0d size=%0d burst=%0d cache=%h prot=%h qos=%h region=%h user=%h data=%h resp=%h",
                     t.kind == AXI_WRITE ? "W" : "R", t.id, t.addr, t.len, t.size, t.burst,
                     t.cache, t.prot, t.qos, t.region, t.user, hd, hr);
  endfunction

  function void check_phase(uvm_phase phase);
    if (dst_wr_q.size() || dst_rd_q.size())
      `uvm_error("SB_MISSING", $sformatf("finished at dst but never at src: %0d writes, %0d reads",
                                         dst_wr_q.size(), dst_rd_q.size()))
  endfunction

  function void report_phase(uvm_phase phase);
    if (trace_fd) $fclose(trace_fd);
    `uvm_info("SB", $sformatf("bridge check: writes %0d ok / %0d bad, reads %0d ok / %0d bad; data check: %0d beats ok / %0d bad; write beats %0d; error responses %0d ok / %0d bad",
                              n_wr_ok, n_wr_bad, n_rd_ok, n_rd_bad, n_beat_ok, n_beat_bad, n_wbeat, n_resp_err, n_resp_bad), UVM_NONE)
    if (n_wr_ok + n_rd_ok == 0)
      `uvm_error("SB_EMPTY", "scoreboard compared nothing")
  endfunction
endclass
