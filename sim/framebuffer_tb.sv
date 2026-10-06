`timescale 1ns / 1ps

/*
 framebuffer testbench (Phase 2 integration)

 Full read/write path at a small resolution so it simulates in seconds:

   pattern_gen --(wp_clk 50 MHz)--> [write FIFO] --+
                                                   +--> sdram_ctrl <--> sdram_model
   pixel out <--(pix_clk 74.25 MHz)-- [read FIFO] --+         (sys_clk 64.8 MHz)

 Three unrelated clocks, so both CDC FIFOs are exercised for real.
 The frame (32 x 64 = 1024 words) is larger than the 512-word read FIFO, so
 the read engine's flow control is exercised too.

   T1 SDRAM init + pattern written
   T2 two consecutive frames: every pixel == fb_pkg::gradient_rgb565(x, y),
      exactly H*V pixels per frame, no underflow
   T3 live update while displaying: rewrite 4 lines (inverted) through the
      write port, the next frames must show the change and nothing else
   T4 SDRAM protocol errors == 0

 Run:  make sim TB=framebuffer_tb
*/

module framebuffer_tb;
    import fb_pkg::*;

    // ------------------------------------------------------------------
    // Small video mode
    // ------------------------------------------------------------------
    localparam int H_ACTIVE = 32, H_FP = 4, H_SYNC = 4, H_BP = 8;    // 48 clocks / line
    localparam int V_ACTIVE = 64, V_FP = 2, V_SYNC = 3, V_BP = 4;    // 73 lines / frame
    localparam int BURST_LEN  = 32;
    localparam int INIT_US    = 10;
    localparam int WORDS_LINE = H_ACTIVE / 2;

    localparam logic [16:0] R_MUL = 17'(65536 / H_ACTIVE);
    localparam logic [16:0] G_MUL = 17'(65536 / V_ACTIVE);

    // Live-update region (T3)
    localparam int UPD_Y0 = 10, UPD_LINES = 4;

    // ------------------------------------------------------------------
    // Clocks
    // ------------------------------------------------------------------
    logic pix_clk = 0, sys_clk = 0, wp_clk = 0;
    always #6.734 pix_clk = ~pix_clk;   // 74.25 MHz
    always #7.716 sys_clk = ~sys_clk;   // 64.8  MHz
    always #10.0  wp_clk  = ~wp_clk;    // 50    MHz

    wire sdram_clk_dev;
    assign #1.5 sdram_clk_dev = ~sys_clk;   // 180 deg + 1.5 ns board delay

    // ------------------------------------------------------------------
    // Resets
    // ------------------------------------------------------------------
    logic arst_n = 0;
    wire  pix_rst_n, sys_rst_n, wp_rst_n;
    reset_sync u_rs_pix (.clk(pix_clk), .arst_n(arst_n), .rst_n(pix_rst_n));
    reset_sync u_rs_sys (.clk(sys_clk), .arst_n(arst_n), .rst_n(sys_rst_n));
    reset_sync u_rs_wp  (.clk(wp_clk),  .arst_n(arst_n), .rst_n(wp_rst_n));

    // ------------------------------------------------------------------
    // Video timing
    // ------------------------------------------------------------------
    wire        hsync, vsync, de;
    wire [11:0] pixel_x, pixel_y;

    video_sync #(
        .H_ACTIVE(H_ACTIVE), .H_FRONT_PORCH(H_FP), .H_SYNC_PULSE(H_SYNC), .H_BACK_PORCH(H_BP),
        .V_ACTIVE(V_ACTIVE), .V_FRONT_PORCH(V_FP), .V_SYNC_PULSE(V_SYNC), .V_BACK_PORCH(V_BP)
    ) u_sync (
        .clk(pix_clk), .rst_n(pix_rst_n),
        .hsync(hsync), .vsync(vsync), .de(de),
        .pixel_x(pixel_x), .pixel_y(pixel_y)
    );

    // ------------------------------------------------------------------
    // Producer: pattern_gen, then the testbench takes over the write port
    // ------------------------------------------------------------------
    wire        pg_valid, pg_done;
    wire [20:0] pg_addr;
    wire [31:0] pg_data;

    logic        tb_wp_active = 0;
    logic        tb_valid = 0;
    logic [20:0] tb_addr  = '0;
    logic [31:0] tb_data  = '0;

    wire        wp_valid = tb_wp_active ? tb_valid : pg_valid;
    wire [20:0] wp_addr  = tb_wp_active ? tb_addr  : pg_addr;
    wire [31:0] wp_data  = tb_wp_active ? tb_data  : pg_data;
    wire        wp_ready;

    pattern_gen #(.H_ACTIVE(H_ACTIVE), .V_ACTIVE(V_ACTIVE)) u_pg (
        .clk(wp_clk), .rst_n(wp_rst_n), .start(1'b1),
        .wp_valid(pg_valid), .wp_ready(wp_ready && !tb_wp_active),
        .wp_addr(pg_addr), .wp_data(pg_data), .done(pg_done)
    );

    // ------------------------------------------------------------------
    // DUT: framebuffer + SDRAM controller + SDRAM model
    // ------------------------------------------------------------------
    wire        req_valid, req_ready, req_we;
    wire [20:0] req_addr;
    wire [31:0] wr_data, rd_data;
    wire        wr_data_ack, rd_data_valid, init_done;
    wire [15:0] pixel;
    wire        underflow;

    framebuffer #(
        .H_ACTIVE(H_ACTIVE), .V_ACTIVE(V_ACTIVE), .BURST_LEN(BURST_LEN)
    ) dut (
        .arst_n       (arst_n),
        .sys_clk      (sys_clk),
        .sdram_ready  (init_done),
        .req_valid    (req_valid),
        .req_ready    (req_ready),
        .req_we       (req_we),
        .req_addr     (req_addr),
        .wr_data      (wr_data),
        .wr_data_ack  (wr_data_ack),
        .rd_data      (rd_data),
        .rd_data_valid(rd_data_valid),
        .pix_clk      (pix_clk),
        .vsync        (vsync),
        .de           (de),
        .pixel        (pixel),
        .underflow    (underflow),
        .wp_clk       (wp_clk),
        .wp_valid     (wp_valid),
        .wp_ready     (wp_ready),
        .wp_addr      (wp_addr),
        .wp_data      (wp_data)
    );

    wire        sdram_cke, sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n;
    wire [10:0] sdram_addr;
    wire [1:0]  sdram_ba;
    wire [3:0]  sdram_dqm;
    wire [31:0] sdram_dq;

    sdram_ctrl #(
        .CLK_FREQ_HZ(64_800_000), .BURST_LEN(BURST_LEN), .INIT_WAIT_US(INIT_US)
    ) u_ctrl (
        .clk(sys_clk), .rst_n(sys_rst_n),
        .req_valid(req_valid), .req_ready(req_ready), .req_we(req_we), .req_addr(req_addr),
        .wr_data(wr_data), .wr_data_ack(wr_data_ack),
        .rd_data(rd_data), .rd_data_valid(rd_data_valid),
        .init_done(init_done),
        .sdram_cke(sdram_cke), .sdram_cs_n(sdram_cs_n), .sdram_ras_n(sdram_ras_n),
        .sdram_cas_n(sdram_cas_n), .sdram_we_n(sdram_we_n),
        .sdram_addr(sdram_addr), .sdram_ba(sdram_ba), .sdram_dqm(sdram_dqm), .sdram_dq(sdram_dq)
    );

    sdram_model #(.T_IO(2.0), .T_INIT_NS(INIT_US * 1000.0)) u_sdram (
        .clk(sdram_clk_dev), .cke(sdram_cke), .cs_n(sdram_cs_n), .ras_n(sdram_ras_n),
        .cas_n(sdram_cas_n), .we_n(sdram_we_n), .addr(sdram_addr), .ba(sdram_ba),
        .dqm(sdram_dqm), .dq(sdram_dq)
    );

    // ------------------------------------------------------------------
    // Pixel checker (samples on negedge: de, pixel_x/y and pixel are stable)
    // ------------------------------------------------------------------
    int  errors = 0;
    bit  checking = 0;
    bit  expect_update = 0;
    int  frame_pixels = 0, frame_mismatch = 0, frame_underflow = 0;
    int  frames = 0;

    task automatic fail(input string msg);
        errors++;
        if (errors <= 25) $display("  -> FAIL @ %0t: %s", $realtime, msg);
    endtask

    function automatic logic [15:0] expected_pixel(input int x, input int y);
        logic [15:0] p;
        p = gradient_rgb565(12'(x), 12'(y), R_MUL, G_MUL);
        if (expect_update && y >= UPD_Y0 && y < UPD_Y0 + UPD_LINES) p = ~p;
        expected_pixel = p;
    endfunction

    always @(negedge pix_clk) begin
        if (checking && de) begin
            logic [15:0] e;
            e = expected_pixel(pixel_x, pixel_y);
            frame_pixels++;
            if (underflow) frame_underflow++;
            else if (pixel !== e) begin
                frame_mismatch++;
                if (frame_mismatch <= 5)
                    fail($sformatf("pixel (%0d,%0d) = %h, expected %h", pixel_x, pixel_y, pixel, e));
            end
        end
    end

    // Check exactly one frame: from the end of vsync to the next vsync
    task automatic check_frame(input string name);
        @(posedge vsync);
        @(negedge vsync);
        frame_pixels = 0; frame_mismatch = 0; frame_underflow = 0;
        checking = 1;
        @(posedge vsync);
        checking = 0;
        frames++;
        if (frame_pixels != H_ACTIVE * V_ACTIVE)
            fail($sformatf("%s: %0d pixels in frame, expected %0d", name, frame_pixels, H_ACTIVE * V_ACTIVE));
        if (frame_underflow != 0)
            fail($sformatf("%s: %0d underflow pixels", name, frame_underflow));
        if (frame_mismatch == 0 && frame_underflow == 0 && frame_pixels == H_ACTIVE * V_ACTIVE)
            $display("  -> PASS: %s (%0d pixels correct)", name, frame_pixels);
        else
            $display("  -> FAIL: %s (%0d mismatches, %0d underflows)", name, frame_mismatch, frame_underflow);
    endtask

    // Write one word through the write port from the producer domain
    task automatic tb_write(input logic [20:0] a, input logic [31:0] d);
        @(negedge wp_clk);
        tb_valid = 1; tb_addr = a; tb_data = d;
        @(posedge wp_clk);
        while (!wp_ready) @(posedge wp_clk);
        #0.1 tb_valid = 0;
    endtask

    // ------------------------------------------------------------------
    // Main sequence
    // ------------------------------------------------------------------
    realtime t0;
    initial begin
        if (!$test$plusargs("nodump")) begin
            $dumpfile("build/framebuffer_tb.vcd");
            $dumpvars(0, framebuffer_tb);
        end

        $display("==================================================================");
        $display(" [TESTBENCH] framebuffer  (%0dx%0d, BURST_LEN=%0d)", H_ACTIVE, V_ACTIVE, BURST_LEN);
        $display("==================================================================");

        #100 arst_n = 1;

        // ---------------- T1 ----------------
        $display("\n[TEST 1] SDRAM init and pattern write");
        t0 = $realtime;
        wait (init_done || $realtime - t0 > 100_000);
        if (!init_done) fail("SDRAM init_done never asserted");
        wait (pg_done || $realtime - t0 > 2_000_000);
        if (!pg_done) fail("pattern_gen never finished (write port stuck?)");
        else $display("  -> PASS: init done, %0d-word pattern queued by %0.1f us",
                      H_ACTIVE * V_ACTIVE / 2, ($realtime - t0) / 1000.0);

        // ---------------- T2 ----------------
        $display("\n[TEST 2] Display gradient from SDRAM");
        @(posedge vsync);          // let the write FIFO drain into SDRAM
        check_frame("frame A");
        check_frame("frame B (stable)");

        // ---------------- T3 ----------------
        $display("\n[TEST 3] Live update of lines %0d..%0d while displaying", UPD_Y0, UPD_Y0 + UPD_LINES - 1);
        tb_wp_active = 1;
        @(negedge vsync);
        repeat (20 * (H_ACTIVE + H_FP + H_SYNC + H_BP)) @(posedge pix_clk);   // mid-frame
        for (int y = UPD_Y0; y < UPD_Y0 + UPD_LINES; y++)
            for (int w = 0; w < WORDS_LINE; w++)
                tb_write(21'(y * WORDS_LINE + w),
                         ~{gradient_rgb565(12'(2 * w + 1), 12'(y), R_MUL, G_MUL),
                           gradient_rgb565(12'(2 * w),     12'(y), R_MUL, G_MUL)});
        expect_update = 1;
        @(posedge vsync);          // allow the writes to land
        check_frame("frame C (updated lines inverted, rest unchanged)");
        check_frame("frame D (stable)");

        // ---------------- T4 ----------------
        $display("\n[TEST 4] SDRAM protocol");
        if (u_sdram.errors != 0) fail($sformatf("%0d SDRAM protocol errors", u_sdram.errors));
        else $display("  -> PASS: no protocol errors (%0d ACT, %0d READ, %0d WRITE, %0d REFRESH)",
                      u_sdram.n_activate, u_sdram.n_read_cmd, u_sdram.n_write_cmd, u_sdram.n_refresh);

        $display("\n==================================================================");
        if (errors == 0) $display(" TEST PASSED: framebuffer_tb (%0d frames verified)", frames);
        else             $display(" TEST FAILED: framebuffer_tb (%0d errors)", errors);
        $display("==================================================================\n");
        $finish;
    end

    initial begin
        #5ms;
        $display(" TEST FAILED: framebuffer_tb watchdog timeout");
        $finish;
    end

endmodule
