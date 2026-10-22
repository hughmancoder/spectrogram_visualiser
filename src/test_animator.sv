`default_nettype none

module test_animator #(
    parameter int NUM_BARS       = 64,
    parameter int BAR_HEIGHT_MAX = 255,
    parameter int DATA_WIDTH     = 8
)(
    input  wire                          clk,
    input  wire                          rst_n,
    input  wire                          tick,

    input  wire [$clog2(NUM_BARS)-1:0]   bar_idx,
    output wire [DATA_WIDTH-1:0]         bar_level,

    output reg  [$clog2(NUM_BARS)-1:0]   write_addr,
    output reg  [DATA_WIDTH-1:0]         write_data,
    output reg                           write_en
);

    localparam int ADDR_WIDTH = $clog2(NUM_BARS);

    reg [DATA_WIDTH-1:0] bars [0:NUM_BARS-1];

    reg [7:0] frame_cnt;
    reg [7:0] bass_pulse;
    reg [5:0] sweep_pos;
    reg       sweep_dir;

    reg [ADDR_WIDTH-1:0] update_idx;
    reg                  updating;

    function automatic [7:0] tri_wave(input [7:0] phase);
        tri_wave = phase[7] ? (~phase[6:0] << 1) : (phase[6:0] << 1);
    endfunction

    wire [7:0] wave1 = tri_wave((update_idx << 2) + (frame_cnt << 2));
    wire [7:0] wave2 = tri_wave((update_idx << 3) - (frame_cnt << 1));

    wire [DATA_WIDTH-1:0] base_level = (DATA_WIDTH > 8) ? ((wave1 + wave2) >> 1) : ((wave1 + wave2) >> 2);
    wire [7:0]            bass_scale = (update_idx < 16) ? (16 - update_idx) : 8'd0;
    wire [DATA_WIDTH-1:0] bass_add   = (DATA_WIDTH > 8) ? (bass_scale * bass_pulse[7:4]) :
                                                          ((bass_scale * bass_pulse[7:4]) >> 1);

    wire [5:0] sweep_diff = (update_idx > sweep_pos) ? (update_idx - sweep_pos) : (sweep_pos - update_idx);
    wire [DATA_WIDTH-1:0] pulse_add = (DATA_WIDTH > 8) ?
        ((sweep_diff == 0) ? 9'd90 : (sweep_diff == 1) ? 9'd60 : (sweep_diff == 2) ? 9'd30 : 9'd0) :
        ((sweep_diff == 0) ? 8'd45 : (sweep_diff == 1) ? 8'd30 : (sweep_diff == 2) ? 8'd15 : 8'd0);

    wire [DATA_WIDTH-1:0] min_floor = (DATA_WIDTH > 8) ? 9'd16 : 8'd8;

    wire [DATA_WIDTH+1:0] raw_sum = base_level + bass_add + pulse_add + min_floor;
    wire [DATA_WIDTH-1:0] clamped_level = (raw_sum > BAR_HEIGHT_MAX[DATA_WIDTH-1:0]) ? BAR_HEIGHT_MAX[DATA_WIDTH-1:0] :
                                          (raw_sum < min_floor)                       ? min_floor :
                                          raw_sum[DATA_WIDTH-1:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            frame_cnt   <= 8'd0;
            bass_pulse  <= 8'd0;
            sweep_pos   <= 6'd0;
            sweep_dir   <= 1'b0;
            update_idx  <= '0;
            updating    <= 1'b0;
            write_en    <= 1'b0;
            write_addr  <= '0;
            write_data  <= '0;
        end else begin
            write_en <= 1'b0;

            if (tick && !updating) begin
                updating   <= 1'b1;
                update_idx <= '0;
                frame_cnt  <= frame_cnt + 1'b1;

                if (frame_cnt[4:0] == 5'd0)
                    bass_pulse <= 8'd180;
                else if (bass_pulse > 8'd6)
                    bass_pulse <= bass_pulse - 8'd6;

                if (!sweep_dir) begin
                    if (sweep_pos == 6'd63) sweep_dir <= 1'b1;
                    else sweep_pos <= sweep_pos + 1'b1;
                end else begin
                    if (sweep_pos == 6'd0) sweep_dir <= 1'b0;
                    else sweep_pos <= sweep_pos - 1'b1;
                end
            end else if (updating) begin
                bars[update_idx] <= clamped_level;
                write_addr       <= update_idx;
                write_data       <= clamped_level;
                write_en         <= 1'b1;

                if (update_idx == NUM_BARS - 1) begin
                    updating <= 1'b0;
                end else begin
                    update_idx <= update_idx + 1'b1;
                end
            end
        end
    end

    assign bar_level = bars[bar_idx];

endmodule

`default_nettype wire
