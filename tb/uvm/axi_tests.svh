// Copyright 2026 Kuan-Yu Liu
// SPDX-License-Identifier: Apache-2.0
//
// Base test: builds the config object and the environment, runs the
// traffic of the derived test, waits until every transaction has its
// response, and prints PASSED / FAILED.
class axi_base_test extends uvm_test;
  `uvm_component_utils(axi_base_test)

  axi_env      env;
  axi_tb_cfg   cfg;
  int unsigned log_depth = 2;     // DUT FIFO depth is 2**log_depth (from tb_top)
  realtime     slow_period = 10ns; // period of the slower clock (from tb_top)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    void'(uvm_config_db #(int unsigned)::get(this, "", "LOG_DEPTH", log_depth));
    void'(uvm_config_db #(realtime)::get(this, "", "SLOW_PERIOD", slow_period));
    cfg = axi_tb_cfg::type_id::create("cfg");
    set_knobs();
    uvm_config_db #(axi_tb_cfg)::set(this, "env*", "cfg", cfg);
    env = axi_env::type_id::create("env", this);
  endfunction

  // Derived tests change cfg here.
  virtual function void set_knobs();
  endfunction

  // Derived tests create their traffic here.
  virtual task run_traffic();
  endtask

  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    run_traffic();
    idle();
    #(50 * slow_period);  // let the monitors see the last handshakes
    phase.drop_objection(this);
  endtask

  // ---- helpers for the derived tests
  function axi_rand_seq mk_seq(string name, int kind_sel, addr_t base, int unsigned span, int unsigned n);
    axi_rand_seq s = axi_rand_seq::type_id::create(name);
    s.kind_sel = kind_sel;
    s.base     = base;
    s.span     = span;
    s.n        = n;
    return s;
  endfunction

  task sweep(addr_t base, int unsigned bytes);
    axi_sweep_read_seq s = axi_sweep_read_seq::type_id::create("sweep");
    s.base  = base;
    s.bytes = bytes;
    s.start(env.mst.sqr);
  endtask

  task idle();
    env.mst.drv.wait_idle();
  endtask

  function void report_phase(uvm_phase phase);
    uvm_report_server rs = uvm_report_server::get_server();
    if (rs.get_severity_count(UVM_FATAL) + rs.get_severity_count(UVM_ERROR) == 0)
      `uvm_info("RESULT", "*** TEST PASSED ***", UVM_NONE)
    else
      `uvm_info("RESULT", "*** TEST FAILED ***", UVM_NONE)
  endfunction
endclass

// One single-beat and one 4-beat write, each read back.
class smoke_test extends axi_base_test;
  `uvm_component_utils(smoke_test)
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  task run_traffic();
    smoke_seq s = smoke_seq::type_id::create("smoke");
    s.do_reads = 1'b0;
    s.start(env.mst.sqr);
    idle();              // the writes must finish before the reads start
    s.do_reads = 1'b1;
    s.start(env.mst.sqr);
  endtask
endclass

// Burst shapes: INCR of length 1, 2, 3, 4, 8, 16 and 256 beats; then narrow
// beats, unaligned starts, FIXED, WRAP and sparse strobes. Everything is
// read back (full sweeps and shaped reads).
class burst_test extends axi_base_test;
  `uvm_component_utils(burst_test)
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  task run_traffic();
    axi_rand_seq s;
    int unsigned lens[7] = '{0, 1, 2, 3, 7, 15, 255};
    foreach (lens[i]) begin  // each length in its own 4 KiB page of region A
      s = mk_seq($sformatf("incr_len%0d", lens[i] + 1), 1, REGION_A + addr_t'(i * 4096), 4096, 2);
      s.min_len = lens[i];
      s.max_len = lens[i];
      s.start(env.mst.sqr);
    end
    s = mk_seq("shaped_wr", 1, REGION_B, 8192, 80);
    s.any_burst = 1'b1;
    s.any_size  = 1'b1;
    s.sparse    = 1'b1;
    s.start(env.mst.sqr);
    idle();
    sweep(REGION_A, 7 * 4096);
    sweep(REGION_B, 8192);
    s = mk_seq("shaped_rd", 0, REGION_B, 8192, 80);
    s.any_burst = 1'b1;
    s.any_size  = 1'b1;
    s.start(env.mst.sqr);
    s = mk_seq("incr_len256_rd", 0, REGION_A + 6 * 4096, 4096, 2);
    s.min_len = 255;
    s.max_len = 255;
    s.start(env.mst.sqr);
  endtask
endclass

// Ordering: W before AW, AW before W, both together; many IDs in flight;
// reads and writes at the same time (different regions).
class order_test extends axi_base_test;
  `uvm_component_utils(order_test)
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  task run_traffic();
    axi_rand_seq s, s1, s2;
    s = mk_seq("w_first", 1, REGION_A, 4096, 8);          s.aw_lead = -20; s.start(env.mst.sqr);
    s = mk_seq("aw_first", 1, REGION_A + 4096, 4096, 8);  s.aw_lead = 20;  s.start(env.mst.sqr);
    s = mk_seq("together", 1, REGION_A + 8192, 4096, 8);  s.start(env.mst.sqr);
    s = mk_seq("many_ids", 1, REGION_B, 8192, 40);        s.start(env.mst.sqr);
    idle();
    s1 = mk_seq("rd_a", 0, REGION_A, 3 * 4096, 40);
    s2 = mk_seq("wr_c", 1, REGION_C, 8192, 40);
    fork
      s1.start(env.mst.sqr);
      s2.start(env.mst.sqr);
    join
    idle();
    sweep(REGION_A, 3 * 4096);
    sweep(REGION_B, 8192);
    sweep(REGION_C, 8192);
  endtask
