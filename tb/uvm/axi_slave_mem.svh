// Copyright 2026 Kuan-Yu Liu
// SPDX-License-Identifier: Apache-2.0
//
// Reactive AXI slave on the destination (downstream) side: a sparse,
// byte-addressed memory. Pipelined and cycle based like the master driver:
// one process per channel. READY on AW/W/AR and the B/R timing follow the
// cfg knobs, so tests can add back-pressure or stall the slave completely.
// Writes are applied when an AW and its whole W burst have both arrived
// (W may arrive first). Responses come back in order.
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

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db #(virtual axi_vif)::get(this, "", "vif", vif))
      `uvm_fatal("NOVIF", "no virtual interface for the slave memory")
    if (!uvm_config_db #(axi_tb_cfg)::get(this, "", "cfg", cfg))
      cfg = axi_tb_cfg::type_id::create("cfg");
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
      foreach (wb.data[i])
        write_beat(axi_seq_item::calc_beat_addr(aw.addr, aw.size, aw.len, aw.burst, i),
                   wb.data[i], wb.strb[i]);
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
    forever begin
      @(vif.slv_cb);
      if (valid_q && vif.slv_cb.b_ready === 1'b1) begin
        valid_q = 1'b0;
        loaded  = 1'b0;
      end
      if (!loaded && b_fifo.size() > 0) begin
        t      = b_fifo.pop_front();
        wait_c = axi_tb_cfg::rand_upto(cfg.slv_b_delay_max);
        loaded = 1'b1;
      end
      if (loaded && !valid_q) begin
        if (wait_c > 0) wait_c--;
        else begin
          vif.slv_cb.b_id   <= t.id;
          vif.slv_cb.b_resp <= axi_pkg::RESP_OKAY;
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

  task r_loop();
    axi_seq_item t;
    data_t       rd;
    bit          loaded  = 1'b0;
    bit          valid_q = 1'b0;
    int unsigned beat    = 0;
    int unsigned wait_c  = 0;
    forever begin
      @(vif.slv_cb);
      if (valid_q && vif.slv_cb.r_ready === 1'b1) begin
        valid_q = 1'b0;
        if (beat == t.len) loaded = 1'b0;
        else begin
          beat++;
          wait_c = axi_tb_cfg::rand_upto(cfg.slv_r_gap_max);
        end
      end
      if (!loaded && ar_fifo.size() > 0) begin
        t      = ar_fifo.pop_front();
        beat   = 0;
        wait_c = axi_tb_cfg::rand_upto(cfg.slv_r_gap_max);
        loaded = 1'b1;
      end
      if (loaded && !valid_q) begin
        if (wait_c > 0) wait_c--;
        else begin
          rd = read_beat(axi_seq_item::calc_beat_addr(t.addr, t.size, t.len, t.burst, beat));
          vif.slv_cb.r_id   <= t.id;
          vif.slv_cb.r_data <= rd;
          vif.slv_cb.r_resp <= axi_pkg::RESP_OKAY;
          vif.slv_cb.r_last <= (beat == t.len);
          vif.slv_cb.r_user <= user_t'(^rd);    // some non-zero user bits to carry
          valid_q = 1'b1;
        end
      end
      vif.slv_cb.r_valid <= valid_q;
    end
  endtask
endclass
