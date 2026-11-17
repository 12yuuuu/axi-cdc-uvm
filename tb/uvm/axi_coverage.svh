// Copyright 2026 Kuan-Yu Liu
// SPDX-License-Identifier: Apache-2.0
//
// Functional coverage for the CDC bridge (see docs/vplan.md).
//
//   txn    shape of every transaction sent into the DUT (from the source
//          monitor): kind, burst type, length, beat size, alignment, strobes
//   flow   DUT events, checked every clock cycle:
//            full.X  the FIFO of channel X was full (VALID=1, READY=0 at its
//                    input: AW/W/AR on the source side, B/R on the dest side)
//            b2b.X   the DUT gave out channel X on two cycles in a row
//                    (the FIFO streams at full rate across the CDC)
//            rw      AW and AR handshakes in the same source cycle
//   order  AW vs. first W beat of each write, on both sides of the DUT
//   clk    clock relation of this run: period ratio bucket, and whether the
//          two clocks ever had a rising edge at the same time
//   scen   which FIFO was full under which clock relation
//
// The covergroups go to the simulator's coverage database. The same bins
// are also counted here and printed as "[COVBIN] <bin> <hits>" lines, so
// tools/merge_cov.py can merge coverage over many runs without a coverage
// tool.
typedef enum {LEN_1, LEN_2, LEN_3_4, LEN_5_8, LEN_9_15, LEN_16, LEN_17_255, LEN_256} cov_len_e;
typedef enum {ALIGNED, UNALIGNED} cov_align_e;
typedef enum {STRB_FULL, STRB_PARTIAL, STRB_EMPTY_BEAT} cov_strb_e;
typedef enum {SRC_FAST_2X, SRC_FAST, SAME_FREQ, DST_FAST, DST_FAST_2X} cov_ratio_e;
typedef enum {NO_COINCIDENT_EDGES, COINCIDENT_EDGES} cov_phase_e;
typedef enum {CH_AW, CH_W, CH_AR, CH_B, CH_R} cov_ch_e;
typedef enum {SIDE_SRC, SIDE_DST} cov_side_e;
typedef enum {W_BEFORE_AW, AW_W_SAME_CYCLE, AW_BEFORE_W} cov_order_e;