endclass

// Random back-pressure on every channel on both sides, random valid gaps,
// random burst shapes; reads and writes at the same time.
class backpressure_test extends axi_base_test;
  `uvm_component_utils(backpressure_test)
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void set_knobs();
    cfg.slv_aw_ready_pct = 50;
    cfg.slv_w_ready_pct  = 50;
    cfg.slv_ar_ready_pct = 50;
    cfg.slv_b_delay_max  = 4;
    cfg.slv_r_gap_max    = 3;
    cfg.mst_b_ready_pct  = 50;
    cfg.mst_r_ready_pct  = 50;
  endfunction

  task run_traffic();
    axi_rand_seq s, s1, s2;
    s = mk_seq("wr_a", 1, REGION_A, 16384, 100);
    s.any_burst = 1'b1; s.any_size = 1'b1; s.sparse = 1'b1; s.delay_max = 4;
    s.start(env.mst.sqr);
    idle();
    s1 = mk_seq("rd_a", 0, REGION_A, 16384, 100);
    s1.any_burst = 1'b1; s1.any_size = 1'b1; s1.delay_max = 4;
    s2 = mk_seq("wr_b", 1, REGION_B, 16384, 100);
    s2.any_burst = 1'b1; s2.any_size = 1'b1; s2.sparse = 1'b1; s2.delay_max = 4;
    fork
      s1.start(env.mst.sqr);
      s2.start(env.mst.sqr);
    join
    idle();
    sweep(REGION_A, 16384);
    sweep(REGION_B, 16384);
  endtask
endclass

// Fill every DUT FIFO on purpose, then let it drain:
//   1. the slave stops taking requests -> AW, W and AR FIFOs fill up
//   2. the master stops taking responses -> B and R FIFOs fill up
// The test also checks that the FIFOs really were full (stall counters),
// so a pass cannot come from traffic that never reached the full state.
class fifo_full_test extends axi_base_test;
  `uvm_component_utils(fifo_full_test)
  int unsigned n_fill;
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void set_knobs();
    n_fill = (1 << log_depth) + 8;  // more than any FIFO can hold
    cfg.max_outstanding = n_fill + 4;
  endfunction

  task run_traffic();
    axi_rand_seq s1, s2;
    `uvm_info("FILL", $sformatf("LOG_DEPTH %0d: %0d transactions per fill phase", log_depth, n_fill), UVM_LOW)
    // ---- 1. request FIFOs
    cfg.slv_req_hold = 1'b1;
    s1 = mk_seq("wr_a", 1, REGION_A, 8192, n_fill); s1.min_len = 3; s1.max_len = 3;
    s2 = mk_seq("rd_c", 0, REGION_C, 8192, n_fill); s2.min_len = 3; s2.max_len = 3;
    fork
      s1.start(env.mst.sqr);
      s2.start(env.mst.sqr);
    join
    #(400 * slow_period);  // 400 cycles of the slower clock
    `uvm_info("FILL", $sformatf("phase 1 (slave held) source stalls so far: AW %0d, W %0d, AR %0d",
                                env.mst.mon.stall_aw, env.mst.mon.stall_w, env.mst.mon.stall_ar), UVM_LOW)
    cfg.slv_req_hold = 1'b0;
    idle();
    // ---- 2. response FIFOs
    cfg.mst_rsp_hold = 1'b1;
    s1 = mk_seq("wr_b", 1, REGION_B, 8192, n_fill); s1.min_len = 3; s1.max_len = 3;
    s2 = mk_seq("rd_a", 0, REGION_A, 8192, n_fill); s2.min_len = 3; s2.max_len = 3;
    fork
      s1.start(env.mst.sqr);
      s2.start(env.mst.sqr);
    join
    #(400 * slow_period);
    `uvm_info("FILL", $sformatf("phase 2 (master held) destination stalls so far: B %0d, R %0d",
                                env.slv_mon.stall_b, env.slv_mon.stall_r), UVM_LOW)
    cfg.mst_rsp_hold = 1'b0;
    idle();
    sweep(REGION_A, 8192);
    sweep(REGION_B, 8192);
  endtask

  function void check_phase(uvm_phase phase);
    super.check_phase(phase);
    if (env.mst.mon.stall_aw == 0) `uvm_error("SCENARIO", "AW FIFO was never full (no source AW stall)")
    if (env.mst.mon.stall_w  == 0) `uvm_error("SCENARIO", "W FIFO was never full (no source W stall)")
    if (env.mst.mon.stall_ar == 0) `uvm_error("SCENARIO", "AR FIFO was never full (no source AR stall)")
    if (env.slv_mon.stall_b  == 0) `uvm_error("SCENARIO", "B FIFO was never full (no destination B stall)")
    if (env.slv_mon.stall_r  == 0) `uvm_error("SCENARIO", "R FIFO was never full (no destination R stall)")
  endfunction
