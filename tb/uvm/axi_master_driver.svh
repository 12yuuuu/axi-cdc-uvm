// Copyright 2026 Kuan-Yu Liu
// SPDX-License-Identifier: Apache-2.0
//
// AXI master driver on the source (upstream) side of the DUT.
//
// Pipelined: the five channels run as five independent processes, so many
// transactions can be in flight (up to cfg.max_outstanding writes and reads).
// Every process is cycle based: at each clock edge it
//   1. checks whether the handshake of the last cycle happened,
//   2. decides what to drive in the next cycle,
//   3. drives it through the clocking block.
// Once VALID is high it stays high, with stable payload, until READY
// (AXI rule A3.2.1). Items carry their own timing knobs (aw_delay, w_delay,
// w_gap, ar_delay); B/R ready follow the cfg knobs.
//
// item_done() is called as soon as an item is queued, so a sequence can
// issue many transactions back to back. The monitors and the scoreboard do
// the checking; tests call wait_idle() before ending.
class axi_master_driver extends uvm_driver #(axi_seq_item);
  `uvm_component_utils(axi_master_driver)

  virtual axi_vif vif;
  axi_tb_cfg      cfg;

  axi_seq_item aw_q[$];          // waiting for AW
  axi_seq_item w_q[$];           // waiting for W (same order as AW, AXI4 rule)
  axi_seq_item ar_q[$];          // waiting for AR
  int unsigned wr_out, rd_out;   // queued but response not seen yet
  bit          inj_aw_unstable;  // +INJECT_AW_UNSTABLE (negative test, see aw_loop)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db #(virtual axi_vif)::get(this, "", "vif", vif))
      `uvm_fatal("NOVIF", "no virtual interface for the master driver")
    if (!uvm_config_db #(axi_tb_cfg)::get(this, "", "cfg", cfg))
      cfg = axi_tb_cfg::type_id::create("cfg");
    inj_aw_unstable = $test$plusargs("INJECT_AW_UNSTABLE");
  endfunction

  task run_phase(uvm_phase phase);
    idle();
    wait (vif.rst_n === 1'b1);
    @(vif.mst_cb);
    fork
      fetch();
      aw_loop();
      w_loop();
      b_loop();
      ar_loop();
      r_loop();
    join
  endtask

  // Blocks until every queued transaction has its response.
  task wait_idle();
    wait (wr_out == 0 && rd_out == 0);
  endtask

  // All valid/ready low. Assigned directly (not through the clocking block)
  // because they must be low from time 0, before the first clock edge.
  function void idle();
    vif.aw_valid = 1'b0;
    vif.w_valid  = 1'b0;
    vif.b_ready  = 1'b0;
    vif.ar_valid = 1'b0;
    vif.r_ready  = 1'b0;
  endfunction

  task fetch();
    forever begin
      seq_item_port.get_next_item(req);
      if (req.kind == AXI_WRITE) begin
        wait (wr_out < cfg.max_outstanding);
        wr_out++;
        aw_q.push_back(req);
        w_q.push_back(req);
      end else begin
        wait (rd_out < cfg.max_outstanding);
        rd_out++;
        ar_q.push_back(req);
      end
      seq_item_port.item_done();
    end
  endtask

  task aw_loop();
    axi_seq_item t;
    bit          loaded  = 1'b0;
    bit          valid_q = 1'b0;
    int unsigned wait_c  = 0;
    forever begin
      @(vif.mst_cb);
      if (valid_q && vif.mst_cb.aw_ready === 1'b1) begin
        valid_q = 1'b0;
        loaded  = 1'b0;
      end
      // Negative test for the assertions: the first time AW has to wait
      // for READY, change its address while VALID stays high. This breaks
      // AXI A3.2.1, but the DUT and both monitors all see the new address,
      // so the scoreboard stays happy; only the SVA can catch it.
      if (inj_aw_unstable && valid_q && vif.mst_cb.aw_ready !== 1'b1) begin
        vif.mst_cb.aw_addr <= t.addr ^ addr_t'('h40);
        inj_aw_unstable = 1'b0;
        `uvm_info("INJECT", $sformatf("AW address %h changed to %h while VALID=1, READY=0", t.addr, t.addr ^ addr_t'('h40)), UVM_NONE)
      end
      if (!loaded && aw_q.size() > 0) begin
        t      = aw_q.pop_front();
        wait_c = t.aw_delay;
        loaded = 1'b1;
      end
      if (loaded && !valid_q) begin
        if (wait_c > 0) wait_c--;
        else begin
          vif.mst_cb.aw_id     <= t.id;
          vif.mst_cb.aw_addr   <= t.addr;
          vif.mst_cb.aw_len    <= t.len;
          vif.mst_cb.aw_size   <= t.size;
          vif.mst_cb.aw_burst  <= t.burst;
          vif.mst_cb.aw_lock   <= t.lock;
          vif.mst_cb.aw_cache  <= t.cache;
          vif.mst_cb.aw_prot   <= t.prot;
          vif.mst_cb.aw_qos    <= t.qos;
          vif.mst_cb.aw_region <= t.region;
          vif.mst_cb.aw_atop   <= t.atop;
          vif.mst_cb.aw_user   <= t.user;
          valid_q = 1'b1;
        end
      end
      vif.mst_cb.aw_valid <= valid_q;
    end
  endtask

  task w_loop();
    axi_seq_item t;
    bit          loaded  = 1'b0;
    bit          valid_q = 1'b0;
    int unsigned beat    = 0;
    int unsigned wait_c  = 0;
    forever begin
      @(vif.mst_cb);
      if (valid_q && vif.mst_cb.w_ready === 1'b1) begin
        valid_q = 1'b0;
        if (beat == t.len) loaded = 1'b0;       // burst done
        else begin
          beat++;
          wait_c = axi_tb_cfg::rand_upto(t.w_gap);
        end
      end
      if (!loaded && w_q.size() > 0) begin
        t      = w_q.pop_front();
        beat   = 0;
        wait_c = t.w_delay;
        loaded = 1'b1;
      end
      if (loaded && !valid_q) begin
        if (wait_c > 0) wait_c--;
        else begin
          vif.mst_cb.w_data <= t.data[beat];
          vif.mst_cb.w_strb <= t.strb[beat];
          vif.mst_cb.w_user <= t.wuser[beat];
          vif.mst_cb.w_last <= (beat == t.len);
          valid_q = 1'b1;
        end
      end
      vif.mst_cb.w_valid <= valid_q;
    end
  endtask

  task b_loop();
    bit ready_q = 1'b0;
    forever begin
      @(vif.mst_cb);
      if (ready_q && vif.mst_cb.b_valid === 1'b1) begin
        if (wr_out == 0) `uvm_error("DRV", "B response with no write outstanding")
        else wr_out--;
      end
      ready_q = !cfg.mst_rsp_hold && axi_tb_cfg::chance(cfg.mst_b_ready_pct);
      vif.mst_cb.b_ready <= ready_q;
    end
  endtask

  task ar_loop();
    axi_seq_item t;
    bit          loaded  = 1'b0;
    bit          valid_q = 1'b0;
    int unsigned wait_c  = 0;
    forever begin
      @(vif.mst_cb);
      if (valid_q && vif.mst_cb.ar_ready === 1'b1) begin
        valid_q = 1'b0;
        loaded  = 1'b0;
      end
      if (!loaded && ar_q.size() > 0) begin
        t      = ar_q.pop_front();
        wait_c = t.ar_delay;
        loaded = 1'b1;
      end
      if (loaded && !valid_q) begin
        if (wait_c > 0) wait_c--;
        else begin
          vif.mst_cb.ar_id     <= t.id;
          vif.mst_cb.ar_addr   <= t.addr;
          vif.mst_cb.ar_len    <= t.len;
          vif.mst_cb.ar_size   <= t.size;
          vif.mst_cb.ar_burst  <= t.burst;
          vif.mst_cb.ar_lock   <= t.lock;
          vif.mst_cb.ar_cache  <= t.cache;
          vif.mst_cb.ar_prot   <= t.prot;
          vif.mst_cb.ar_qos    <= t.qos;
          vif.mst_cb.ar_region <= t.region;
          vif.mst_cb.ar_user   <= t.user;
          valid_q = 1'b1;
        end
      end
      vif.mst_cb.ar_valid <= valid_q;
    end
  endtask

  task r_loop();
    bit ready_q = 1'b0;
    forever begin
      @(vif.mst_cb);
      if (ready_q && vif.mst_cb.r_valid === 1'b1 && vif.mst_cb.r_last === 1'b1) begin
        if (rd_out == 0) `uvm_error("DRV", "last R beat with no read outstanding")
        else rd_out--;
      end
      ready_q = !cfg.mst_rsp_hold && axi_tb_cfg::chance(cfg.mst_r_ready_pct);
      vif.mst_cb.r_ready <= ready_q;
    end
  endtask
endclass