class axi_coverage extends uvm_subscriber #(axi_seq_item);
  `uvm_component_utils(axi_coverage)

  virtual axi_vif src_vif, dst_vif;
  realtime        src_period, dst_period;

  int unsigned hits[string];      // every coverage goal, with its hit count
  int unsigned n_full[5];         // full cycles per channel (cov_ch_e)
  int unsigned n_coincident;      // rising edges of both clocks at the same time
  int unsigned aw_n[2], wf_n[2];  // per side: AW handshakes, first W beats
  bit          in_burst[2];       // per side: inside a W burst
  cov_ratio_e  ratio_b;          // clock relation of this run (set at the end)
  cov_phase_e  phase_b;

  covergroup cg_txn with function sample(axi_kind_e kind, axi_pkg::burst_t burst, cov_len_e len,
                                         axi_pkg::size_t size, cov_align_e align, cov_strb_e strb);
    cp_kind  : coverpoint kind;
    cp_burst : coverpoint burst { bins FIXED = {axi_pkg::BURST_FIXED};
                                  bins INCR  = {axi_pkg::BURST_INCR};
                                  bins WRAP  = {axi_pkg::BURST_WRAP}; }
    cp_len   : coverpoint len;
    cp_size  : coverpoint size  { bins B1 = {0}; bins B2 = {1}; bins B4 = {2}; bins B8 = {3}; }
    cp_align : coverpoint align;
    cp_strb  : coverpoint strb iff (kind == AXI_WRITE);
    // FIXED: at most 16 beats. WRAP: 2, 4, 8 or 16 beats (AXI spec A3.4.1).
    x_kbl    : cross cp_kind, cp_burst, cp_len {
      ignore_bins fixed_long = binsof(cp_burst.FIXED) && binsof(cp_len) intersect {LEN_17_255, LEN_256};
      ignore_bins wrap_bad   = binsof(cp_burst.WRAP)  && binsof(cp_len) intersect {LEN_1, LEN_9_15, LEN_17_255, LEN_256};
    }
    x_ks     : cross cp_kind, cp_size;
  endgroup

  covergroup cg_flow with function sample(int unsigned what, cov_ch_e ch);
    cp_full : coverpoint ch iff (what == 0);
    cp_b2b  : coverpoint ch iff (what == 1);
    cp_rw   : coverpoint what { bins aw_ar_same_cycle = {2}; }
  endgroup

  covergroup cg_order with function sample(cov_side_e side, cov_order_e ord);
    cp_side : coverpoint side;
    cp_ord  : coverpoint ord;
    x_so    : cross cp_side, cp_ord;
  endgroup

  covergroup cg_clk with function sample(cov_ratio_e r, cov_phase_e p);
    cp_ratio : coverpoint r;
    cp_phase : coverpoint p;
    x_rp     : cross cp_ratio, cp_phase;
  endgroup

  covergroup cg_scen with function sample(cov_ch_e ch, cov_ratio_e r, cov_phase_e p);
    cp_ch    : coverpoint ch;
    cp_ratio : coverpoint r;
    cp_phase : coverpoint p;
    x_cr     : cross cp_ch, cp_ratio;
    x_cp     : cross cp_ch, cp_phase;
  endgroup

  function new(string name, uvm_component parent);
    super.new(name, parent);
    cg_txn   = new();
    cg_flow  = new();
    cg_order = new();
    cg_clk   = new();
    cg_scen  = new();
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db #(virtual axi_vif)::get(this, "", "src_vif", src_vif) ||
        !uvm_config_db #(virtual axi_vif)::get(this, "", "dst_vif", dst_vif))
      `uvm_fatal("NOVIF", "coverage: no src_vif / dst_vif")
    if (!uvm_config_db #(realtime)::get(this, "", "SRC_PERIOD", src_period) ||
        !uvm_config_db #(realtime)::get(this, "", "DST_PERIOD", dst_period))
      `uvm_fatal("NOCLK", "coverage: no SRC_PERIOD / DST_PERIOD")
    add_goals();
  endfunction

  // ---------------------------------------------------------------- goals
  static function string burst_name(axi_pkg::burst_t b);
    case (b)
      axi_pkg::BURST_FIXED: return "FIXED";
      axi_pkg::BURST_INCR:  return "INCR";
      default:              return "WRAP";
    endcase
  endfunction

  static function string size_name(axi_pkg::size_t s);
    return $sformatf("B%0d", 1 << s);
  endfunction

  // Same legal set as the ignore_bins of x_kbl.
  static function bit legal_len(axi_pkg::burst_t b, cov_len_e l);
    if (b == axi_pkg::BURST_FIXED) return !(l inside {LEN_17_255, LEN_256});
    if (b == axi_pkg::BURST_WRAP)  return !(l inside {LEN_1, LEN_9_15, LEN_17_255, LEN_256});
    return 1'b1;
  endfunction

  function void goal(string k);
    hits[k] = 0;
  endfunction

  function void hit(string k);
    if (!hits.exists(k)) `uvm_error("COVKEY", {"unknown coverage bin ", k})
    else hits[k]++;
  endfunction

  function void add_goals();
    axi_kind_e  k;
    cov_len_e   l;
    cov_align_e a;
    cov_strb_e  s;
    cov_ratio_e r;
    cov_phase_e p;
    cov_ch_e    c;
    cov_side_e  sd;
    cov_order_e o;
    axi_pkg::burst_t bursts[3] = '{axi_pkg::BURST_FIXED, axi_pkg::BURST_INCR, axi_pkg::BURST_WRAP};
    k = k.first(); do begin goal({"txn.kind.", k.name()}); k = k.next(); end while (k != k.first());
    foreach (bursts[i]) goal({"txn.burst.", burst_name(bursts[i])});
    l = l.first(); do begin goal({"txn.len.", l.name()}); l = l.next(); end while (l != l.first());
    for (int z = 0; z <= 3; z++) goal({"txn.size.", size_name(z)});
    a = a.first(); do begin goal({"txn.align.", a.name()}); a = a.next(); end while (a != a.first());
    s = s.first(); do begin goal({"txn.strb.", s.name()}); s = s.next(); end while (s != s.first());
    k = k.first();
    do begin
      foreach (bursts[i]) begin
        l = l.first();
        do begin
          if (legal_len(bursts[i], l)) goal({"txn.x_kbl.", k.name(), ".", burst_name(bursts[i]), ".", l.name()});
          l = l.next();
        end while (l != l.first());
      end
      for (int z = 0; z <= 3; z++) goal({"txn.x_ks.", k.name(), ".", size_name(z)});
      k = k.next();
    end while (k != k.first());

    c = c.first();
    do begin goal({"flow.full.", c.name()}); goal({"flow.b2b.", c.name()}); c = c.next(); end while (c != c.first());
    goal("flow.rw.aw_ar_same_cycle");

    sd = sd.first();
    do begin
      o = o.first(); do begin goal({"order.", sd.name(), ".", o.name()}); o = o.next(); end while (o != o.first());
      sd = sd.next();
    end while (sd != sd.first());

    r = r.first(); do begin goal({"clk.ratio.", r.name()}); r = r.next(); end while (r != r.first());
    p = p.first(); do begin goal({"clk.phase.", p.name()}); p = p.next(); end while (p != p.first());
    r = r.first();
    do begin
      p = p.first(); do begin goal({"clk.x.", r.name(), ".", p.name()}); p = p.next(); end while (p != p.first());
      r = r.next();
    end while (r != r.first());

    c = c.first();
    do begin
      r = r.first(); do begin goal({"scen.ratio.", c.name(), ".", r.name()}); r = r.next(); end while (r != r.first());
      p = p.first(); do begin goal({"scen.phase.", c.name(), ".", p.name()}); p = p.next(); end while (p != p.first());
      c = c.next();
    end while (c != c.first());
  endfunction

  // ------------------------------------------------------- transactions
  static function cov_len_e len_bin(axi_pkg::len_t len);
    if (len == 0)   return LEN_1;
    if (len == 1)   return LEN_2;
    if (len <= 3)   return LEN_3_4;
    if (len <= 7)   return LEN_5_8;
    if (len <= 14)  return LEN_9_15;
    if (len == 15)  return LEN_16;
    if (len <= 254) return LEN_17_255;
    return LEN_256;
  endfunction

  // Strobes, over the active byte lanes of each beat only.
  static function cov_strb_e strb_bin(axi_seq_item t);
    int unsigned lo, hi;
    bit partial = 1'b0;
    foreach (t.strb[i]) begin
      if (t.strb[i] == '0) return STRB_EMPTY_BEAT;
      t.beat_lanes(i, lo, hi);
      for (int unsigned b = lo; b <= hi; b++) if (!t.strb[i][b]) partial = 1'b1;
    end
    return partial ? STRB_PARTIAL : STRB_FULL;
  endfunction

  function void write(axi_seq_item t);
    cov_len_e   l = len_bin(t.len);
    cov_align_e a = (t.addr % (1 << t.size) == 0) ? ALIGNED : UNALIGNED;
    cov_strb_e  s = (t.kind == AXI_WRITE) ? strb_bin(t) : STRB_FULL;
    string      bn = burst_name(t.burst), sn = size_name(t.size);
    cg_txn.sample(t.kind, t.burst, l, t.size, a, s);
    hit({"txn.kind.", t.kind.name()});
    hit({"txn.burst.", bn});
    hit({"txn.len.", l.name()});
    hit({"txn.size.", sn});
    hit({"txn.align.", a.name()});
    if (t.kind == AXI_WRITE) hit({"txn.strb.", s.name()});
    hit({"txn.x_kbl.", t.kind.name(), ".", bn, ".", l.name()});
    hit({"txn.x_ks.", t.kind.name(), ".", sn});
  endfunction

  // ------------------------------------------------------ per-cycle events
  function void full(cov_ch_e c);
    n_full[c]++;
    cg_flow.sample(0, c);
    hit({"flow.full.", c.name()});
  endfunction

  function void b2b(cov_ch_e c);
    cg_flow.sample(1, c);
    hit({"flow.b2b.", c.name()});
  endfunction

  // Called every cycle of one side with that cycle's AW and W handshakes.
  function void order_step(cov_side_e sd, bit aw_hs, bit w_hs, bit w_last);
    bit         first = w_hs && !in_burst[sd];
    cov_order_e o;
    if (aw_hs) aw_n[sd]++;
    if (first) begin
      wf_n[sd]++;
      if (wf_n[sd] > aw_n[sd])               o = W_BEFORE_AW;     // W burst k started, AW k not seen yet
      else if (wf_n[sd] == aw_n[sd] && aw_hs) o = AW_W_SAME_CYCLE; // AW k came in this cycle
      else                                    o = AW_BEFORE_W;
      cg_order.sample(sd, o);
      hit({"order.", sd.name(), ".", o.name()});
    end
    if (w_hs) in_burst[sd] = !w_last;
  endfunction

  task run_phase(uvm_phase phase);
    fork
      watch_src();
      watch_dst();
      watch_edges();
    join
  endtask

  task watch_src();
    bit aw_hs, w_hs, ar_hs, b_hs, r_hs, b_q, r_q;
    wait (src_vif.rst_n === 1'b1);
    forever begin
      @(src_vif.mon_cb);
      if (src_vif.rst_n !== 1'b1) continue;
      aw_hs = src_vif.mon_cb.aw_valid === 1'b1 && src_vif.mon_cb.aw_ready === 1'b1;
      w_hs  = src_vif.mon_cb.w_valid  === 1'b1 && src_vif.mon_cb.w_ready  === 1'b1;
      ar_hs = src_vif.mon_cb.ar_valid === 1'b1 && src_vif.mon_cb.ar_ready === 1'b1;
      b_hs  = src_vif.mon_cb.b_valid  === 1'b1 && src_vif.mon_cb.b_ready  === 1'b1;
      r_hs  = src_vif.mon_cb.r_valid  === 1'b1 && src_vif.mon_cb.r_ready  === 1'b1;
      if (src_vif.mon_cb.aw_valid === 1'b1 && src_vif.mon_cb.aw_ready !== 1'b1) full(CH_AW);
      if (src_vif.mon_cb.w_valid  === 1'b1 && src_vif.mon_cb.w_ready  !== 1'b1) full(CH_W);
      if (src_vif.mon_cb.ar_valid === 1'b1 && src_vif.mon_cb.ar_ready !== 1'b1) full(CH_AR);
      if (b_hs && b_q) b2b(CH_B);
      if (r_hs && r_q) b2b(CH_R);
      if (aw_hs && ar_hs) begin
        cg_flow.sample(2, CH_AW);
        hit("flow.rw.aw_ar_same_cycle");
      end
      order_step(SIDE_SRC, aw_hs, w_hs, src_vif.mon_cb.w_last === 1'b1);
      b_q = b_hs;
      r_q = r_hs;
    end
  endtask

  task watch_dst();
    bit aw_hs, w_hs, ar_hs, aw_q, w_q, ar_q;
    wait (dst_vif.rst_n === 1'b1);
    forever begin
      @(dst_vif.mon_cb);
      if (dst_vif.rst_n !== 1'b1) continue;
      aw_hs = dst_vif.mon_cb.aw_valid === 1'b1 && dst_vif.mon_cb.aw_ready === 1'b1;
      w_hs  = dst_vif.mon_cb.w_valid  === 1'b1 && dst_vif.mon_cb.w_ready  === 1'b1;
      ar_hs = dst_vif.mon_cb.ar_valid === 1'b1 && dst_vif.mon_cb.ar_ready === 1'b1;
      if (dst_vif.mon_cb.b_valid === 1'b1 && dst_vif.mon_cb.b_ready !== 1'b1) full(CH_B);
      if (dst_vif.mon_cb.r_valid === 1'b1 && dst_vif.mon_cb.r_ready !== 1'b1) full(CH_R);
      if (aw_hs && aw_q) b2b(CH_AW);
      if (w_hs  && w_q)  b2b(CH_W);
      if (ar_hs && ar_q) b2b(CH_AR);
      order_step(SIDE_DST, aw_hs, w_hs, dst_vif.mon_cb.w_last === 1'b1);
      aw_q = aw_hs;
      w_q  = w_hs;
      ar_q = ar_hs;
    end
  endtask

  // Count rising edges of the two clocks at exactly the same time. When
  // both happen at once, the second process to wake up sees the first
  // one's time, so each such edge pair is counted once.
  task watch_edges();
    realtime t_src = -1.0, t_dst = -2.0;
    fork
      forever begin @(posedge src_vif.clk); t_src = $realtime; if (t_dst == t_src) n_coincident++; end
      forever begin @(posedge dst_vif.clk); t_dst = $realtime; if (t_src == t_dst) n_coincident++; end
    join
  endtask

  // ------------------------------------------------------------ end of run
  function cov_ratio_e ratio_bin();
    real r = src_period / dst_period;
    if (r <= 0.5)  return SRC_FAST_2X;
    if (r < 0.95)  return SRC_FAST;
    if (r <= 1.05) return SAME_FREQ;
    if (r < 2.0)   return DST_FAST;
    return DST_FAST_2X;
  endfunction

  function void extract_phase(uvm_phase phase);
    cov_ch_e c;
    super.extract_phase(phase);
    ratio_b = ratio_bin();
    phase_b = (n_coincident > 0) ? COINCIDENT_EDGES : NO_COINCIDENT_EDGES;
    cg_clk.sample(ratio_b, phase_b);
    hit({"clk.ratio.", ratio_b.name()});
    hit({"clk.phase.", phase_b.name()});
    hit({"clk.x.", ratio_b.name(), ".", phase_b.name()});
    c = c.first();
    do begin
      if (n_full[c] > 0) begin
        cg_scen.sample(c, ratio_b, phase_b);
        hit({"scen.ratio.", c.name(), ".", ratio_b.name()});
        hit({"scen.phase.", c.name(), ".", phase_b.name()});
      end
      c = c.next();
    end while (c != c.first());
  endfunction

  function void report_phase(uvm_phase phase);
    string groups[5] = '{"txn", "flow", "order", "clk", "scen"};
    int unsigned g_hit[string], g_all[string];
    int unsigned n_hit = 0, n_all = 0;
    string       s = "";
    foreach (hits[k]) begin
      string g = k;
      for (int i = 0; i < k.len(); i++)
        if (k[i] == ".") begin g = k.substr(0, i - 1); break; end
      g_all[g]++;
      n_all++;
      if (hits[k] > 0) begin g_hit[g]++; n_hit++; end
    end
    foreach (groups[i]) s = {s, $sformatf("%s %0d/%0d, ", groups[i], g_hit[groups[i]], g_all[groups[i]])};
    `uvm_info("COV", $sformatf("bins hit: %stotal %0d/%0d; coincident clock edges %0d; ratio %s",
                               s, n_hit, n_all, n_coincident, ratio_b.name()), UVM_LOW)
    `uvm_info("COV", $sformatf("simulator covergroup %%: txn %0.1f, flow %0.1f, order %0.1f, clk %0.1f, scen %0.1f",
                               cg_txn.get_coverage(), cg_flow.get_coverage(), cg_order.get_coverage(),
                               cg_clk.get_coverage(), cg_scen.get_coverage()), UVM_LOW)
    foreach (hits[k]) $display("[COVBIN] %s %0d", k, hits[k]);
  endfunction
endclass
