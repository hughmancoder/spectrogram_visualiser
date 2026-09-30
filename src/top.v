`default_nettype none

module top (
    input  wire       clk,      // 27 MHz onboard clock
    input  wire [1:0] btn,      // Onboard buttons (active-low: 0 = pressed)
    output wire [5:0] led       // Onboard LEDs (active-low: 0 = lit)
);

    
    wire [5:0] led_status;
    assign led_status[0]   = btn[0];
    assign led_status[1]   = btn[1];
    

    assign led = ~led_status;

endmodule

`default_nettype wire