endclass

// Constrained-random test. Everything comes from the seed (-svseed): the
// cfg knobs, the number and shape of transactions, and random "hold"
// pulses that stall the slave or the master for a while, so the DUT FIFOs
// fill up and drain many times. Use it with +RAND_CLOCKS for random clocks.
class rand_test extends axi_base_test;
  `uvm_component_utils(rand_test)
  bit seqs_done;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void set_knobs();
    cfg.max_outstanding  = $urandom_range(16, 1);
    cfg.slv_aw_ready_pct = $urandom_range(100, 20);
    cfg.slv_w_ready_pct  = $urandom_range(100, 20);
    cfg.slv_ar_ready_pct = $urandom_range(100, 20);
    cfg.mst_b_ready_pct  = $urandom_range(100, 20);
    cfg.mst_r_ready_pct  = $urandom_range(100, 20);
    cfg.slv_b_delay_max  = $urandom_range(6);
    cfg.slv_r_gap_max    = $urandom_range(4);
    `uvm_info("RAND", $sformatf("knobs: outstanding %0d, slave ready AW/W/AR %0d/%0d/%0d %%, master ready B/R %0d/%0d %%, B delay <= %0d, R gap <= %0d",
                                cfg.max_outstanding, cfg.slv_aw_ready_pct, cfg.slv_w_ready_pct, cfg.slv_ar_ready_pct,
                                cfg.mst_b_ready_pct, cfg.mst_r_ready_pct, cfg.slv_b_delay_max, cfg.slv_r_gap_max), UVM_LOW)
  endfunction

  virtual function axi_rand_seq shaped(string name, int kind_sel, addr_t base, int unsigned n);
    axi_rand_seq s = mk_seq(name, kind_sel, base, 16384, n);
    s.any_burst = 1'b1;
    s.any_size  = 1'b1;
    s.sparse    = (kind_sel == 1);
    s.delay_max = $urandom_range(6);
    return s;
  endfunction

  task run_traffic();
    axi_rand_seq s, s1, s2;
    int unsigned n1 = n_txn();
    int unsigned n2 = n_txn();
    int unsigned n3 = n_txn();
    `uvm_info("RAND", $sformatf("traffic: %0d writes to A; then %0d reads of A with %0d writes to B", n1, n2, n3), UVM_LOW)
    s = shaped("wr_a", 1, REGION_A, n1);
    s.start(env.mst.sqr);
    idle();
    s1 = shaped("rd_a", 0, REGION_A, n2);
    s2 = shaped("wr_b", 1, REGION_B, n3);
    seqs_done = 1'b0;
    fork
      begin
        fork
          s1.start(env.mst.sqr);
          s2.start(env.mst.sqr);
        join
        seqs_done = 1'b1;
      end
      hold_pulses();
    join
    idle();
    sweep(REGION_A, 16384);
    sweep(REGION_B, 16384);
  endtask

  function bit busy();
    return !seqs_done || (env.mst.drv.wr_out + env.mst.drv.rd_out > 0);
  endfunction

  // Random sizes, in slower-clock cycles / transactions. Derived tests
  // change them (the call order, and so the seed mapping, stays the same).
  virtual function int unsigned n_txn();    return $urandom_range(150, 50); endfunction
  virtual function int unsigned hold_gap(); return $urandom_range(400, 50); endfunction
  virtual function int unsigned hold_len(); return $urandom_range(200, 10); endfunction

  // While traffic runs: now and then hold the slave (requests) or the
  // master (responses) for 10-200 cycles of the slower clock.
  task hold_pulses();
    int unsigned n = 0;
    while (busy()) begin
      #(hold_gap() * slow_period);
      if (!busy()) break;
      if ($urandom_range(1)) cfg.slv_req_hold = 1'b1;
      else                   cfg.mst_rsp_hold = 1'b1;
      #(hold_len() * slow_period);
      cfg.slv_req_hold = 1'b0;
      cfg.mst_rsp_hold = 1'b0;
      n++;
    end
    `uvm_info("RAND", $sformatf("%0d hold pulses", n), UVM_LOW)
  endtask
