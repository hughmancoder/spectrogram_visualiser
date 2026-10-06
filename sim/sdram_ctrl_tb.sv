`timescale 1ns / 1ps

/*
 sdram_ctrl testbench

 DUT: sdram_ctrl (contract in docs/phase2_spec.md) + sim/models/sdram_model.sv
 The model checks every SDRAM protocol / timing rule; this testbench drives the
 user interface and checks data, handshakes and performance.

   T1 initialisation: init_done timing, no requests accepted before it
   T2 single write + read burst, verified through the model backdoor
   T3 address mapping corners {row, bank, col} via backdoor
   T4 randomised back-to-back mixed read/write traffic vs a shadow memory
   T5 throughput: back-to-back read and write bursts
   T6 refresh while idle (model flags refresh starvation)
   +  monitors: wr_data_ack / rd_data_valid come in runs of exactly BURST_LEN,
      and only when a burst of that type is outstanding

 Parameters (override with TB_PARAMS="-Psdram_ctrl_tb.NAME=value"):
   BURST_LEN   words per request (8, 16, 32, ...)
   CLK_DLY_PS  clock delay FPGA -> SDRAM
   DQ_DLY_PS   read data return delay SDRAM -> FPGA

 Run:  make sim TB=sdram_ctrl_tb
*/

module sdram_ctrl_tb;

    parameter int BURST_LEN  = 32;
    parameter int CLK_DLY_PS = 1500;
    parameter int DQ_DLY_PS  = 2000;

    localparam int  CLK_FREQ_HZ = 64_800_000;
    localparam int  INIT_US     = 10;        // shortened power-up wait for simulation
    localparam real T_CLK       = 15.432;    // ns
    localparam int  NSLOTS      = 64;        // bursts tracked in the shadow memory

    // ------------------------------------------------------------------
    // Clocks: controller clock + 180 deg SDRAM clock (with board delay)
    // ------------------------------------------------------------------
    logic clk = 0;
    always #(T_CLK / 2) clk = ~clk;

    wire sdram_clk_pin = ~clk;                 // what the PLL CLKOUTP would drive
    wire sdram_clk_dev;
    assign #(CLK_DLY_PS / 1000.0) sdram_clk_dev = sdram_clk_pin;

    // ------------------------------------------------------------------
    // DUT
    // ------------------------------------------------------------------
    logic        rst_n = 0;
    logic        req_valid = 0;
    wire         req_ready;
    logic        req_we = 0;
    logic [20:0] req_addr = '0;
    wire  [31:0] wr_data;
    wire         wr_data_ack;
    wire  [31:0] rd_data;
    wire         rd_data_valid;
    wire         init_done;

    wire        sdram_cke, sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n;
    wire [10:0] sdram_addr;
    wire [1:0]  sdram_ba;
    wire [3:0]  sdram_dqm;
    wire [31:0] sdram_dq;

    sdram_ctrl #(
        .CLK_FREQ_HZ (CLK_FREQ_HZ),
        .BURST_LEN   (BURST_LEN),
        .INIT_WAIT_US(INIT_US)
    ) dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .req_valid    (req_valid),
        .req_ready    (req_ready),
        .req_we       (req_we),
        .req_addr     (req_addr),
        .wr_data      (wr_data),
        .wr_data_ack  (wr_data_ack),
        .rd_data      (rd_data),
        .rd_data_valid(rd_data_valid),
        .init_done    (init_done),
        .sdram_cke    (sdram_cke),
        .sdram_cs_n   (sdram_cs_n),
        .sdram_ras_n  (sdram_ras_n),
        .sdram_cas_n  (sdram_cas_n),
        .sdram_we_n   (sdram_we_n),
        .sdram_addr   (sdram_addr),
        .sdram_ba     (sdram_ba),
        .sdram_dqm    (sdram_dqm),
        .sdram_dq     (sdram_dq)
    );

    sdram_model #(
        .T_IO     (DQ_DLY_PS / 1000.0),
        .T_INIT_NS(INIT_US * 1000.0)
    ) u_sdram (
        .clk  (sdram_clk_dev),
        .cke  (sdram_cke),
        .cs_n (sdram_cs_n),
        .ras_n(sdram_ras_n),
        .cas_n(sdram_cas_n),
        .we_n (sdram_we_n),
        .addr (sdram_addr),
        .ba   (sdram_ba),
        .dqm  (sdram_dqm),
        .dq   (sdram_dq)
    );

    // ------------------------------------------------------------------
    // Bookkeeping
    // ------------------------------------------------------------------
    int errors = 0;

    task automatic fail(input string msg);
        errors++;
        if (errors <= 25) $display("  -> FAIL @ %0t: %s", $realtime, msg);
    endtask

    // Write data source: circular buffer, presented FWFT-style
    logic [31:0] wbuf [0:1023];
    int          w_head = 0, w_tail = 0;
    assign wr_data = wbuf[w_head % 1024];

    // Expected read data, in request order
    logic [31:0] rd_exp [$];
    bit          rd_check [$];      // 0 = don't compare (just count)
    int          rd_words = 0;

    int wr_bursts_outstanding = 0;
    int rd_bursts_outstanding = 0;

    // ------------------------------------------------------------------
    // Monitors
    // ------------------------------------------------------------------
    int ack_run = 0, val_run = 0;

    always @(posedge clk) begin
        // ---- write data acknowledge ----
        if (wr_data_ack) begin
            if (ack_run == 0 && wr_bursts_outstanding == 0)
                fail("wr_data_ack asserted with no write burst outstanding");
            if (w_head == w_tail)
                fail("wr_data_ack consumed more data than was supplied");
            w_head <= w_head + 1;
            ack_run++;
            if (ack_run == BURST_LEN) begin
                ack_run = 0;
                wr_bursts_outstanding--;
            end
        end else if (ack_run != 0) begin
            fail($sformatf("wr_data_ack run of %0d cycles (expected %0d consecutive)", ack_run, BURST_LEN));
            ack_run = 0;
            wr_bursts_outstanding--;
        end

        // ---- read data valid ----
        if (rd_data_valid) begin
            if (val_run == 0 && rd_bursts_outstanding == 0)
                fail("rd_data_valid asserted with no read burst outstanding");
            if (rd_exp.size() == 0) begin
                fail("unexpected read data");
            end else begin
                logic [31:0] e;
                bit          chk;
                e   = rd_exp.pop_front();
                chk = rd_check.pop_front();
                if (chk && rd_data !== e)
                    fail($sformatf("read data mismatch: got %h expected %h", rd_data, e));
            end
            rd_words++;
            val_run++;
            if (val_run == BURST_LEN) begin
                val_run = 0;
                rd_bursts_outstanding--;
            end
        end else if (val_run != 0) begin
            fail($sformatf("rd_data_valid run of %0d cycles (expected %0d consecutive)", val_run, BURST_LEN));
            val_run = 0;
            rd_bursts_outstanding--;
        end
    end

    // ------------------------------------------------------------------
    // Driver tasks
    // ------------------------------------------------------------------
    // Present a request and wait for the handshake (req_valid && req_ready on a posedge)
    task automatic issue(input bit we, input logic [20:0] a);
        int guard = 0;
        @(negedge clk);
        req_valid = 1; req_we = we; req_addr = a;
        @(posedge clk);
        while (!req_ready) begin
            @(posedge clk);
            if (++guard > 5000) begin fail("request never accepted"); break; end
        end
        if (we) wr_bursts_outstanding++; else rd_bursts_outstanding++;
        #0.1 req_valid = 0;
    endtask

    task automatic queue_write(input logic [20:0] a, input logic [31:0] d [0:255]);
        for (int i = 0; i < BURST_LEN; i++) begin
            wbuf[w_tail % 1024] = d[i];
            w_tail++;
        end
        issue(1'b1, a);
    endtask

    task automatic queue_read(input logic [20:0] a, input logic [31:0] e [0:255], input bit check);
        for (int i = 0; i < BURST_LEN; i++) begin
            rd_exp.push_back(e[i]);
            rd_check.push_back(check);
        end
        issue(1'b0, a);
    endtask

    task automatic wait_idle();
        int guard = 0;
        while ((rd_exp.size() != 0 || wr_bursts_outstanding != 0 || rd_bursts_outstanding != 0)
               && guard < 100000) begin
            @(posedge clk);
            guard++;
        end
        if (guard >= 100000) fail("timeout waiting for outstanding bursts");
        repeat (10) @(posedge clk);
    endtask

    // Backdoor helpers: word address = {row[10:0], bank[1:0], col[7:0]}
    function automatic logic [31:0] backdoor(input logic [20:0] a);
        backdoor = u_sdram.peek(a[9:8], a[20:10], a[7:0]);
    endfunction

    // ------------------------------------------------------------------
    // Shadow memory for randomised testing
    // ------------------------------------------------------------------
    logic [20:0] slot_addr [NSLOTS];
    logic [31:0] shadow    [NSLOTS][0:255];
    logic [31:0] tmp       [0:255];

    function automatic logic [20:0] rand_aligned_addr();
        logic [20:0] a;
        a = $urandom;
        rand_aligned_addr = a & ~21'(BURST_LEN - 1);
    endfunction

    // ------------------------------------------------------------------
    // Main sequence
    // ------------------------------------------------------------------
    realtime t0, t_init;
    int      e0, cycles, ref0;
    logic [20:0] corner [6];

    initial begin
        if (!$test$plusargs("nodump")) begin
            $dumpfile("build/sdram_ctrl_tb.vcd");
            $dumpvars(0, sdram_ctrl_tb);
        end

        $display("==================================================================");
        $display(" [TESTBENCH] sdram_ctrl  (BURST_LEN=%0d, clk dly %0d ps, dq dly %0d ps)",
                 BURST_LEN, CLK_DLY_PS, DQ_DLY_PS);
        $display("==================================================================");

        // ---------------- T1 init ----------------
        $display("\n[TEST 1] Power-up initialisation");
        repeat (5) @(posedge clk);
        #1 rst_n = 1;
        t0 = $realtime;
        // A request held during init must not be accepted until init_done
        @(negedge clk);
        req_valid = 1; req_we = 0; req_addr = 0;
        forever begin
            @(posedge clk);
            if (req_ready) begin
                if (!init_done) fail("request accepted (req_ready) before init_done");
                // Accepted: expect one (unchecked) read burst back
                rd_bursts_outstanding++;
                for (int i = 0; i < BURST_LEN; i++) begin
                    rd_exp.push_back('0);
                    rd_check.push_back(1'b0);
                end
                break;
            end
            if ($realtime - t0 > (INIT_US + 50) * 1000.0) begin
                fail("init_done / req_ready never asserted");
                break;
            end
        end
        #0.1 req_valid = 0;
        wait (init_done);
        t_init = $realtime - t0;
        if (t_init < INIT_US * 1000.0)
            fail($sformatf("init_done after %0.1f us (< %0d us power-up wait)", t_init / 1000.0, INIT_US));
        if (!u_sdram.mode_set) fail("init_done asserted but mode register never loaded");
        if (errors == 0)
            $display("  -> PASS: init_done after %0.2f us (CL=%0d, BL=%0d)",
                     t_init / 1000.0, u_sdram.cas_latency, u_sdram.burst_len);
        repeat (20) @(posedge clk);

        // ---------------- T2 single burst ----------------
        $display("\n[TEST 2] Single write burst + read back (addr 0)");
        e0 = errors;
        for (int i = 0; i < BURST_LEN; i++) tmp[i] = 32'hA5000000 | (i << 8) | i;
        queue_write(21'h0, tmp);
        wait_idle();
        for (int i = 0; i < BURST_LEN; i++)
            if (backdoor(21'(i)) !== tmp[i])
                fail($sformatf("backdoor word %0d = %h, expected %h", i, backdoor(21'(i)), tmp[i]));
        queue_read(21'h0, tmp, 1'b1);
        wait_idle();
        if (errors == e0) $display("  -> PASS: %0d words written, verified via backdoor and read back", BURST_LEN);

        // ---------------- T3 address mapping ----------------
        $display("\n[TEST 3] Address mapping {row, bank, col}");
        e0 = errors;
        corner[0] = {11'd0,    2'd1, 8'd0};
        corner[1] = {11'd0,    2'd2, 8'd0};
        corner[2] = {11'd0,    2'd3, 8'd0};
        corner[3] = {11'd1234, 2'd2, 8'(256 - BURST_LEN)};
        corner[4] = {11'd2047, 2'd3, 8'(256 - BURST_LEN)};   // last burst in memory
        corner[5] = {11'd1,    2'd0, 8'(BURST_LEN)};
        for (int c = 0; c < 6; c++) begin
            for (int i = 0; i < BURST_LEN; i++) tmp[i] = {3'(c), corner[c], 8'(i)};
            queue_write(corner[c], tmp);
        end
        wait_idle();
        for (int c = 0; c < 6; c++)
            for (int i = 0; i < BURST_LEN; i++)
                if (backdoor(corner[c] + 21'(i)) !== {3'(c), corner[c], 8'(i)})
                    fail($sformatf("addr %h word %0d landed in the wrong place (backdoor %h)",
                                   corner[c], i, backdoor(corner[c] + 21'(i))));
        for (int c = 0; c < 6; c++) begin
            for (int i = 0; i < BURST_LEN; i++) tmp[i] = {3'(c), corner[c], 8'(i)};
            queue_read(corner[c], tmp, 1'b1);
        end
        wait_idle();
        if (errors == e0) $display("  -> PASS: banks, rows and columns map as specified");

        // ---------------- T4 random traffic ----------------
        $display("\n[TEST 4] Randomised back-to-back read/write traffic");
        e0 = errors;
        for (int s = 0; s < NSLOTS; s++) begin
            bit dup;
            do begin
                slot_addr[s] = rand_aligned_addr();
                dup = 0;
                for (int k = 0; k < s; k++) if (slot_addr[k] == slot_addr[s]) dup = 1;
            end while (dup);
            for (int i = 0; i < BURST_LEN; i++) shadow[s][i] = $urandom;
            for (int i = 0; i < BURST_LEN; i++) tmp[i] = shadow[s][i];
            queue_write(slot_addr[s], tmp);
        end
        for (int n = 0; n < 400; n++) begin
            int s;
            s = $urandom % NSLOTS;
            if (($urandom % 100) < 40) begin
                for (int i = 0; i < BURST_LEN; i++) shadow[s][i] = $urandom;
                for (int i = 0; i < BURST_LEN; i++) tmp[i] = shadow[s][i];
                queue_write(slot_addr[s], tmp);
            end else begin
                for (int i = 0; i < BURST_LEN; i++) tmp[i] = shadow[s][i];
                queue_read(slot_addr[s], tmp, 1'b1);
            end
        end
        wait_idle();
        if (errors == e0) $display("  -> PASS: 464 bursts, all read data matched the shadow memory");

        // ---------------- T5 throughput ----------------
        $display("\n[TEST 5] Throughput (back-to-back bursts)");
        e0 = errors;
        for (int i = 0; i < BURST_LEN; i++) tmp[i] = 0;
        t0 = $realtime;
        for (int n = 0; n < 64; n++) queue_read(21'(n * BURST_LEN), tmp, 1'b0);
        wait_idle();
        cycles = int'(($realtime - t0) / T_CLK) - 10;
        $display("  -> 64 read bursts:  %0d cycles (%0.1f cycles/burst, %0.0f%% bus efficiency)",
                 cycles, cycles / 64.0, 100.0 * 64 * BURST_LEN / cycles);
        if (cycles > 64 * (BURST_LEN + 16))
            fail($sformatf("read throughput too low (limit %0d cycles/burst)", BURST_LEN + 16));
        t0 = $realtime;
        for (int n = 0; n < 64; n++) queue_write(21'(n * BURST_LEN), tmp);
        wait_idle();
        cycles = int'(($realtime - t0) / T_CLK) - 10;
        $display("  -> 64 write bursts: %0d cycles (%0.1f cycles/burst, %0.0f%% bus efficiency)",
                 cycles, cycles / 64.0, 100.0 * 64 * BURST_LEN / cycles);
        if (cycles > 64 * (BURST_LEN + 16))
            fail($sformatf("write throughput too low (limit %0d cycles/burst)", BURST_LEN + 16));
        if (errors == e0) $display("  -> PASS: throughput within limits");

        // ---------------- T6 refresh ----------------
        $display("\n[TEST 6] Auto refresh while idle (60 us)");
        e0 = errors;
        ref0 = u_sdram.n_refresh;
        #60us;
        if (u_sdram.n_refresh - ref0 < 4)
            fail($sformatf("only %0d refreshes in 60 us (need >= 4 for 4096/64ms)", u_sdram.n_refresh - ref0));
        if (errors == e0) $display("  -> PASS: %0d refreshes in 60 us", u_sdram.n_refresh - ref0);

        // ---------------- Summary ----------------
        $display("\n  SDRAM model: %0d ACT, %0d READ, %0d WRITE, %0d REFRESH, %0d protocol errors",
                 u_sdram.n_activate, u_sdram.n_read_cmd, u_sdram.n_write_cmd,
                 u_sdram.n_refresh, u_sdram.errors);
        $display("\n==================================================================");
        if (errors == 0 && u_sdram.errors == 0)
            $display(" TEST PASSED: sdram_ctrl_tb");
        else
            $display(" TEST FAILED: sdram_ctrl_tb (%0d testbench errors, %0d SDRAM protocol errors)",
                     errors, u_sdram.errors);
        $display("==================================================================\n");
        $finish;
    end

    // Watchdog
    initial begin
        #20ms;
        $display(" TEST FAILED: sdram_ctrl_tb watchdog timeout");
        $finish;
    end

endmodule
