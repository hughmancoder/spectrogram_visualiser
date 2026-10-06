# Phase 2 Spec — SDRAM Controller & Framebuffer

This is the contract your RTL has to meet. The testbenches in `sim/` check it.
Internal design choices are up to you unless a section says **required**.

```
                      sys_clk 64.8 MHz                         pix_clk 74.25 MHz
 producer ──wp_*──► [ write FIFO ] ──► ┌──────────────┐ req/rd/wr ┌────────────┐   O_sdram_*
 (any clk)          async_fifo         │ framebuffer  │◄─────────►│ sdram_ctrl │◄──────────► SDRAM
                                       │  arbiter +   │           └────────────┘
 HDMI ◄──pixel──── [ read FIFO ] ◄──── │  read engine │
 (pix_clk)          async_fifo         └──────────────┘
```

| Module | Who writes it | File | Testbench |
|---|---|---|---|
| `cdc_sync` | **you** | `src/cdc_sync.sv` | via `async_fifo_tb` |
| `reset_sync` | **you** | `src/reset_sync.sv` | via `async_fifo_tb` |
| `async_fifo` | **you** | `src/async_fifo.sv` | `async_fifo_tb` |
| `sdram_ctrl` | **you** | `src/sdram_ctrl.sv` | `sdram_ctrl_tb` |
| `framebuffer` | **you** | `src/framebuffer.sv` | `framebuffer_tb` |
| `top` integration | **you** | `src/top.sv` | `top_tb` (to be updated) |
| `fb_pkg`, `pattern_gen`, `pll_sys` | provided | `src/` | — |
| `sdram_model` | provided | `sim/models/` | — |

Run things:

```bash
make sim TB=async_fifo_tb      # one testbench
make test                      # all Phase 2 testbenches -> PASS/FAIL summary
make sim TB=framebuffer_tb REF=1   # stuck? use hidden reference for modules you haven't written
```

`REF=1` only fills in modules missing from `src/`; if you've written a module, your version is the one used.
The reference lives in `.reference/phase2_rtl/` (git-ignored). Try not to look.

---

## 1. `cdc_sync` — multi-flop synchroniser

```systemverilog
module cdc_sync #(parameter int WIDTH = 1, parameter int STAGES = 2) (
    input  wire             clk,     // destination clock
    input  wire             rst_n,   // async, active-low
    input  wire [WIDTH-1:0] d,       // from another clock domain
    output wire [WIDTH-1:0] q
);
```
- `STAGES` flops in series, clocked by `clk`, reset to 0.
- Only for single bits or Gray-coded buses. Know why.

## 2. `reset_sync` — async assert, sync de-assert

```systemverilog
module reset_sync #(parameter int STAGES = 2) (
    input  wire clk,
    input  wire arst_n,   // asynchronous, from anywhere
    output wire rst_n     // asserts immediately, releases on a clk edge
);
```

## 3. `async_fifo` — dual-clock FIFO, first-word-fall-through (required interface)

```systemverilog
module async_fifo #(parameter int WIDTH = 32, parameter int ADDR_W = 9) (  // depth = 2**ADDR_W
    input  wire              arst_n,     // async flush, any domain
    // write side
    input  wire              wr_clk,
    input  wire              wr_en,
    input  wire [WIDTH-1:0]  wr_data,
    output wire              wr_full,
    output logic [ADDR_W:0]  wr_count,
    // read side
    input  wire              rd_clk,
    input  wire              rd_en,
    output logic [WIDTH-1:0] rd_data,
    output wire              rd_empty,
    output logic [ADDR_W:0]  rd_count
);
```

| Rule | Detail |
|---|---|
| Write | Word accepted on `posedge wr_clk` when `wr_en && !wr_full`. Writes while full are dropped. |
| FWFT read | While `!rd_empty`, `rd_data` already holds the oldest word, so no `rd_en` is needed to see it. `rd_en` pops it; the next word appears the following cycle, giving sustained 1 word/clk. `rd_en` while empty is ignored. |
| Latency | A word written into an empty FIFO must appear on the read side within **6 `rd_clk` cycles**. |
| Capacity | With the reader idle, at least `DEPTH` words are accepted before `wr_full` (DEPTH+1 is OK if your FWFT register adds a slot). When full, `wr_count == DEPTH`. |
| `rd_count` | **Never over-reports**: if `rd_count >= N`, N back-to-back pops must all succeed. |
| `wr_count` | **Never under-reports**: if `DEPTH - wr_count >= N`, N back-to-back writes must all succeed. |
| Flush | `arst_n` low (asynchronously, any time) empties the FIFO. After release: empty, counts 0. |
| Synthesis | The memory should map to Gowin BSRAM, so use a registered read. |