endclass

// rand_test after coverage closure (Stage 7). Stage 6 and the first Stage 7
// coverage run showed what rand_test can never reach:
//   - with LOG_DEPTH >= 4 the AW, AR and B FIFOs were never full: at most 16
//     transactions were in flight, but those FIFOs hold 2**LOG_DEPTH + 1
//     (axi_cdc_ram) or + 2 (axi_cdc) entries
//   - no INCR burst was longer than 16 beats
// Changes: half of the seeds allow more transactions in flight than the
// biggest FIFO holds; half of the sequences allow long INCR bursts (up to
// 256 beats, still mostly short ones). Use with +RAND_CLOCKS +CLK_CORNERS
// so that some seeds also get clocks with coincident edges.
class rand_cov_test extends rand_test;
  `uvm_component_utils(rand_cov_test)
  bit deep;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void set_knobs();
    int unsigned cap = (1 << log_depth) + 2;  // the biggest DUT FIFO (axi_cdc)
    super.set_knobs();
    deep = $urandom_range(1);
    if (deep) cfg.max_outstanding = $urandom_range(cap + 6, cap + 1);
    `uvm_info("RAND", $sformatf("closure knobs: deep %0d -> outstanding %0d (biggest FIFO %0d entries)",
                                deep, cfg.max_outstanding, cap), UVM_LOW)
  endfunction

  function axi_rand_seq shaped(string name, int kind_sel, addr_t base, int unsigned n);
    axi_rand_seq s = super.shaped(name, kind_sel, base, n);
    s.long_ok = $urandom_range(1);
    if (s.long_ok) s.max_len = 255;
    return s;
  endfunction
endclass

// Targeted random for deep FIFOs (Stage 8, closure round 2). Stage 7 showed
// that with LOG_DEPTH 4 and 6 random traffic almost never fills the AW, AR
// and B FIFOs, even with more transactions in flight than a FIFO holds: a
// FIFO only fills if those transactions all arrive while the other side is
// held, and a hold of 10-200 cycles with up to 256-beat bursts is too short.
// Here, for every seed: more in flight than the biggest FIFO (2**d + 2),
// short bursts (1-4 beats), 2-4x a FIFO's worth of transactions per phase,
// and holds of 2-8x the FIFO size. Clocks still come from the seed.
class rand_deep_test extends rand_cov_test;
  `uvm_component_utils(rand_deep_test)
  int unsigned cap;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void set_knobs();
    super.set_knobs();
    cap = (1 << log_depth) + 2;
    cfg.max_outstanding = cap + $urandom_range(6, 2);
    `uvm_info("RAND", $sformatf("deep knobs: outstanding %0d (biggest FIFO %0d entries), holds %0d-%0d cycles",
                                cfg.max_outstanding, cap, 2 * cap, 8 * cap), UVM_LOW)
  endfunction

  function axi_rand_seq shaped(string name, int kind_sel, addr_t base, int unsigned n);
    axi_rand_seq s = super.shaped(name, kind_sel, base, n);
    s.long_ok = 1'b0;
    s.max_len = 3;
    return s;
  endfunction

  function int unsigned n_txn();    return $urandom_range(4 * cap, 2 * cap); endfunction
  function int unsigned hold_gap(); return $urandom_range(200, 20);          endfunction
  function int unsigned hold_len(); return $urandom_range(8 * cap, 2 * cap); endfunction
endclass
