`timescale 1ns / 1ps

module pll_pixel_tb;

    reg clk_in = 0;
    reg rst = 0;
    wire clk_out;
    wire locked;

    pll_pixel uut (
        .clk_in  (clk_in),
        .rst     (rst),
        .clk_out (clk_out),
        .locked  (locked)
    );

    // 27 MHz reference clock generator (half-period ~18.5185 ns)
    always #18.5185 clk_in = ~clk_in;

    realtime t1, t_period;
    real freq_mhz;

    initial begin
        $dumpfile("build/pll_pixel_tb.vcd");
        $dumpvars(0, pll_pixel_tb);

    
        @(posedge clk_out);
        t1 = $realtime;
        @(posedge clk_out);
        t_period = $realtime - t1;
        freq_mhz = 1000.0 / t_period;

        $display("[pll_pixel_tb] Measured Clock Period: %0.3f ns", t_period);
        $display("[pll_pixel_tb] Measured Frequency:    %0.2f MHz", freq_mhz);

        // Exact value check (with standard floating-point tolerance epsilon)
        if (freq_mhz < 74.24 || freq_mhz > 74.26) begin
            $display("[FAIL] Frequency mismatch! Expected 74.25 MHz, got %0.3f MHz", freq_mhz);
            $finish(1);
        end else begin
            $display("[PASS] Frequency matches expected 74.25 MHz");
        end

        #200;
        $display("[pll_pixel_tb] Asserting reset...");
        rst = 1'b1;
        #50;
        if (locked !== 1'b0) begin
            $display("[FAIL] Expected locked == 0 during reset, got %b", locked);
            $finish(1);
        end else begin
            $display("[pll_pixel_tb] PASS: PLL locked went low during reset.");
        end

        $finish;
    end

endmodule