How the design works: Gray-coded pointers, one extra MSB, 2-flop sync of each pointer into the other domain, full/empty comparisons.

## 4. `sdram_ctrl` — burst SDRAM controller

### Interface (required)

```systemverilog
module sdram_ctrl #(
    parameter int CLK_FREQ_HZ  = 64_800_000,
    parameter int BURST_LEN    = 32,     // words per request: 8, 16, 32, ... 256
    parameter int INIT_WAIT_US = 200
    // any other parameters you like, with defaults
)(
    input  wire         clk,
    input  wire         rst_n,
    // request
    input  wire         req_valid,
    output wire         req_ready,
    input  wire         req_we,          // 1 = write burst
    input  wire  [20:0] req_addr,        // word address, BURST_LEN-aligned
    // write data (FWFT source)
    input  wire  [31:0] wr_data,
    output wire         wr_data_ack,     // controller consumes wr_data this cycle
    // read data
    output logic [31:0] rd_data,
    output logic        rd_data_valid,
    output logic        init_done,
    // SDRAM pins (O_sdram_clk is driven by top from pll_sys.sdram_clk)
    output wire         sdram_cke, sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n,
    output logic [10:0] sdram_addr,
    output logic [1:0]  sdram_ba,
    output wire  [3:0]  sdram_dqm,
    inout  wire  [31:0] sdram_dq
);
```

### Behaviour

