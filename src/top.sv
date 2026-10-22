

module top (
    input  wire       clk,      // 27 MHz  crystal oscillator
    input  wire [1:0] btn,      // Onboard buttons (active-low: 0 = pressed)
    
    // HDMI / TMDS Outputs
    output wire       tmds_clk_p,
    output wire       tmds_clk_n,
    output wire [2:0] tmds_data_p,
    output wire [2:0] tmds_data_n,

    output wire [5:0] led       // Onboard LEDs (active-low: )
);

    // Clock Generation
    wire clk_pixel;   // 74.25 MHz
    wire clk_serial;  // 371.25 MHz
    wire pll_locked;
    wire pll_rst = 1'b0; 

    pll_pixel u_pll (
        .clk_in     (clk),
        .rst        (pll_rst),
        .pixel_clk  (clk_pixel),
        .serial_clk (clk_serial),
        .locked     (pll_locked)
    );

    // Video Sync and Timing Generation
    wire hsync, vsync, de;
    wire [11:0] pixel_x;
    wire [11:0] pixel_y;

    video_sync u_sync (
        .clk     (clk_pixel),
        .rst_n   (pll_locked),
        .hsync   (hsync),
        .vsync   (vsync),
        .de      (de),
        .pixel_x (pixel_x),
        .pixel_y (pixel_y)
    );

    // Test Pattern Generation 
    wire [7:0] red   = de ? (pixel_x[5] ^ pixel_y[5] ? 8'hFF : 8'h00) : 8'h00;
    wire [7:0] green = de ? pixel_x[7:0] : 8'h00;
    wire [7:0] blue  = de ? pixel_y[7:0] : 8'h00;

    // TMDS Encoding for HDMI
    hdmi_tx u_hdmi (
        .pixel_clk   (clk_pixel),
        .serial_clk  (clk_serial),
        .rst_n       (pll_locked),
        
        .red         (red),
        .green       (green),
        .blue        (blue),
        .hsync       (hsync),
        .vsync       (vsync),
        .de          (de),
        
        .tmds_clk_p  (tmds_clk_p),
        .tmds_clk_n  (tmds_clk_n),
        .tmds_data_p (tmds_data_p),
        .tmds_data_n (tmds_data_n)
    );

    // LED Blinker
    reg [25:0] pixel_counter = 26'd0;
    always @(posedge clk_pixel or negedge pll_locked) begin
        if (!pll_locked) begin
            pixel_counter <= 26'd0;
        end else begin
            pixel_counter <= pixel_counter + 1'b1;
        end
    end
    wire pixel_blink = pixel_counter[25];

    reg [24:0] ref_counter = 25'd0;
    always @(posedge clk) begin
        ref_counter <= ref_counter + 1'b1;
    end
    wire ref_blink = ref_counter[24];    
endmodule
