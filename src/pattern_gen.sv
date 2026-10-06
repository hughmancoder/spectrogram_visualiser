`default_nettype none

/*
 Test Pattern Writer

 Writes one full frame of the "counter gradient" (fb_pkg::gradient_rgb565)
 into the framebuffer through its write port, then asserts `done`.

 Word n (n = 0 .. H*V/2 - 1) is written to SDRAM word address n and holds two
 RGB565 pixels:  {pixel(x+1, y), pixel(x, y)}  with x even.

 Runs in the producer clock domain (any clock — it talks to the framebuffer's
 write FIFO). Writes one word per cycle while wp_ready is high.
*/

module pattern_gen #(
    parameter int H_ACTIVE = 1280,
    parameter int V_ACTIVE = 720
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,          // level: begin writing once high

    output wire        wp_valid,
    input  wire        wp_ready,
    output wire [20:0] wp_addr,
    output wire [31:0] wp_data,

    output logic       done
);

    localparam logic [16:0] R_MUL = 17'(65536 / H_ACTIVE);
    localparam logic [16:0] G_MUL = 17'(65536 / V_ACTIVE);

    logic [11:0] x, y;
    logic [20:0] addr;
    logic        running;

    assign wp_valid = running;
    assign wp_addr  = addr;
    assign wp_data  = {fb_pkg::gradient_rgb565(x + 12'd1, y, R_MUL, G_MUL),
                       fb_pkg::gradient_rgb565(x,         y, R_MUL, G_MUL)};

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x       <= '0;
            y       <= '0;
            addr    <= '0;
            running <= 1'b0;
            done    <= 1'b0;
        end else if (!running && !done) begin
            running <= start;
        end else if (running && wp_ready) begin
            addr <= addr + 1'b1;
            if (x == 12'(H_ACTIVE - 2)) begin
                x <= '0;
                if (y == 12'(V_ACTIVE - 1)) begin
                    running <= 1'b0;
                    done    <= 1'b1;
                end else begin
                    y <= y + 1'b1;
                end
            end else begin
                x <= x + 12'd2;
            end
        end
    end

endmodule

`default_nettype wire
