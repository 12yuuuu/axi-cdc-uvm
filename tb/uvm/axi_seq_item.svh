// Copyright 2026 Kuan-Yu Liu
// SPDX-License-Identifier: Apache-2.0
//
typedef enum bit {AXI_READ = 1'b0, AXI_WRITE = 1'b1} axi_kind_e;

// One AXI4 transaction (a whole burst). The sequence sets the request
// fields; the driver (or a monitor) fills in the response fields.
class axi_seq_item extends uvm_sequence_item;
  `uvm_object_utils(axi_seq_item)

  // ---- request (AW or AR, plus W beats for a write)
  rand axi_kind_e        kind;
  rand id_t              id;
  rand addr_t            addr;
  rand axi_pkg::len_t    len;     // number of beats - 1
  rand axi_pkg::size_t   size;    // bytes per beat = 2**size
  rand axi_pkg::burst_t  burst;
  rand logic             lock;
  rand axi_pkg::cache_t  cache;
  rand axi_pkg::prot_t   prot;
  rand axi_pkg::qos_t    qos;
  rand axi_pkg::region_t region;
  rand axi_pkg::atop_t   atop;    // AW only
  rand user_t            user;    // AW/AR user
  rand data_t            data[];  // W data, one entry per beat
  rand strb_t            strb[];  // W strobes, one entry per beat
  rand user_t            wuser[]; // W user, one entry per beat

  // ---- response
  axi_pkg::resp_t        resp[];  // write: resp[0] is B; read: one per beat
  data_t                 rdata[]; // R data, one entry per beat
  user_t                 ruser[]; // R user, one entry per beat
  user_t                 buser;   // B user
  id_t                   rsp_id;  // ID seen on B or R

  // ---- filled in by the monitors
  realtime               start_t; // AW / AR handshake
  realtime               end_t;   // B / last R handshake

  // ---- timing knobs for the driver (random, bounded by delay_max)
  rand int unsigned      aw_delay; // idle cycles before AW valid
  rand int unsigned      w_delay;  // idle cycles before the first W beat
  rand int unsigned      w_gap;    // up to this many idle cycles between W beats
  rand int unsigned      ar_delay; // idle cycles before AR valid

  // ---- shape knobs (not random): the sequence sets them before randomize()
  int unsigned max_len   = 15;     // len <= max_len
  bit          any_burst = 1'b0;   // 1: FIXED and WRAP allowed, not only INCR
  bit          any_size  = 1'b0;   // 1: narrow beats and unaligned start allowed
  bit          sparse    = 1'b0;   // 1: random write strobes inside the active lanes
  bit          long_ok   = 1'b0;   // 1: some INCR bursts longer than 16 beats (set max_len = 255)
  int unsigned delay_max = 0;      // upper bound of the four timing knobs

  constraint c_burst { burst != 2'b11;  // reserved encoding
                       !any_burst -> burst == axi_pkg::BURST_INCR; }
  constraint c_size  { size <= $clog2(SW);
                       !any_size -> size == $clog2(SW); }
  constraint c_len   { len <= max_len;
                       burst == axi_pkg::BURST_WRAP  -> len inside {1, 3, 7, 15};
                       burst == axi_pkg::BURST_FIXED -> len <= 15; }
  // Unaligned start only for narrow INCR / FIXED; WRAP must be aligned.
  constraint c_align { (!any_size || burst == axi_pkg::BURST_WRAP) -> addr % (1 << size) == 0; }
  // An INCR burst must not cross a 4 KiB boundary (AXI spec A3.4.1).
  constraint c_4k    { burst == axi_pkg::BURST_INCR -> (addr % 4096) + ((len + 1) << size) <= 4096; }
  // No exclusive access and no atomics (the slave model does not do them).
  constraint c_side  { lock == 1'b0; atop == '0; }
  constraint c_data  {
    data.size()  == ((kind == AXI_WRITE) ? len + 1 : 0);
    strb.size()  == data.size();
    wuser.size() == data.size();
  }
  // Long bursts are rare, so most traffic still has many short bursts.
  constraint c_long  { long_ok -> len dist { [0:15] :/ 90, [16:254] :/ 7, 255 :/ 3 }; }
  constraint c_delay { aw_delay <= delay_max; w_delay <= delay_max;
                       w_gap    <= delay_max; ar_delay <= delay_max; }

  // Strobes follow the active byte lanes of each beat (all of them, or a
  // random subset if `sparse`). Lanes outside the beat are always 0.
  function void post_randomize();
    int unsigned lo, hi;
    foreach (strb[i]) begin
      beat_lanes(i, lo, hi);
      strb[i] = '0;
      for (int unsigned b = lo; b <= hi; b++)
        strb[i][b] = sparse ? 1'($urandom_range(1)) : 1'b1;
    end
  endfunction

  function new(string name = "axi_seq_item");
    super.new(name);
  endfunction

  function int unsigned num_beats();
    return len + 1;
  endfunction

  // Address of beat i (AXI spec A3.4.1). Static, so the slave model and the
  // scoreboard can use it without an item.
  static function addr_t calc_beat_addr(addr_t a, axi_pkg::size_t sz,
                                        axi_pkg::len_t ln, axi_pkg::burst_t bt,
                                        int unsigned i);
    int unsigned nbytes  = 1 << sz;
    int unsigned total   = nbytes * (ln + 1);
    addr_t       aligned = a & ~addr_t'(nbytes - 1);
    addr_t       lower, ba;
    case (bt)
      axi_pkg::BURST_FIXED: return a;
      axi_pkg::BURST_WRAP: begin
        lower = a & ~addr_t'(total - 1);
        ba    = aligned + addr_t'(i * nbytes);
        if (ba >= lower + total) ba -= total;
        return ba;
      end
      default: return (i == 0) ? a : aligned + addr_t'(i * nbytes); // INCR
    endcase
  endfunction

  // Byte lanes that carry data in beat i (AXI spec A3.4.3): from the beat
  // address up to the end of its size-aligned container.
  function void beat_lanes(int unsigned i, output int unsigned lo, output int unsigned hi);
    addr_t       a      = calc_beat_addr(addr, size, len, burst, i);
    int unsigned nbytes = 1 << size;
    addr_t       top    = (a & ~addr_t'(nbytes - 1)) + addr_t'(nbytes - 1);
    lo = a   % SW;
    hi = top % SW;
  endfunction

  function void do_copy(uvm_object rhs);
    axi_seq_item t;
    super.do_copy(rhs);
    if (!$cast(t, rhs)) `uvm_fatal("COPY", "do_copy: wrong type")
    kind  = t.kind;  id    = t.id;    addr   = t.addr;   len  = t.len;
    size  = t.size;  burst = t.burst; lock   = t.lock;   cache = t.cache;
    prot  = t.prot;  qos   = t.qos;   region = t.region; atop = t.atop;
    user  = t.user;  data  = t.data;  strb   = t.strb;   wuser = t.wuser;
    resp  = t.resp;  rdata = t.rdata; ruser  = t.ruser;  buser = t.buser;
    rsp_id = t.rsp_id; start_t = t.start_t; end_t = t.end_t;
  endfunction

  // Compare one field and note it if different.
  local function void cmp(ref string s, input string name,
                          input logic [CW-1:0] a, input logic [CW-1:0] b);
    if (a !== b) s = {s, $sformatf(" %s: %h vs %h;", name, a, b)};
  endfunction

  // Empty string if `o` carries exactly the same AXI content, otherwise a
  // list of the differences. Times are not compared.
  function string diff(axi_seq_item o);
    string s = "";
    cmp(s, "kind", kind, o.kind);     cmp(s, "id", id, o.id);
    cmp(s, "addr", addr, o.addr);     cmp(s, "len", len, o.len);
    cmp(s, "size", size, o.size);     cmp(s, "burst", burst, o.burst);
    cmp(s, "lock", lock, o.lock);     cmp(s, "cache", cache, o.cache);
    cmp(s, "prot", prot, o.prot);     cmp(s, "qos", qos, o.qos);
    cmp(s, "region", region, o.region); cmp(s, "user", user, o.user);
    cmp(s, "rsp_id", rsp_id, o.rsp_id);
    if (kind == AXI_WRITE) begin
      cmp(s, "atop", atop, o.atop);
      if (data.size() != o.data.size())
        s = {s, $sformatf(" W beats: %0d vs %0d;", data.size(), o.data.size())};
      else
        foreach (data[i]) begin
          cmp(s, $sformatf("w[%0d].data", i), data[i], o.data[i]);
          cmp(s, $sformatf("w[%0d].strb", i), strb[i], o.strb[i]);
          cmp(s, $sformatf("w[%0d].user", i), wuser[i], o.wuser[i]);
        end
      if (resp.size() != 1 || o.resp.size() != 1) s = {s, " B missing;"};
      else cmp(s, "b.resp", resp[0], o.resp[0]);
      cmp(s, "b.user", buser, o.buser);
    end else begin
      if (rdata.size() != o.rdata.size())
        s = {s, $sformatf(" R beats: %0d vs %0d;", rdata.size(), o.rdata.size())};
      else
        foreach (rdata[i]) begin
          cmp(s, $sformatf("r[%0d].data", i), rdata[i], o.rdata[i]);
          cmp(s, $sformatf("r[%0d].resp", i), resp[i], o.resp[i]);
          cmp(s, $sformatf("r[%0d].user", i), ruser[i], o.ruser[i]);
        end
    end
    return s;
  endfunction

  function string convert2string();
    string s;
    s = $sformatf("%s id=%0h addr=%h len=%0d size=%0d burst=%0d cache=%h prot=%h qos=%h region=%h user=%h",
                  kind.name(), id, addr, len, size, burst, cache, prot, qos, region, user);
    foreach (data[i])  s = {s, $sformatf("\n    w[%0d] %h strb %h user %h", i, data[i], strb[i], wuser[i])};
    foreach (rdata[i]) s = {s, $sformatf("\n    r[%0d] %h resp %0d user %h", i, rdata[i], resp[i], ruser[i])};
    if (kind == AXI_WRITE && resp.size() > 0)
      s = {s, $sformatf("\n    b resp %0d user %h id %0h", resp[0], buser, rsp_id)};
    return s;
  endfunction
endclass
