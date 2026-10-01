`default_nettype none

/*
 Pixel Clock PLL Module for Tang Nano 20K (Gowin GW2AR-18)
 
 Input:  27.0 MHz onboard crystal oscillator (pin 4)
 Output: 
   - 371.25 MHz serial clock (720p 1280x720 @ 60Hz TMDS clock). Needed for HDMI
   - 74.25 MHz pixel clock
   - CLKOUT = CLK_IN * (FBDIV_SEL + 1) / (IDIV_SEL + 1)
   - 4 = IDIV_SEL + 1
   - 55 = FBDIV_SEL + 1
   - 2 = ODIV_SEL + 1
   - Serial clock: 27 * (55 / 4) * 2 = 371.25
    - Pixel clock = serial clock / CLKDIV = 371.25 / 5 = 74.25 MHz

rPLL Parameters for 371.25 MHz:
   - FCLKIN    = "27.0"
   - IDIV_SEL  = 3   (divide by 4 -> PFD = 6.75 MHz)
   - FBDIV_SEL = 54  (multiply by 55 -> CLKOUT = 371.25 MHz)
   - ODIV_SEL  = 2   (VCO = 371.25 * 2 = 742.5 MHz)
*/

module pll_pixel (
    input  wire clk_in,   
    input  wire rst,     
    output wire pixel_clk,
    output wire serial_clk,
    output wire locked   
);

`ifdef __ICARUS__
    reg clk_sim_serial = 1'b0;
    reg clk_sim_pixel = 1'b0;
    reg lock_sim = 1'b0;

    // 371.25 MHz: period = 2.6936 ns; half-period ~ 1.3468 ns
    always #1.3468 clk_sim_serial = ~clk_sim_serial;

    int div_cnt = 0;
    always @(posedge clk_sim_serial) begin
        if (div_cnt == 4) begin
            div_cnt <= 0;
            clk_sim_pixel <= 1'b1;
        end else if (div_cnt == 2) begin
            div_cnt <= div_cnt + 1;
            clk_sim_pixel <= 1'b0;
        end else begin
            div_cnt <= div_cnt + 1;
        end
    end

    initial begin
        lock_sim = 1'b0;
        #100;
        lock_sim = 1'b1;
    end

    assign serial_clk = (rst) ? 1'b0 : clk_sim_serial;
    assign pixel_clk  = (rst) ? 1'b0 : clk_sim_pixel;
    assign locked     = (rst) ? 1'b0 : lock_sim;

`else
    wire clk_serial;
    rPLL #(
        .FCLKIN("27"),
        .DEVICE("GW2AR-18C"),
        .IDIV_SEL(3),      // PFD = 27 / 4 = 6.75 MHz
        .FBDIV_SEL(54),    // CLKOUT = 6.75 * 55 = 371.25 MHz
        .ODIV_SEL(2),      // VCO = 371.25 * 2 = 742.5 MHz
        .DYN_IDIV_SEL("false"),
        .DYN_FBDIV_SEL("false"),
        .DYN_ODIV_SEL("false"),
        .DYN_DA_EN("true"),
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
        .CLKIN(clk_in),
        .CLKOUT(clk_serial),
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

    CLKDIV #(
        .DIV_MODE("5"),
        .GSREN("false")
    ) clkdiv_inst (
        .CLKOUT(pixel_clk),
        .HCLKIN(clk_serial),
        .RESETN(~rst & locked),
        .CALIB(1'b1)
    );

    assign serial_clk = clk_serial;
`endif

endmodule

`default_nettype wire