| Item | Requirement |
|---|---|
| Handshake | A request is accepted on a `posedge clk` with `req_valid && req_ready`. `req_ready` must stay low until `init_done`. |
| Address map | `req_addr = {row[10:0], bank[1:0], col[7:0]}` (checked through the model's backdoor). Aligned bursts never cross a row. |
| Write data | `wr_data_ack` high for exactly `BURST_LEN` **consecutive** cycles per write burst; `wr_data` is valid before ack. |
| Read data | `rd_data_valid` high for exactly `BURST_LEN` **consecutive** cycles per read burst, in address order. |
| Ordering | Requests complete in order. |
| Init | ≥ `INIT_WAIT_US` of NOP/INHIBIT, PRECHARGE ALL, ≥ 2 AUTO REFRESH, LOAD MODE REGISTER, then `init_done = 1`. |
| Refresh | 4096 rows / 64 ms means one AUTO REFRESH every ≤ 15.6 µs. The model flags any gap that is longer. |
| Throughput | Back-to-back bursts must average ≤ `BURST_LEN + 16` cycles each (so ≥ 66 % efficiency at 32). |
| Protocol | Zero errors from `sim/models/sdram_model.sv` (tRCD, tRP, tRC, tRAS, tRFC, tWR, tMRD, bus contention, …). |
| DQM | Keep at `4'b0000` (the model requires it during reads). |

### Timing numbers (64.8 MHz → 15.43 ns/cycle; −6/−7 grade SDRAM)

| Param | ns | cycles @ 64.8 MHz |
|---|---|---|
| tRCD (ACT→RD/WR) | 18 | 2 |
| tRP (PRE→ACT) | 18 | 2 |
| tRC (ACT→ACT / REF→REF) | 60 | 4 |
| tRAS (ACT→PRE) | 42 | 3 |
| tRFC (REF→cmd) | 60 | 4 |
| tWR (last data→PRE) | — | 2 |
| tMRD | — | 2 |
| CAS latency | — | 2 (or 3) |

Commands `{cs_n, ras_n, cas_n, we_n}`: NOP `0111`, ACTIVE `0011`, READ `0101`, WRITE `0100`,
PRECHARGE `0010` (A10=1 → all banks), AUTO REFRESH `0001`, LOAD MODE `0000`.
Mode register: `A[2:0]` burst length (`011` = 8), `A3` 0 = sequential, `A[6:4]` CAS latency, `A9` 0 = burst writes.

### Design hints (not required)
- BL=8 in the mode register; issue a new READ/WRITE every 8 cycles in the same row so longer bursts stream without gaps; set A10 (auto-precharge) on the last one. Then you never need to track open rows.
- Register every SDRAM output (command, address, DQ, output enable).
- **Read capture is the hard part.** The SDRAM clock is 180° shifted (`pll_sys`). Read data for a READ registered at edge T comes back roughly `T + 0.5 + CL` cycles plus `tAC` plus I/O delay later. Work out which edge to sample on (falling-edge capture is worth considering), and make it a parameter, because it may need tuning on real hardware. `sdram_ctrl_tb` lets you sweep board delays:
  `make sim TB=sdram_ctrl_tb TB_PARAMS="-Psdram_ctrl_tb.CLK_DLY_PS=0 -Psdram_ctrl_tb.DQ_DLY_PS=0"`

## 5. `framebuffer` — arbiter + read engine + FIFOs + pixel unpacker

### Interface (required)

```systemverilog
module framebuffer #(
    parameter int H_ACTIVE   = 1280,
    parameter int V_ACTIVE   = 720,
    parameter int BURST_LEN  = 32,
    parameter int RD_FIFO_AW = 9,
    parameter int WR_FIFO_AW = 9
)(
    input  wire        arst_n,          // global async reset
    // system / SDRAM domain
    input  wire        sys_clk,
    input  wire        sdram_ready,     // sdram_ctrl.init_done
    output wire        req_valid,
    input  wire        req_ready,
    output wire        req_we,
    output wire [20:0] req_addr,
    output wire [31:0] wr_data,
    input  wire        wr_data_ack,
    input  wire [31:0] rd_data,
    input  wire        rd_data_valid,
    // pixel domain
    input  wire        pix_clk,
    input  wire        vsync,           // active high (from video_sync)
    input  wire        de,
    output wire [15:0] pixel,           // RGB565, same cycle as de
    output wire        underflow,       // de && no data available
    // write port (producer domain)
    input  wire        wp_clk,
    input  wire        wp_valid,
    output wire        wp_ready,
    input  wire [20:0] wp_addr,
    input  wire [31:0] wp_data
);
```

### Behaviour

| Item | Requirement |
|---|---|
| Pixel format | RGB565, 2 pixels per word: `word[15:0]` = even x, `word[31:16]` = odd x. Frame at word address 0, `H_ACTIVE/2` words per line, `H*V/2` words per frame. |
| Display | `pixel` is valid **in the same cycle** as `de`, matching `video_sync`'s registered `de`/`pixel_x`/`pixel_y`. Output 0 when no data is available. |
| Frame sync | Every frame starts again at word 0. Suggested: hold the read FIFO and the read engine in reset while `vsync` is high, then fetch exactly `H*V/2` words. |
| Underflow | Must never happen at 1280×720 (or in the TB). |
| Write port | Valid/ready in `wp_clk`. A word is accepted when `wp_valid && wp_ready`. Producers write **whole, aligned bursts** of `BURST_LEN` consecutive addresses. |
| Arbitration | Video reads take priority over writes; writes must still get through while the screen is being displayed (TB test 3). |
| Read FIFO flow control | Only issue a read burst when the read FIFO is guaranteed to have room for it, counting words that are already requested but not yet delivered. |

Bandwidth check at 720p: 640 words per 22.2 µs line ≈ 29 M words/s. 32-word bursts at 64.8 MHz give ≈ 54 M words/s.

## 6. `top` integration (after the framebuffer TB passes)

1. Add the SDRAM ports to `top` using these exact names (the CST already constrains them):
   `O_sdram_clk, O_sdram_cke, O_sdram_cs_n, O_sdram_cas_n, O_sdram_ras_n, O_sdram_wen_n, O_sdram_dqm[3:0], O_sdram_addr[10:0], O_sdram_ba[1:0], IO_sdram_dq[31:0]`
2. Instantiate `pll_sys` (64.8 MHz + 180° `sdram_clk` → `O_sdram_clk`), `sdram_ctrl`, `framebuffer`, `pattern_gen` (clocked by `clk_pixel`).
3. Feed `fb_pkg::rgb565_to_rgb888(pixel)` into `hdmi_tx`.
4. Debug LEDs. Suggested: SDRAM `init_done`, `pattern_gen.done`, a stretched `underflow`, and a stretched "pixel ≠ expected gradient" flag. The last one tells you straight away whether read capture is wrong on real hardware.
5. Update `sim/top_tb.sv` to connect `sim/models/sdram_model.sv` to the new ports.

**Hardware pass criterion:** a smooth, stable gradient, with red increasing left→right, green increasing top→bottom and blue decreasing left→right. No sparkles, no shifted columns, and the mismatch LED stays off.
