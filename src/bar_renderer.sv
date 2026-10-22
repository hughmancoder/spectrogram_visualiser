module bar_renderer #(
    parameter int NUM_BARS   = 64,
    parameter int BAR_WIDTH  = 20,
    parameter int GAP_WIDTH  = 4,
    parameter int Y_BOTTOM   = 450,  // Baseline Y coordinate
    parameter int MAX_HEIGHT = 256,  // Max bar height in pixels
    parameter int CAP_HEIGHT = 3     // Peak indicator thickness
)(
    input  logic        clk,         // Pixel clock
    input  logic        rst_n,       // active low
    
    // Video timing inputs
    input  logic [11:0] pixel_x,
    input  logic [11:0] pixel_y,
    input  logic        active_video, // Active inside 1280x720 box
    input  logic        frame_tick,  // Pulses high for 1 clk once per frame 

    // Interface to bar_levels memory
    input  logic [7:0]                  bar_data, // Current height of bar_addr
    output logic [$clog2(NUM_BARS)-1:0] bar_addr, // for 6 bars

    // RGB Output
    output logic [23:0] rgb_out // 8-bit RGB streams
);

    localparam logic [23:0] RED    = 24'hFF0000;
    localparam logic [23:0] GREEN  = 24'h00FF00;
    localparam logic [23:0] YELLOW = 24'hFFFF00;
    localparam logic [23:0] WHITE  = 24'hFFFFFF;
    localparam logic [23:0] BLACK  = 24'h000000;

    localparam int THRESH_YELLOW = MAX_HEIGHT / 3;       
    localparam int THRESH_RED    = (MAX_HEIGHT * 2) / 3; 
    localparam int SOLID_WIDTH   = BAR_WIDTH - GAP_WIDTH; 

    // Horizontal Tracking (Running counter method for 20px pitch)
    // 64 x 20 = 1280
    logic [$clog2(NUM_BARS):0] current_bar_idx;
    logic [$clog2(BAR_WIDTH)-1:0] sub_bar_x;
    logic in_gap;

    assign bar_addr = current_bar_idx;
    assign in_gap   = (sub_bar_x >= SOLID_WIDTH);


    always_ff @(posedge clk) begin
        if (!rst_n || !active_video) begin
            current_bar_idx <= 0;
            sub_bar_x       <= 0;
        end else begin
            if (sub_bar_x == BAR_WIDTH - 1) begin
                sub_bar_x <= 0;
                current_bar_idx <= current_bar_idx + 1'b1;
            end else begin
                sub_bar_x <= sub_bar_x + 1;
            end
        end
    end
    

    
    // Introduce 1 cycle delay to match BRAM read latency to sync with bar_addr
    logic                         in_gap_d1;
    logic [11:0]                  pixel_y_d1;
    logic                         active_video_d1;
    logic [$clog2(NUM_BARS)-1:0]  bar_idx_d1;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            in_gap_d1       <= 1'b1;
            pixel_y_d1      <= '0;
            active_video_d1 <= 1'b0;
            bar_idx_d1      <= '0;
        end else begin
            in_gap_d1       <= in_gap;
            pixel_y_d1      <= pixel_y;
            active_video_d1 <= active_video;
            bar_idx_d1      <= current_bar_idx;
        end
    end

    // stores the height of the floating cap for each bar
    logic [7:0] peak_levels [0:NUM_BARS-1];
    logic [1:0] decay_timer;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            decay_timer <= '0;
            for (int i = 0; i < NUM_BARS; i++) begin
                peak_levels[i] <= '0;
            end
        end else begin
            // Once every 3 frames / 20 px/s, gently float all caps downward
            if (frame_tick) begin
                if (decay_timer == 2'd2) begin
                    decay_timer <= '0;
                    for (int i = 0; i < NUM_BARS; i++) begin
                        if (peak_levels[i] > 8'd0) begin
                            peak_levels[i] <= peak_levels[i] - 8'd1;
                        end
                    end
                end else begin
                    decay_timer <= decay_timer + 2'd1;
                end
            end else if (active_video_d1 && (bar_data > peak_levels[bar_idx_d1])) begin
                peak_levels[bar_idx_d1] <= bar_data;
            end
        end
    end

    logic [7:0] current_peak;
    assign current_peak = peak_levels[bar_idx_d1];


    // vertical calculation and colour picker
    logic        above_floor;
    logic [11:0] dist_from_bottom;
    logic        is_peak_cap;
    logic        is_bar_lit;

    assign above_floor      = (pixel_y_d1 <= Y_BOTTOM);
    assign dist_from_bottom = above_floor ? (Y_BOTTOM - pixel_y_d1) : 12'd0;

    always_ff @(posedge clk) begin
        if (!rst_n || !active_video_d1) begin
            rgb_out <= BLACK;
        // peak cap
        end else if ((!in_gap_d1) && above_floor &&
                         (current_peak > 8'd0) &&
                         (dist_from_bottom >= current_peak) &&
                         (dist_from_bottom <  current_peak + CAP_HEIGHT)) begin
            rgb_out <= WHITE;
        // bar lit
        end else if ((!in_gap_d1) && above_floor &&
                         (bar_data > 8'd0) &&
                         (dist_from_bottom <= bar_data)) begin
            if (dist_from_bottom >= THRESH_RED) begin
                rgb_out <= RED;
            end else if (dist_from_bottom >= THRESH_YELLOW) begin
                rgb_out <= YELLOW;
            end else begin
                rgb_out <= GREEN;
            end
        end else begin
            rgb_out <= BLACK;
        end
    end

endmodule
