// Copyright 2026 Kuan-Yu Liu
// SPDX-License-Identifier: Apache-2.0
//
// Passive monitor for one side of the DUT. It watches the five channels,
// rebuilds whole transactions from the handshakes, and sends every finished
// one to `ap`:
//   write = AW + its W beats + B      (W beats pair with AWs in order)
//   read  = AR + its R beats          (R beats pair with the oldest AR of that ID)
class axi_monitor extends uvm_monitor;
  `uvm_component_utils(axi_monitor)

  virtual axi_vif                   vif;
  uvm_analysis_port #(axi_seq_item) ap;

  // transactions in flight
  axi_seq_item aw_q[$];        // AW seen, W burst not finished yet
  axi_seq_item wb_q[$];        // finished W bursts with no AW yet (W may come first)
  axi_seq_item wait_b[$];      // AW + all W seen, waiting for B
  axi_seq_item ar_q[$];        // AR seen, no R beat yet
  axi_seq_item r_cur[id_t];    // read receiving R beats, per ID
  data_t       w_data[$];      // beats of the W burst being received
  strb_t       w_strb[$];
  user_t       w_user[$];

  int unsigned n_wr, n_rd;     // finished transactions
  // Stall cycles: VALID high but READY low. On the source side, AW/W/AR
  // stalls can only come from a full DUT FIFO; on the destination side,
  // B/R stalls can only come from a full DUT FIFO.
  int unsigned stall_aw, stall_w, stall_b, stall_ar, stall_r;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    ap = new("ap", this);
    if (!uvm_config_db #(virtual axi_vif)::get(this, "", "vif", vif))
      `uvm_fatal("NOVIF", "no virtual interface for the monitor")
  endfunction

  task run_phase(uvm_phase phase);
    wait (vif.rst_n === 1'b1);
    forever begin
      @(vif.mon_cb);
      if (vif.rst_n !== 1'b1) continue;
      sample_aw();
      sample_w();
      pair_aw_w();
      sample_b();
      sample_ar();
      sample_r();
      count_stalls();
    end
  endtask

  function void count_stalls();
    if (vif.mon_cb.aw_valid === 1'b1 && vif.mon_cb.aw_ready !== 1'b1) stall_aw++;
    if (vif.mon_cb.w_valid  === 1'b1 && vif.mon_cb.w_ready  !== 1'b1) stall_w++;
    if (vif.mon_cb.b_valid  === 1'b1 && vif.mon_cb.b_ready  !== 1'b1) stall_b++;
    if (vif.mon_cb.ar_valid === 1'b1 && vif.mon_cb.ar_ready !== 1'b1) stall_ar++;
    if (vif.mon_cb.r_valid  === 1'b1 && vif.mon_cb.r_ready  !== 1'b1) stall_r++;
  endfunction

  function void sample_aw();
    axi_seq_item t;
    if (vif.mon_cb.aw_valid !== 1'b1 || vif.mon_cb.aw_ready !== 1'b1) return;
    t = axi_seq_item::type_id::create("mon_wr");
    t.kind   = AXI_WRITE;
    t.id     = vif.mon_cb.aw_id;
    t.addr   = vif.mon_cb.aw_addr;
    t.len    = vif.mon_cb.aw_len;
    t.size   = vif.mon_cb.aw_size;
    t.burst  = vif.mon_cb.aw_burst;
    t.lock   = vif.mon_cb.aw_lock;
    t.cache  = vif.mon_cb.aw_cache;
    t.prot   = vif.mon_cb.aw_prot;
    t.qos    = vif.mon_cb.aw_qos;
    t.region = vif.mon_cb.aw_region;
    t.atop   = vif.mon_cb.aw_atop;
    t.user   = vif.mon_cb.aw_user;
    t.start_t = $realtime;
    aw_q.push_back(t);
  endfunction

  function void sample_w();
    axi_seq_item wb;
    if (vif.mon_cb.w_valid !== 1'b1 || vif.mon_cb.w_ready !== 1'b1) return;
    w_data.push_back(vif.mon_cb.w_data);
    w_strb.push_back(vif.mon_cb.w_strb);
    w_user.push_back(vif.mon_cb.w_user);
    if (vif.mon_cb.w_last === 1'b1) begin
      wb = axi_seq_item::type_id::create("mon_wb");
      wb.data  = w_data;
      wb.strb  = w_strb;
      wb.wuser = w_user;
      wb_q.push_back(wb);
      w_data.delete(); w_strb.delete(); w_user.delete();
    end
  endfunction

  function void pair_aw_w();
    axi_seq_item t, wb;
    while (aw_q.size() > 0 && wb_q.size() > 0) begin
      t  = aw_q.pop_front();
      wb = wb_q.pop_front();
      t.data  = wb.data;
      t.strb  = wb.strb;
      t.wuser = wb.wuser;
      if (t.data.size() != t.num_beats())
        `uvm_error("WLEN", $sformatf("W burst has %0d beats, AW len says %0d: %s",
                                     t.data.size(), t.num_beats(), t.convert2string()))
      wait_b.push_back(t);
    end
  endfunction

  function void sample_b();
    axi_seq_item t;
    int          idx[$];
    if (vif.mon_cb.b_valid !== 1'b1 || vif.mon_cb.b_ready !== 1'b1) return;
    idx = wait_b.find_first_index(x) with (x.id == vif.mon_cb.b_id);
    if (idx.size() == 0) begin
      `uvm_error("BNOAW", $sformatf("B with id %0h, but no finished write with that id", vif.mon_cb.b_id))
      return;
    end
    t = wait_b[idx[0]];
    wait_b.delete(idx[0]);
    t.rsp_id  = vif.mon_cb.b_id;
    t.resp    = new[1];
    t.resp[0] = vif.mon_cb.b_resp;
    t.buser   = vif.mon_cb.b_user;
    t.end_t   = $realtime;
    n_wr++;
    ap.write(t);
  endfunction

  function void sample_ar();
    axi_seq_item t;
    if (vif.mon_cb.ar_valid !== 1'b1 || vif.mon_cb.ar_ready !== 1'b1) return;
    t = axi_seq_item::type_id::create("mon_rd");
    t.kind   = AXI_READ;
    t.id     = vif.mon_cb.ar_id;
    t.addr   = vif.mon_cb.ar_addr;
    t.len    = vif.mon_cb.ar_len;
    t.size   = vif.mon_cb.ar_size;
    t.burst  = vif.mon_cb.ar_burst;
    t.lock   = vif.mon_cb.ar_lock;
    t.cache  = vif.mon_cb.ar_cache;
    t.prot   = vif.mon_cb.ar_prot;
    t.qos    = vif.mon_cb.ar_qos;
    t.region = vif.mon_cb.ar_region;
    t.atop   = '0;
    t.user   = vif.mon_cb.ar_user;
    t.start_t = $realtime;
    ar_q.push_back(t);
  endfunction

  function void sample_r();
    axi_seq_item t;
    id_t         id;
    int          idx[$];
    int unsigned n;
    if (vif.mon_cb.r_valid !== 1'b1 || vif.mon_cb.r_ready !== 1'b1) return;
    id = vif.mon_cb.r_id;
    if (!r_cur.exists(id)) begin
      idx = ar_q.find_first_index(x) with (x.id == id);
      if (idx.size() == 0) begin
        `uvm_error("RNOAR", $sformatf("R beat with id %0h, but no read with that id", id))
        return;
      end
      r_cur[id] = ar_q[idx[0]];
      ar_q.delete(idx[0]);
    end
    t = r_cur[id];
    n = t.rdata.size();
    t.rdata = new[n + 1](t.rdata);
    t.resp  = new[n + 1](t.resp);
    t.ruser = new[n + 1](t.ruser);
    t.rdata[n] = vif.mon_cb.r_data;
    t.resp[n]  = vif.mon_cb.r_resp;
    t.ruser[n] = vif.mon_cb.r_user;
    if (vif.mon_cb.r_last === 1'b1) begin
      if (t.rdata.size() != t.num_beats())
        `uvm_error("RLEN", $sformatf("read got %0d beats, AR len says %0d", t.rdata.size(), t.num_beats()))
      t.rsp_id = id;
      t.end_t  = $realtime;
      r_cur.delete(id);
      n_rd++;
      ap.write(t);
    end else if (t.rdata.size() >= t.num_beats()) begin
      `uvm_error("RLAST", $sformatf("beat %0d of a %0d-beat read without r_last", n, t.num_beats()))
    end
  endfunction

  // At the end of the test nothing may be left half-done.
  function void check_phase(uvm_phase phase);
    if (aw_q.size() || wb_q.size() || wait_b.size() || ar_q.size() || r_cur.num() || w_data.size())
      `uvm_error("UNFINISHED", $sformatf("left over: %0d AW without W, %0d W bursts without AW, %0d writes without B, %0d AR without R, %0d reads without last R, %0d loose W beats",
                 aw_q.size(), wb_q.size(), wait_b.size(), ar_q.size(), r_cur.num(), w_data.size()))
  endfunction

  function void report_phase(uvm_phase phase);
    `uvm_info("MON", $sformatf("%0d writes and %0d reads finished; stall cycles (valid=1, ready=0): AW %0d, W %0d, B %0d, AR %0d, R %0d",
                               n_wr, n_rd, stall_aw, stall_w, stall_b, stall_ar, stall_r), UVM_LOW)
  endfunction
endclass
