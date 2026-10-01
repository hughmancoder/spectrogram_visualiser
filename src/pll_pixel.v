`default_nettype none

/*
 Pixel Clock PLL Module for Tang Nano 20K (Gowin GW2AR-18)
 Refer to gowin clock user guide section 7
 
 Input:  27.0 MHz onboard crystal oscillator (pin 4)
 Output: 74.25 MHz pixel clock (720p 1280x720 @ 60Hz)
 
 rPLL Parameters for 74.25 MHz:
   - FCLKIN    = "27.0"
   - IDIV_SEL  = 3   (divide by 4 -> PFD = 6.75 MHz, range: 3-500 MHz)
   - FBDIV_SEL = 10  (multiply by 11 -> CLKOUT = 74.25 MHz)
   - ODIV_SEL  = 8   (VCO = 594.0 MHz, range: 500-1250 MHz)

Frequency multiplication factor: (1 + FBDIV_SEL) / (IDIV_SEL + 1) * 2 = (1 + 10) / (3 + 1) * 2 = 11 / 4 * 2 = 5.5
This is documented in page 37 of the user guide

Ports:
clk_in: Connected to the 27 MHz crystal oscillator on the board.
rst: Allows your system to hold the PLL in reset (e.g. via a button or power-on logic).
clk_out: The new, accelerated clock driving the video sync and pixel generation pipeline.
locked: Analog PLLs take a few microseconds to synchronize after power-on or reset. locked stays 0 while the frequency is unstable, and asserts 1 when the clock is steady and safe for the rest of your FPGA logic to use.
 */

module pll_pixel (
    input  wire clk_in,   
    input  wire rst,     
    output wire clk_out, 
    output wire locked   
);

`ifdef __ICARUS__
    reg clk_sim = 1'b0;
    reg lock_sim = 1'b0;

    // 74.25 MHz: period = 13.468 ns;  half-period ~ 6.734 ns
    always #6.734 clk_sim = ~clk_sim;

    initial begin
        lock_sim = 1'b0;
        #100; // PLL lock time delay
        lock_sim = 1'b1;
    end

    assign clk_out = (rst) ? 1'b0 : clk_sim;
    assign locked  = (rst) ? 1'b0 : lock_sim;

`else
   
    rPLL #(
        .FCLKIN("27.0"),
        .DEVICE("GW2AR-18C"),
        .IDIV_SEL(3),      // PFD = 27 / 4 = 6.75 MHz
        .FBDIV_SEL(10),    // CLKOUT = 6.75 11 = 74.25 MHz
        .ODIV_SEL(8),      // VCO = 74.25 8 = 594 MHz
        .DYN_IDIV_SEL("false"),
        .DYN_FBDIV_SEL("false"),
        .DYN_ODIV_SEL("false"),
        .DYN_DA_EN("false")
    ) pll_inst (
        .CLKIN(clk_in),
        .CLKOUT(clk_out),
        .LOCK(locked),
        .CLKOUTP(),
        .CLKOUTD(),
        .CLKOUTD3(),
        .RESET(rst),
        .RESET_P(1'b0),
        .CLKFB(1'b0),
        .FBDSEL(6'b0),
        .IDSEL(6'b0),
        .ODSEL(6'b0),
        .PSDA(4'b0),
        .DUTYDA(4'b0),
        .FDLY(4'b0)
    );
`endif

endmodule

`default_nettype wire
