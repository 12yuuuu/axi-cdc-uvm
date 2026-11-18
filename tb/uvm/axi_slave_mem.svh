// Copyright 2026 Kuan-Yu Liu
// SPDX-License-Identifier: Apache-2.0
//
// Reactive AXI slave on the destination (downstream) side: a sparse,
// byte-addressed memory. Pipelined and cycle based like the master driver:
// one process per channel. READY on AW/W/AR and the B/R timing follow the
// cfg knobs, so tests can add back-pressure or stall the slave completely.
// Writes are applied when an AW and its whole W burst have both arrived
// (W may arrive first).
//
// Responses: in order by default. With the cfg knobs, B responses of
// different IDs may come back out of order, and the beats of up to
// slv_r_active read bursts with different IDs may be interleaved (AXI
// A5.3: only responses with the same ID must stay in order). With err_en,
// bursts in the error pages get SLVERR / DECERR (cfg.resp_for): their
// writes are dropped and their reads return data 0.
//
// +INJECT_SLV_WRAP_BUG (negative test): the slave forgets to wrap WRAP
// bursts. The bus traffic stays legal and both monitors agree, so only the
// end-to-end data check (with its own address math) can see it.
class axi_slave_mem extends uvm_component;
  `uvm_component_utils(axi_slave_mem)

  virtual axi_vif vif;
  axi_tb_cfg      cfg;
  bit [7:0]       mem [addr_t];  // only written bytes exist

  axi_seq_item aw_fifo[$];  // AW accepted, waiting for its W burst
  axi_seq_item wb_fifo[$];  // W bursts accepted, waiting for their AW
  axi_seq_item b_fifo[$];   // writes applied, B to send
  axi_seq_item ar_fifo[$];  // AR accepted, R beats to send
  data_t       w_data[$];   // W burst being received
  strb_t       w_strb[$];
  bit          inj_wrap_bug;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db #(virtual axi_vif)::get(this, "", "vif", vif))
      `uvm_fatal("NOVIF", "no virtual interface for the slave memory")
    if (!uvm_config_db #(axi_tb_cfg)::get(this, "", "cfg", cfg))
      cfg = axi_tb_cfg::type_id::create("cfg");
    inj_wrap_bug = $test$plusargs("INJECT_SLV_WRAP_BUG");
  endfunction

  // Address of beat i as the slave computes it.
  function addr_t beat_addr(axi_seq_item t, int unsigned i);
    if (inj_wrap_bug && t.burst == axi_pkg::BURST_WRAP)  // injected bug: no wrap
      return (t.addr & ~addr_t'((1 << t.size) - 1)) + addr_t'(i << t.size);
    return axi_seq_item::calc_beat_addr(t.addr, t.size, t.len, t.burst, i);
  endfunction

  // Index of the response to send next: 0 (in order), or with the OOO knob
  // a random entry that has no older entry with the same ID.
  function int unsigned pick(axi_seq_item q[$], int unsigned pct);
    int unsigned ok[$];
    if (q.size() < 2 || pct == 0 || !axi_tb_cfg::chance(pct)) return 0;
    foreach (q[i]) begin
      bit older_same_id = 1'b0;
      for (int unsigned j = 0; j < i; j++) if (q[j].id == q[i].id) older_same_id = 1'b1;
      if (!older_same_id) ok.push_back(i);
    end
    return ok[$urandom_range(ok.size() - 1)];
  endfunction

  task run_phase(uvm_phase phase);
    idle();
    wait (vif.rst_n === 1'b1);
    @(vif.slv_cb);
    fork
      aw_loop();
      w_loop();
      b_loop();
      ar_loop();
      r_loop();
    join
  endtask

  function void idle();
    vif.aw_ready = 1'b0;
    vif.w_ready  = 1'b0;
    vif.b_valid  = 1'b0;
    vif.ar_ready = 1'b0;
    vif.r_valid  = 1'b0;
  endfunction

  // Store the bytes whose strobe is set. Byte lane b of the bus carries
  // address (bus-aligned address + b).
  function void write_beat(addr_t a, data_t d, strb_t s);
    addr_t base = a & ~addr_t'(SW - 1);
    for (int unsigned b = 0; b < SW; b++)
      if (s[b]) mem[base + addr_t'(b)] = d[8*b +: 8];
  endfunction

  // Return all byte lanes. Bytes never written read as 0.
  function data_t read_beat(addr_t a);
    addr_t base = a & ~addr_t'(SW - 1);
    data_t d    = '0;
    for (int unsigned b = 0; b < SW; b++)
      if (mem.exists(base + addr_t'(b))) d[8*b +: 8] = mem[base + addr_t'(b)];
    return d;
  endfunction

  // Apply every write that has both its AW and its W burst.
  function void pair_writes();
    axi_seq_item aw, wb;
    while (aw_fifo.size() > 0 && wb_fifo.size() > 0) begin
      aw = aw_fifo.pop_front();
      wb = wb_fifo.pop_front();
      if (wb.data.size() != aw.num_beats())
        `uvm_error("SLV_WLEN", $sformatf("W burst has %0d beats, AW len says %0d", wb.data.size(), aw.num_beats()))
      aw.resp    = new[1];
      aw.resp[0] = cfg.resp_for(aw.addr);
      if (aw.resp[0] == axi_pkg::RESP_OKAY)
        foreach (wb.data[i]) write_beat(beat_addr(aw, i), wb.data[i], wb.strb[i]);
      b_fifo.push_back(aw);
    end
  endfunction

  function axi_seq_item capture_ax(bit is_write);
    axi_seq_item t = axi_seq_item::type_id::create(is_write ? "slv_aw" : "slv_ar");
    t.kind  = is_write ? AXI_WRITE : AXI_READ;
    t.id    = is_write ? vif.slv_cb.aw_id    : vif.slv_cb.ar_id;
    t.addr  = is_write ? vif.slv_cb.aw_addr  : vif.slv_cb.ar_addr;
    t.len   = is_write ? vif.slv_cb.aw_len   : vif.slv_cb.ar_len;
    t.size  = is_write ? vif.slv_cb.aw_size  : vif.slv_cb.ar_size;
    t.burst = is_write ? vif.slv_cb.aw_burst : vif.slv_cb.ar_burst;
    return t;
  endfunction

  task aw_loop();
    bit ready_q = 1'b0;
    forever begin
      @(vif.slv_cb);
      if (ready_q && vif.slv_cb.aw_valid === 1'b1) begin
        aw_fifo.push_back(capture_ax(1'b1));
        pair_writes();
      end
      ready_q = !cfg.slv_req_hold && axi_tb_cfg::chance(cfg.slv_aw_ready_pct);
      vif.slv_cb.aw_ready <= ready_q;
    end
  endtask

  task w_loop();
    axi_seq_item wb;
    bit          ready_q = 1'b0;
    forever begin
      @(vif.slv_cb);
      if (ready_q && vif.slv_cb.w_valid === 1'b1) begin
        w_data.push_back(vif.slv_cb.w_data);
        w_strb.push_back(vif.slv_cb.w_strb);
        if (vif.slv_cb.w_last === 1'b1) begin
          wb = axi_seq_item::type_id::create("slv_wb");
          wb.data = w_data;
          wb.strb = w_strb;
          wb_fifo.push_back(wb);
          w_data.delete();
          w_strb.delete();
          pair_writes();
        end
      end
      ready_q = !cfg.slv_req_hold && axi_tb_cfg::chance(cfg.slv_w_ready_pct);
      vif.slv_cb.w_ready <= ready_q;
    end
  endtask

  task b_loop();
    axi_seq_item t;
    bit          loaded  = 1'b0;
    bit          valid_q = 1'b0;
    int unsigned wait_c  = 0;
    int unsigned gath_c  = 0;
    forever begin
      @(vif.slv_cb);
      if (valid_q && vif.slv_cb.b_ready === 1'b1) begin
        valid_q = 1'b0;
        loaded  = 1'b0;
      end
      // slv_b_gather = 0 (every test but rand_ooo_test): no extra wait and
      // no extra random draw, so those tests stay as they were.
      if (!loaded && b_fifo.size() == 1 && gath_c < cfg.slv_b_gather) gath_c++;
      else if (!loaded && b_fifo.size() > 0) begin
        int unsigned k = pick(b_fifo, cfg.slv_b_ooo_pct);
        t      = b_fifo[k];
        b_fifo.delete(k);
        wait_c = axi_tb_cfg::rand_upto(cfg.slv_b_delay_max);
        loaded = 1'b1;
        gath_c = 0;
      end
      if (loaded && !valid_q) begin
        if (wait_c > 0) wait_c--;
        else begin
          vif.slv_cb.b_id   <= t.id;
          vif.slv_cb.b_resp <= t.resp[0];
          vif.slv_cb.b_user <= user_t'(^t.id);  // some non-zero user bits to carry
          valid_q = 1'b1;
        end
      end
      vif.slv_cb.b_valid <= valid_q;
    end
  endtask

  task ar_loop();
    bit ready_q = 1'b0;
    forever begin
      @(vif.slv_cb);
      if (ready_q && vif.slv_cb.ar_valid === 1'b1)
        ar_fifo.push_back(capture_ax(1'b0));
      ready_q = !cfg.slv_req_hold && axi_tb_cfg::chance(cfg.slv_ar_ready_pct);
      vif.slv_cb.ar_ready <= ready_q;
    end
  endtask

  // R channel. act holds the read bursts being returned (at most
  // cfg.slv_r_active); cur is the one whose beat is on the bus. With one
  // active burst this is a plain in-order R channel.
  task r_loop();
    axi_seq_item t;
    axi_seq_item act[$];
    int unsigned beat_of[$];
    int unsigned cur     = 0;
    bit          valid_q = 1'b0;
    int unsigned wait_c  = 0;
    data_t       rd;
    axi_pkg::resp_t rr;
    forever begin
      @(vif.slv_cb);
      if (valid_q && vif.slv_cb.r_ready === 1'b1) begin
        valid_q = 1'b0;
        if (beat_of[cur] == act[cur].len) begin
          act.delete(cur);
          beat_of.delete(cur);
          cur = 0;
        end else begin
          beat_of[cur]++;
          wait_c = axi_tb_cfg::rand_upto(cfg.slv_r_gap_max);
          if (act.size() > 1) cur = switch_burst(act, cur);
        end
      end
      while (ar_fifo.size() > 0 && act.size() < ((cfg.slv_r_active > 0) ? cfg.slv_r_active : 1)) begin
        if (act.size() == 0) wait_c = axi_tb_cfg::rand_upto(cfg.slv_r_gap_max);
        act.push_back(ar_fifo.pop_front());
        beat_of.push_back(0);
      end
      if (act.size() > 0 && !valid_q) begin
        if (wait_c > 0) wait_c--;
        else begin
          t  = act[cur];
          rr = cfg.resp_for(t.addr);
          rd = (rr == axi_pkg::RESP_OKAY) ? read_beat(beat_addr(t, beat_of[cur])) : '0;
          vif.slv_cb.r_id   <= t.id;
          vif.slv_cb.r_data <= rd;
          vif.slv_cb.r_resp <= rr;
          vif.slv_cb.r_last <= (beat_of[cur] == t.len);
          vif.slv_cb.r_user <= user_t'(^rd);    // some non-zero user bits to carry
          valid_q = 1'b1;
        end
      end
      vif.slv_cb.r_valid <= valid_q;
    end
  endtask

  // After a beat: maybe continue with another active burst. Only the oldest
  // active burst of each ID may send (same-ID reads stay in order).
  function int unsigned switch_burst(axi_seq_item act[$], int unsigned cur);
    int unsigned ok[$];
    if (cfg.slv_r_ilv_pct == 0 || !axi_tb_cfg::chance(cfg.slv_r_ilv_pct)) return cur;
    foreach (act[i]) begin
      bit older_same_id = 1'b0;
      for (int unsigned j = 0; j < i; j++) if (act[j].id == act[i].id) older_same_id = 1'b1;
      if (!older_same_id) ok.push_back(i);
    end
    return ok[$urandom_range(ok.size() - 1)];
  endfunction
endclass
