// Copyright 2026 Kuan-Yu Liu
// SPDX-License-Identifier: Apache-2.0
//
// Reference model for the end-to-end data check: a byte memory plus the
// expected response of every burst.
//
// It is written apart from the stimulus and the slave model on purpose.
// The slave and the sequence item compute beat addresses in closed form
// (axi_seq_item::calc_beat_addr, masks); this model walks the burst step by
// step with the transfer pseudo-code of the AXI spec (A3.4.2: Start_Address,
// Aligned_Address, Wrap_Boundary, Lower/Upper_Byte_Lane, with divisions).
// A mistake in one of them therefore shows up as an SB_DATA mismatch instead
// of being repeated on both sides. addr_model_test checks both against
// hand-computed vectors, and +INJECT_SLV_WRAP_BUG shows the data check
// catching an address bug in the slave alone.
class axi_ref_model extends uvm_object;
  `uvm_object_utils(axi_ref_model)

  axi_tb_cfg cfg;              // address map (error pages)
  bit [7:0]  mem [addr_t];     // only written bytes exist; others read 0

  function new(string name = "axi_ref_model");
    super.new(name);
  endfunction

  // Beat addresses and active byte lanes of a burst, by the AXI pseudo-code.
  static function void beats(input addr_t start, input int unsigned size, input int unsigned len,
                             input axi_pkg::burst_t burst,
                             output addr_t a[], output int unsigned lo[], output int unsigned hi[]);
    longint unsigned number_bytes    = longint'(1) << size;
    longint unsigned burst_length    = len + 1;
    longint unsigned data_bus_bytes  = SW;
    longint unsigned address         = start;
    longint unsigned aligned_address = (start / number_bytes) * number_bytes;
    longint unsigned dtsize          = number_bytes * burst_length;
    longint unsigned lower_wrap      = (start / dtsize) * dtsize;
    longint unsigned upper_wrap      = lower_wrap + dtsize;
    bit              aligned         = (aligned_address == start);
    a  = new[burst_length];
    lo = new[burst_length];
    hi = new[burst_length];
    for (int unsigned n = 0; n < burst_length; n++) begin
      lo[n] = address - (address / data_bus_bytes) * data_bus_bytes;
      if (aligned) hi[n] = lo[n] + number_bytes - 1;
      else         hi[n] = aligned_address + number_bytes - 1 - (address / data_bus_bytes) * data_bus_bytes;
      a[n] = addr_t'(address);
      if (burst != axi_pkg::BURST_FIXED) begin
        if (aligned) begin
          address = address + number_bytes;
          if (burst == axi_pkg::BURST_WRAP && address >= upper_wrap) address = lower_wrap;
        end else begin
          address = aligned_address + number_bytes;
          aligned = 1'b1;
        end
      end
    end
  endfunction

  function axi_pkg::resp_t expected_resp(addr_t start);
    return cfg.resp_for(start);
  endfunction

  // A write as seen at the source port. Only OKAY writes change memory.
  function void write(axi_seq_item t);
    addr_t       a[];
    int unsigned lo[], hi[];
    longint unsigned word;
    if (expected_resp(t.addr) != axi_pkg::RESP_OKAY) return;
    beats(t.addr, t.size, t.len, t.burst, a, lo, hi);
    foreach (a[n]) begin
      word = (longint'(a[n]) / SW) * SW;
      for (int unsigned b = lo[n]; b <= hi[n]; b++)
        if (t.strb[n][b]) mem[addr_t'(word + b)] = t.data[n][8*b +: 8];
    end
  endfunction

  // Expected data of every beat of a read; only lanes lo[n]..hi[n] count.
  function void read_expect(axi_seq_item t, output data_t exp[],
                            output int unsigned lo[], output int unsigned hi[]);
    addr_t           a[];
    longint unsigned word;
    beats(t.addr, t.size, t.len, t.burst, a, lo, hi);
    exp = new[a.size()];
    foreach (a[n]) begin
      word   = (longint'(a[n]) / SW) * SW;
      exp[n] = '0;
      for (int unsigned b = lo[n]; b <= hi[n]; b++)
        if (mem.exists(addr_t'(word + b))) exp[n][8*b +: 8] = mem[addr_t'(word + b)];
    end
  endfunction
endclass
