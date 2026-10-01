`default_nettype none

module top (
    input  wire       clk,      // 27 MHz onboard crystal oscillator
    input  wire [1:0] btn,      // Onboard buttons (active-low: 0 = pressed)
    output wire [5:0] led       // Onboard LEDs (active-low: 0 = lit)
);

    // -------------------------------------------------------------------------
    // PLL Instantiation: Generate 74.25 MHz pixel clock from 27 MHz crystal
    // -------------------------------------------------------------------------
    wire clk_pixel;
    wire pll_locked;
    wire pll_rst = ~btn[0];     // Press S1 (btn[0]) to hold PLL in reset

    pll_pixel u_pll (
        .clk_in  (clk),
        .rst     (pll_rst),
        .clk_out (clk_pixel),
        .locked  (pll_locked)
    );

    // -------------------------------------------------------------------------
    // Test Blinker 1: Driven by 74.25 MHz Pixel Clock (Proves PLL oscillation)
    // -------------------------------------------------------------------------
    reg [25:0] pixel_counter = 26'd0;
    always @(posedge clk_pixel or negedge pll_locked) begin
        if (!pll_locked) begin
            pixel_counter <= 26'd0;
        end else begin
            pixel_counter <= pixel_counter + 1'b1;
        end
    end
    wire pixel_blink = pixel_counter[25]; // Toggles at ~1.1 Hz (74.25 MHz / 2^26)

    // -------------------------------------------------------------------------
    // Test Blinker 2: Driven by 27.0 MHz Reference Clock (For visual comparison)
    // -------------------------------------------------------------------------
    reg [24:0] ref_counter = 25'd0;
    always @(posedge clk) begin
        ref_counter <= ref_counter + 1'b1;
    end
    wire ref_blink = ref_counter[24];     // Toggles at ~0.8 Hz (27 MHz / 2^25)

    // -------------------------------------------------------------------------
    // LED Mapping (Tang Nano 20K LEDs are active-low: 0 = LIT, 1 = OFF)
    // -------------------------------------------------------------------------
    // Bit 0: PLL Locked status (LIT when locked)
    // Bit 1: Pixel clock 74.25 MHz blinker (~1.1 Hz)
    // Bit 2: Reference 27.0 MHz blinker (~0.8 Hz)
    // Bit 3: Button S1 status (LIT when pressed -> resets PLL)
    // Bit 4: Button S2 status (LIT when pressed)
    // Bit 5: Board heartbeat / active indicator
    assign led = ~{
        1'b1,           // led[5]
        ~btn[1],        // led[4]
        ~btn[0],        // led[3]
        ref_blink,      // led[2]
        pixel_blink,    // led[1]
        pll_locked      // led[0]
    };

endmodule

`default_nettype wire
