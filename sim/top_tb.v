`timescale 1ns / 1ps

module top_tb;

    reg clk = 0;
    reg [1:0] btn = 2'b11; // Buttons idle high (active-low)
    wire [5:0] led;

    // Instantiate Unit Under Test
    top uut (
        .clk(clk),
        .btn(btn),
        .led(led)
    );

    // 27 MHz reference clock (period = 37.037 ns, half-period = 18.5185 ns)
    always #18.5185 clk = ~clk;

    realtime t_start, t_period;
    real freq_mhz;

    initial begin
        $dumpfile("build/top_tb.vcd");
        $dumpvars(0, top_tb);

   
        // 1. Wait for PLL lock
        $display("[TB] Waiting for PLL to achieve lock...");
        wait(uut.pll_locked == 1'b1);
        $display("[TB] PLL locked at time %0t ps (LED[0] = %b - active low ON)", $time, led[0]);

        // 2. Measure PLL pixel clock period & calculate frequency
        @(posedge uut.clk_pixel);
        t_start = $realtime;
        @(posedge uut.clk_pixel);
        t_period = $realtime - t_start;
        freq_mhz = 1000.0 / t_period;

        $display("[TB] Measured Pixel Clock Period: %0.3f ns", t_period);
        $display("[TB] Measured Pixel Frequency:    %0.2f MHz (Target: 74.25 MHz)", freq_mhz);

        if (freq_mhz >= 73.0 && freq_mhz <= 75.5) begin
            $display("[TB] PASS: Clock frequency matches 720p pixel clock requirement!");
        end else begin
            $display("[TB] FAIL: Clock frequency out of acceptable bounds!");
        end

        // 3. Test PLL Reset via Button S1 (btn[0])
        #100;
        $display("[TB] Pressing Button S1 to reset PLL...");
        btn[0] = 1'b0; // Active-low press
        #50;
        if (uut.pll_locked == 1'b0) begin
            $display("[TB] PASS: PLL successfully entered reset (locked = 0)");
        end else begin
            $display("[TB] FAIL: PLL did not enter reset!");
        end

        // 4. Release Button S1 and verify re-lock
        #100;
        $display("[TB] Releasing Button S1...");
        btn[0] = 1'b1;
        wait(uut.pll_locked == 1'b1);
        $display("[TB] PASS: PLL successfully re-locked! (time: %0t ps)", $time);


        $finish;
    end

endmodule
