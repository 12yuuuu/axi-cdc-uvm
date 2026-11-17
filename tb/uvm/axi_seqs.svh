// Copyright 2026 Kuan-Yu Liu
// SPDX-License-Identifier: Apache-2.0
//
// Address regions used by the tests (64 KiB apart, so they never overlap).
localparam addr_t REGION_A = 32'h0001_0000;
localparam addr_t REGION_B = 32'h0002_0000;
localparam addr_t REGION_C = 32'h0003_0000;

// Smoke sequence: one single-beat and one 4-beat transfer. With
// `do_reads` = 0 it writes, with 1 it reads the same addresses back. The
// test runs the two halves with idle() in between: AXI does not order reads
// against writes, so a read sent while the write to the same address is
// still in flight may legally return the old data (Stage 4 lesson).
// It only creates traffic; the scoreboard does all the checking.
class smoke_seq extends uvm_sequence #(axi_seq_item);
  `uvm_object_utils(smoke_seq)

  bit do_reads = 1'b0;

  function new(string name = "smoke_seq");
    super.new(name);
  endfunction

  task body();
    one(4'h1, 32'h0000_1000, 1);  // one beat
    one(4'h2, 32'h0000_2000, 4);  // 4-beat INCR burst
  endtask

  task one(id_t t_id, addr_t t_addr, int unsigned n_beats);
    axi_seq_item t = axi_seq_item::type_id::create(do_reads ? "rd" : "wr");
    axi_kind_e   k = do_reads ? AXI_READ : AXI_WRITE;
    start_item(t);
    if (!t.randomize() with { kind == local::k; id == local::t_id;
                              addr == local::t_addr; len == local::n_beats - 1; })
      `uvm_fatal("RAND", "smoke item: randomize() failed")
    finish_item(t);
  endtask
endclass

// General random sequence: n transactions inside [base, base + span).
// The knobs shape the transactions; everything else is random.
class axi_rand_seq extends uvm_sequence #(axi_seq_item);
  `uvm_object_utils(axi_rand_seq)

  int unsigned n         = 10;
  int          kind_sel  = 1;          // 1: writes, 0: reads, -1: mixed
  addr_t       base      = REGION_A;
  int unsigned span      = 4096;
  int unsigned min_len   = 0;
  int unsigned max_len   = 15;
  bit          any_burst = 1'b0;       // FIXED and WRAP too
  bit          any_size  = 1'b0;       // narrow and unaligned too
  bit          sparse    = 1'b0;       // random write strobes
  bit          long_ok   = 1'b0;       // some INCR bursts of 17-256 beats (needs max_len = 255)
  int unsigned delay_max = 0;          // random aw/w/ar delay and W gap, 0..max
  int          aw_lead   = 0;          // >0: AW goes first by this many cycles; <0: W goes first
  int unsigned id_max    = (1 << IW) - 1;

  function new(string name = "axi_rand_seq");
    super.new(name);
  endfunction

  task body();
    axi_seq_item t;
    int unsigned lead = (aw_lead < 0) ? -aw_lead : aw_lead;
    repeat (n) begin
      t = axi_seq_item::type_id::create("t");
      t.max_len   = max_len;
      t.any_burst = any_burst;
      t.any_size  = any_size;
      t.sparse    = sparse;
      t.long_ok   = long_ok;
      t.delay_max = (delay_max > lead) ? delay_max : lead;
      start_item(t);
      if (!t.randomize() with {
            (local::kind_sel == 1) -> kind == AXI_WRITE;
            (local::kind_sel == 0) -> kind == AXI_READ;
            addr >= local::base;
            (addr + ((len + 1) << size)) <= (local::base + local::span);
            len >= local::min_len;
            id <= local::id_max;
            (local::aw_lead > 0) -> (w_delay == local::aw_lead && aw_delay == 0);
            (local::aw_lead < 0) -> (aw_delay == -local::aw_lead && w_delay == 0);
            (local::aw_lead != 0) -> w_gap == 0;
          })
        `uvm_fatal("RAND", $sformatf("%s: randomize() failed", get_name()))
      finish_item(t);
    end
  endtask
endclass

// Read every byte of [base, base + bytes) with full-width 16-beat INCR
// reads, so the scoreboard checks the whole region against its reference
// memory. `base` must be 128-byte aligned.
class axi_sweep_read_seq extends uvm_sequence #(axi_seq_item);
  `uvm_object_utils(axi_sweep_read_seq)

  addr_t       base  = REGION_A;
  int unsigned bytes = 4096;

  function new(string name = "axi_sweep_read_seq");
    super.new(name);
  endfunction

  task body();
    axi_seq_item t;
    for (int unsigned off = 0; off < bytes; off += 16 * SW) begin
      t = axi_seq_item::type_id::create("t");
      start_item(t);
      if (!t.randomize() with { kind == AXI_READ; addr == local::base + local::off;
                                len == 15; size == $clog2(SW); burst == axi_pkg::BURST_INCR; })
        `uvm_fatal("RAND", "sweep read: randomize() failed")
      finish_item(t);
    end
  endtask
endclass
