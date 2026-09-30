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

    // 27 MHz clock generator (half-period ~18.518 ns)
    always #18.518 clk = ~clk;

    initial begin
        $dumpfile("build/top_tb.vcd");
        $dumpvars(0, top_tb);

        $display("[TB] Starting simulation...");

        #200;
        $display("[TB] Pressing Button S1 (btn[0])...");
        btn[0] = 1'b0;
        #200;
        btn[0] = 1'b1;

        #200;
        $display("[TB] Pressing Button S2 (btn[1])...");
        btn[1] = 1'b0;
        #200;
        btn[1] = 1'b1;

        #500;
        $display("[TB] Simulation completed successfully!");
        $finish;
    end

endmodule
