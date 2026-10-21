/*

Move data safely between two unrelated clocks (e.g. SDRAM clock -> HDMI
pixel clock). The two sides share no clock, so the ONLY things that cross
the boundary are the two pointers, and they cross as Gray code through
2-flop synchronisers. Data itself never crosses through a synchroniser:
it sits in a RAM that each side accesses with its own clock.


THE FOUR IDEAS THIS MODULE IS BUILT ON
  1. Extra pointer bit.
     Pointers are ADDR_W+1 bits wide. The low ADDR_W bits address the RAM;
     the top bit counts "laps". Equal pointers      -> FIFO empty.
     Pointers equal except the top bit -> FIFO full.
  2. Gray code across the clock boundary.
     A binary counter can change many bits at once (011 -> 100). If the other
     clock samples mid-change it can capture a value that was never the real
     pointer (e.g. 111). Gray code changes exactly ONE bit per increment, so
     a mistimed sample yields either the old value or the new value, both of
     which are legitimate. The worst case is a slightly stale pointer.
  3. Stale pointers are safe.
     The write side sees an old read pointer -> thinks the FIFO is fuller than
     it really is -> may delay a write, never overflows.
     The read side sees an old write pointer -> thinks the FIFO is emptier
     than it really is -> may delay a read, never underflows.
  4. First-Word-Fall-Through output register.
     When rd_empty is low, rd_data ALREADY holds the head word. Pulse rd_en
     to pop it; the next word appears on the following clock. This gives one
     word per clock sustained and lets the RAM use a registered read, which
     maps onto block RAM (e.g. Gowin BSRAM).


Why keep both binary and Gray:
- Binary is easy to use for RAM addressing and subtraction.
- Gray is safe to send to the other clock domain.

Binary:  000 001 010 011 100 101 110 111
Gray:    000 001 011 010 110 111 101 100
*/


module async_fifo #(
    parameter int WIDTH  = 16,     // Data width
    parameter int ADDR_W = 9       // Depth = 2^ADDR_W 
)(
    input  wire              arst_n,   // shared async reset, any domain, active-low

    // Write Domain (Producer / SDRAM)
    input  wire              wr_clk,
    input  wire              wr_en,
    input  wire [WIDTH-1:0]  wr_data,
    output wire              wr_full,
    output logic [ADDR_W:0]  wr_count,

    // Read Domain (Consumer / HDMI Pixel Clock)
    input  wire              rd_clk,
    input  wire              rd_en,
    output logic [WIDTH-1:0] rd_data,
    output wire              rd_empty,
    output logic [ADDR_W:0]  rd_count
);

    localparam int DEPTH = 1 << ADDR_W;

// binary to gray code formula
function automatic logic [ADDR_W:0] bin2gray(input logic [ADDR_W:0] b);
    bin2gray = b ^ (b >> 1);
endfunction

function automatic logic [ADDR_W:0] gray2bin(input logic [ADDR_W:0] g);
    logic [ADDR_W:0] b;
    b[ADDR_W] = g[ADDR_W];
    for (int i = ADDR_W - 1; i >= 0; i--)
        b[i] = b[i+1] ^ g[i];
    gray2bin = b;
endfunction

// wire up synchronisation reset modules to prevent metastability
wire wr_rst_sync_n, rd_rst_sync_n; 
reset_sync u_wr_rst (.clk(wr_clk), .arst_n(arst_n), .rst_n(wr_rst_sync_n));
reset_sync u_rd_rst (.clk(rd_clk), .arst_n(arst_n), .rst_n(rd_rst_sync_n));


// SHARED STATE
// dual port RAM
logic [WIDTH-1:0] mem [0:DEPTH-1];
// Pointers (binary + Gray) for write and read domains
logic [ADDR_W:0] wbin, wgray;          // write domain
logic [ADDR_W:0] rbin, rgray;          // read domain

