`default_nettype none

/*
 Framebuffer package

 Shared definitions for the SDRAM framebuffer:

 - Pixel format: RGB565, two pixels packed per 32-bit SDRAM word
       word[15:0]  = even pixel (x)
       word[31:16] = odd pixel  (x + 1)
 - Phase 2 test pattern ("counter gradient"): a pure function of (x, y) so the
   writer (pattern_gen), the on-chip checker (top) and the testbenches all
   agree on what the screen should look like.

       R5 = (x * R_MUL) >> 11      R_MUL = 65536 / H_ACTIVE   (0..31 across screen)
       G6 = (y * G_MUL) >> 10      G_MUL = 65536 / V_ACTIVE   (0..63 down screen)
       B5 = 31 - R5

   For 1280x720 this is a smooth full-range gradient. For tiny simulation
   resolutions (e.g. 32x64) every pixel gets a unique colour, which lets the
   testbenches catch addressing / word-ordering bugs.
*/

package fb_pkg;

    // Embedded SDRAM geometry (GW2AR-18: 64 Mbit = 4 banks x 2048 rows x 256 cols x 32 bit)
    localparam int SDRAM_ADDR_W = 21;   // word address = {row[10:0], bank[1:0], col[7:0]}
    localparam int SDRAM_DATA_W = 32;

    // Gradient test pattern for a single pixel
    function automatic logic [15:0] gradient_rgb565(
        input logic [11:0] x,
        input logic [11:0] y,
        input logic [16:0] r_mul,
        input logic [16:0] g_mul
    );
        logic [31:0] r_full;
        logic [31:0] g_full;
        logic [4:0]  r5;
        logic [5:0]  g6;
        logic [4:0]  b5;
        r_full = {20'd0, x} * {15'd0, r_mul};
        g_full = {20'd0, y} * {15'd0, g_mul};
        r5 = r_full[15:11];
        g6 = g_full[15:10];
        b5 = 5'd31 - r5;
        gradient_rgb565 = {r5, g6, b5};
    endfunction

    // Expand RGB565 to RGB888 by bit replication (keeps full-scale white at FF)
    function automatic logic [23:0] rgb565_to_rgb888(input logic [15:0] p);
        rgb565_to_rgb888 = {p[15:11], p[15:13],   // R
                            p[10:5],  p[10:9],    // G
                            p[4:0],   p[4:2]};    // B
    endfunction

endpackage

`default_nettype wire
