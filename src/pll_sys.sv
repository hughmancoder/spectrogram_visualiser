`default_nettype none

/*
 System / SDRAM Clock PLL for Tang Nano 20K (Gowin GW2AR-18)

 Input:  27.0 MHz onboard crystal
 Output:
   - sys_clk   : 64.8 MHz  (SDRAM controller + framebuffer system domain)
   - sdram_clk : 64.8 MHz, phase shifted 180 deg -> drive O_sdram_clk

   CLKOUT = 27 * (FBDIV_SEL + 1) / (IDIV_SEL + 1) = 27 * 12 / 5 = 64.8 MHz
   PFD    = 27 / 5 = 5.4 MHz
   VCO    = 64.8 * 8 (ODIV_SEL) = 518.4 MHz   (valid range 500 - 1250 MHz)
   (values from: gowin_pll -d GW2AR-LV18QN88C8/I7 -i 27 -o 64.8)

 CLKOUTP phase: PSDA_SEL in 22.5 deg steps -> "1000" = 8 * 22.5 = 180 deg.

 Why 180 deg? Commands/data change on the rising edge of sys_clk; the SDRAM
 samples them on the rising edge of sdram_clk, i.e. half a cycle later, which
 centres the sampling point in the data valid window.

 Why 64.8 MHz? It is a known-good frequency for the embedded SDRAM with
 simple controllers, and still gives ~2x the bandwidth needed for a
 1280x720 RGB565 framebuffer when using 32-word bursts.
*/

module pll_sys (
    input  wire clk_in,      // 27 MHz
    input  wire rst,
    output wire sys_clk,     // 64.8 MHz
    output wire sdram_clk,   // 64.8 MHz, 180 deg
    output wire locked
);

`ifdef __ICARUS__
    reg clk_sim  = 1'b0;
    reg lock_sim = 1'b0;

    // 64.8 MHz: period 15.432 ns
    always #7.716 clk_sim = ~clk_sim;

    initial begin
        lock_sim = 1'b0;
        #150;
        lock_sim = 1'b1;
    end

    assign sys_clk   = rst ? 1'b0 : clk_sim;
    assign sdram_clk = rst ? 1'b1 : ~clk_sim;
    assign locked    = rst ? 1'b0 : lock_sim;

`else
    rPLL #(
        .FCLKIN("27"),
        .DEVICE("GW2AR-18C"),
        .IDIV_SEL(4),          // PFD = 27 / 5 = 5.4 MHz
        .FBDIV_SEL(11),        // CLKOUT = 5.4 * 12 = 64.8 MHz
        .ODIV_SEL(8),          // VCO = 64.8 * 8 = 518.4 MHz
        .DYN_IDIV_SEL("false"),
        .DYN_FBDIV_SEL("false"),
        .DYN_ODIV_SEL("false"),
        .PSDA_SEL("1000"),     // CLKOUTP = 180 deg
        .DYN_DA_EN("false"),
        .DUTYDA_SEL("1000"),
        .CLKFB_SEL("internal"),
        .CLKOUT_FT_DIR(1'b1),
        .CLKOUTP_FT_DIR(1'b1),
        .CLKOUT_DLY_STEP(0),
        .CLKOUTP_DLY_STEP(0),
        .CLKOUT_BYPASS("false"),
        .CLKOUTP_BYPASS("false"),
        .CLKOUTD_BYPASS("false"),
        .DYN_SDIV_SEL(2),
        .CLKOUTD_SRC("CLKOUT"),
        .CLKOUTD3_SRC("CLKOUT")
    ) pll_inst (
        .CLKIN   (clk_in),
        .CLKOUT  (sys_clk),
        .CLKOUTP (sdram_clk),
        .CLKOUTD (),
        .CLKOUTD3(),
        .LOCK    (locked),
        .RESET   (rst),
        .RESET_P (1'b0),
        .CLKFB   (1'b0),
        .FBDSEL  (6'b0),
        .IDSEL   (6'b0),
        .ODSEL   (6'b0),
        .PSDA    (4'b0),
        .DUTYDA  (4'b0),
        .FDLY    (4'b0)
    );
`endif

endmodule

`default_nettype wire