wire  [ADDR_W:0] rgray_sync;           // rgray as seen in wr_clk domain
wire  [ADDR_W:0] wgray_sync;           // wgray as seen in rd_clk domain

logic            full_q;               // registered full flag
logic            out_valid;            // assert when output register holds a word
 

 
// WRITE DOMAIN

// Read pointer -> write clock 
cdc_sync #(.WIDTH(ADDR_W + 1)) u_sync_r2w (
    .clk   (wr_clk),
    .rst_n (wr_rst_sync_n),
    .d     (rgray),
    .q     (rgray_sync)
);

// Write only if requested, there is room, and we are out of reset.
wire do_write = wr_en && !full_q && wr_rst_sync_n;

// Next pointer values (moves by at most 1 per clock, so Gray changes 1 bit).
// wbin only updates at the end of this clock edge, so Gray is computed
// from the NEXT binary value to keep both pointers in step.
wire [ADDR_W:0] wbin_next  = do_write ? wbin + 1'b1 : wbin;
wire [ADDR_W:0] wgray_next = bin2gray(wbin_next);

// FULL condition: write pointer has lapped the read pointer (binary equal except MSB).
// Flipping the binary MSB inverts the TOP TWO bits of the Gray code.
// Testing the NEXT write pointer and registering it keeps wr_full a clean
// flop output instead of a long compare feeding the write enable.
wire full_next = (wgray_next ==
                    {~rgray_sync[ADDR_W:ADDR_W-1], rgray_sync[ADDR_W-2:0]});

// RAM write: no reset needed (RAM contents are don't-care until written).
// The RAM address is the pointer 
always_ff @(posedge wr_clk) begin
    if (do_write)
        mem[wbin[ADDR_W-1:0]] <= wr_data;
end

// Pointers and full flag: async assert, synchronous release.
always_ff @(posedge wr_clk or negedge wr_rst_sync_n) begin
    if (!wr_rst_sync_n) begin
        wbin     <= '0;
        wgray    <= '0;
        full_q   <= 1'b0;
        wr_count <= '0;
    end else begin
        wbin     <= wbin_next;
        wgray    <= wgray_next;
        full_q   <= full_next;
        wr_count <= wbin_next - gray2bin(rgray_sync);
    end
end

assign wr_full = full_q;
 


// READ DOMAIN

// Write pointer -> read clock 
cdc_sync #(.WIDTH(ADDR_W + 1)) u_sync_w2r (
    .clk   (rd_clk),
    .rst_n (rd_rst_sync_n),
    .d     (wgray),
    .q     (wgray_sync)
);

//  RAM has nothing left to fetch when the read pointer has caught up with
wire ram_empty = (rgray == wgray_sync);

// active when user takes word out of register
wire pop = rd_en && out_valid;
// active to refill output register from RAM when it is empty or being emptied
wire fetch = !ram_empty && (!out_valid || pop);

wire [ADDR_W:0] rbin_next = fetch ? rbin + 1'b1 : rbin;
wire [ADDR_W:0] rgray_next = bin2gray(rbin_next);

// Registered RAM read with an enable
always_ff @(posedge rd_clk) begin
    if (fetch)
        rd_data <= mem[rbin[ADDR_W-1:0]];
end

// Pointers and valid flag: async assert, synchronous release.
always_ff @(posedge rd_clk or negedge rd_rst_sync_n) begin
    if (!rd_rst_sync_n) begin
        rbin      <= '0;
        rgray     <= '0;
        out_valid <= 1'b0;
        rd_count  <= '0;
    end else begin
        rbin      <= rbin_next;
        rgray     <= rgray_next;
        out_valid <= fetch || (out_valid && !pop);
        rd_count  <= (gray2bin(wgray_sync) - rbin_next) + ((fetch || (out_valid && !pop)) ? 1'b1 : 1'b0);
    end
end

assign rd_empty = !out_valid;
 
endmodule