`timescale 1ns / 1ps

/*
 async_fifo testbench

 Verifies the contract in docs/phase2_spec.md (async_fifo):
   T1 reset state
   T2 first-word-fall-through latency / data
   T3 fill to full (writes while full are dropped), wr_count at full
   T4 drain in order, rd_count reaches 0, rd_en while empty is ignored
   T5 randomised concurrent traffic, both clock ratios, with
      "burst" flow control using rd_count / wr_count (how the framebuffer
      uses them) — a burst must never hit empty/full
   T6 asynchronous flush (reset) with data inside, then traffic again

 Run:  make sim TB=async_fifo_tb
*/

module async_fifo_tb;

    localparam int WIDTH  = 16;
    localparam int ADDR_W = 4;
    localparam int DEPTH  = 1 << ADDR_W;
    localparam int BURST  = 4;

    // ------------------------------------------------------------------
    // Clocks (periods can be changed at run time)
    // ------------------------------------------------------------------
    real wr_half = 6.734;   // 74.25 MHz
    real rd_half = 7.716;   // 64.8  MHz
    logic wr_clk = 0, rd_clk = 0;
    always #(wr_half) wr_clk = ~wr_clk;
    always #(rd_half) rd_clk = ~rd_clk;

    // ------------------------------------------------------------------
    // DUT
    // ------------------------------------------------------------------
    logic              arst_n = 0;
    logic              wr_en  = 0;
    logic [WIDTH-1:0]  wr_data = '0;
    wire               wr_full;
    wire  [ADDR_W:0]   wr_count;
    logic              rd_en  = 0;
    wire  [WIDTH-1:0]  rd_data;
    wire               rd_empty;
    wire  [ADDR_W:0]   rd_count;

    async_fifo #(.WIDTH(WIDTH), .ADDR_W(ADDR_W)) dut (
        .arst_n  (arst_n),
        .wr_clk  (wr_clk), .wr_en(wr_en), .wr_data(wr_data),
        .wr_full (wr_full), .wr_count(wr_count),
        .rd_clk  (rd_clk), .rd_en(rd_en), .rd_data(rd_data),
        .rd_empty(rd_empty), .rd_count(rd_count)
    );

    // ------------------------------------------------------------------
    // Scoreboard
    // ------------------------------------------------------------------
    logic [WIDTH-1:0] sb [$];
    int errors = 0;
    int n_written = 0, n_read = 0;

    task automatic fail(input string msg);
        errors++;
        if (errors <= 20) $display("  -> FAIL @ %0t: %s", $realtime, msg);
    endtask

    // Write one word (blocking until accepted). Returns when done.
    task automatic push(input logic [WIDTH-1:0] d);
        @(negedge wr_clk);
        while (wr_full) @(negedge wr_clk);
        wr_en = 1; wr_data = d;
        @(posedge wr_clk);
        sb.push_back(d);
        n_written++;
        #0.1 wr_en = 0;
    endtask

    // Pop one word and compare against the scoreboard
    task automatic pop_check();
        logic [WIDTH-1:0] exp;
        @(negedge rd_clk);
        while (rd_empty) @(negedge rd_clk);
        if (sb.size() == 0) begin
            fail("FIFO presented data but scoreboard is empty");
        end else begin
            exp = sb.pop_front();
            if (rd_data !== exp) fail($sformatf("data mismatch: got %h expected %h", rd_data, exp));
        end
        rd_en = 1;
        @(posedge rd_clk);
        n_read++;
        #0.1 rd_en = 0;
    endtask

    task automatic do_reset();
        arst_n = 0;
        wr_en = 0; rd_en = 0;
        repeat (4) @(posedge wr_clk);
        repeat (4) @(posedge rd_clk);
        arst_n = 1;
        repeat (4) @(posedge wr_clk);
        repeat (4) @(posedge rd_clk);
        sb.delete();
    endtask

    // ------------------------------------------------------------------
    // Randomised stress: independent writer / reader processes
    // ------------------------------------------------------------------
    int  stress_words;
    int  p_wr, p_rd;          // percent probability of attempting each cycle
    bit  stress_wr_done, stress_rd_done;

    task automatic stress_writer();
        int sent = 0;
        while (sent < stress_words) begin
            @(negedge wr_clk);
            if (($urandom % 100) < p_wr) begin
                // Burst write when wr_count says there is room for a whole burst
                if ((DEPTH - wr_count) >= BURST && ($urandom % 2)) begin
                    for (int i = 0; i < BURST && sent < stress_words; i++) begin
                        if (i > 0) @(negedge wr_clk);
                        if (wr_full) begin
                            fail("wr_full asserted during a burst that wr_count allowed");
                            break;
                        end
                        wr_en = 1; wr_data = $urandom;
                        @(posedge wr_clk);
                        sb.push_back(wr_data); sent++; n_written++;
                        #0.1 wr_en = 0;
                    end
                end else if (!wr_full) begin
                    wr_en = 1; wr_data = $urandom;
                    @(posedge wr_clk);
                    sb.push_back(wr_data); sent++; n_written++;
                    #0.1 wr_en = 0;
                end
            end
        end
        stress_wr_done = 1;
    endtask

    task automatic stress_reader();
        logic [WIDTH-1:0] exp;
        int got = 0;
        while (got < stress_words) begin
            @(negedge rd_clk);
            if (($urandom % 100) < p_rd) begin
                if (rd_count >= BURST && ($urandom % 2)) begin
                    // Burst read: rd_count promised BURST words -> must never be empty
                    for (int i = 0; i < BURST; i++) begin
                        if (i > 0) @(negedge rd_clk);
                        if (rd_empty) begin
                            fail("rd_empty during a burst that rd_count allowed");
                        end else begin
                            exp = sb.pop_front();
                            if (rd_data !== exp) fail($sformatf("stress mismatch: got %h exp %h", rd_data, exp));
                            rd_en = 1; @(posedge rd_clk); got++; n_read++; #0.1 rd_en = 0;
                        end
                    end
                end else if (!rd_empty) begin
                    exp = sb.pop_front();
                    if (rd_data !== exp) fail($sformatf("stress mismatch: got %h exp %h", rd_data, exp));
                    rd_en = 1; @(posedge rd_clk); got++; n_read++; #0.1 rd_en = 0;
                end
            end
        end
        stress_rd_done = 1;
    endtask

    task automatic run_stress(input int words, input int pw, input int pr, input string name);
        int e0;
        e0 = errors;
        stress_words = words; p_wr = pw; p_rd = pr;
        stress_wr_done = 0; stress_rd_done = 0;
        fork
            stress_writer();
            stress_reader();
        join
        if (sb.size() != 0) fail($sformatf("%0d words left in scoreboard", sb.size()));
        if (errors == e0) $display("  -> PASS: %s (%0d words)", name, words);
    endtask

    // ------------------------------------------------------------------
    // Main sequence
    // ------------------------------------------------------------------
    int accepted, cnt, e0;
    logic [WIDTH-1:0] first_word;

    initial begin
        if (!$test$plusargs("nodump")) begin
            $dumpfile("build/async_fifo_tb.vcd");
            $dumpvars(0, async_fifo_tb);
        end

        $display("==================================================================");
        $display(" [TESTBENCH] async_fifo  (WIDTH=%0d, DEPTH=%0d)", WIDTH, DEPTH);
        $display("==================================================================");

        // ---------------- T1 reset ----------------
        $display("\n[TEST 1] Reset state");
        do_reset();
        if (rd_empty !== 1'b1) fail("rd_empty not set after reset");
        if (wr_full  !== 1'b0) fail("wr_full set after reset");
        if (wr_count !== 0)    fail($sformatf("wr_count = %0d after reset", wr_count));
        if (rd_count !== 0)    fail($sformatf("rd_count = %0d after reset", rd_count));
        if (errors == 0) $display("  -> PASS: empty, not full, counts zero");

        // ---------------- T2 FWFT ----------------
        $display("\n[TEST 2] First-word-fall-through");
        e0 = errors;
        first_word = 16'hBEEF;
        push(first_word);
        cnt = 0;
        while (rd_empty && cnt < 20) begin @(posedge rd_clk); cnt++; end
        #0.1;
        if (rd_empty) fail("data never appeared on read side");
        else if (cnt > 6) fail($sformatf("FWFT latency %0d rd_clk cycles (spec: <= 6)", cnt));
        if (rd_data !== first_word) fail($sformatf("FWFT data %h, expected %h (without rd_en)", rd_data, first_word));
        repeat (5) @(posedge rd_clk);
        if (rd_empty || rd_data !== first_word) fail("head word not held while rd_en is low");
        pop_check();
        repeat (6) @(posedge rd_clk);
        if (!rd_empty) fail("rd_empty not set after popping the only word");
        if (errors == e0) $display("  -> PASS: data visible after %0d rd_clk cycles without rd_en", cnt);

        // ---------------- T3 fill to full ----------------
        $display("\n[TEST 3] Fill until full (reader idle)");
        e0 = errors;
        do_reset();
        accepted = 0;
        for (int i = 0; i < DEPTH + 8; i++) begin
            bit will_accept;
            @(negedge wr_clk);
            will_accept = !wr_full;
            wr_en = 1;
            wr_data = (will_accept ? 16'h1000 + i[15:0] : 16'hDEAD);   // DEAD = must be dropped
            @(posedge wr_clk);
            if (will_accept) begin sb.push_back(wr_data); accepted++; n_written++; end
            #0.1 wr_en = 0;
            repeat (3) @(posedge wr_clk);   // let pointers settle
        end
        if (accepted < DEPTH || accepted > DEPTH + 1)
            fail($sformatf("accepted %0d words before full (expected %0d or %0d)", accepted, DEPTH, DEPTH + 1));
        if (!wr_full) fail("wr_full not asserted");
        if (wr_count != DEPTH) fail($sformatf("wr_count = %0d when full (expected %0d)", wr_count, DEPTH));
        repeat (6) @(posedge rd_clk);
        if (rd_count < DEPTH) fail($sformatf("rd_count = %0d when full (expected >= %0d)", rd_count, DEPTH));
        if (errors == e0) $display("  -> PASS: accepted %0d words, wr_full=1, wr_count=%0d", accepted, wr_count);

        // ---------------- T4 drain ----------------
        $display("\n[TEST 4] Drain in order; rd_en while empty is ignored");
        e0 = errors;
        while (sb.size() > 0) pop_check();
        repeat (6) @(posedge rd_clk);
        if (!rd_empty) fail("not empty after drain");
        if (rd_count != 0) fail($sformatf("rd_count = %0d after drain", rd_count));
        repeat (6) @(posedge wr_clk);
        if (wr_count != 0) fail($sformatf("wr_count = %0d after drain", wr_count));
        // Hammer rd_en while empty, then make sure the next word is intact
        @(negedge rd_clk); rd_en = 1;
        repeat (10) @(posedge rd_clk);
        #0.1 rd_en = 0;
        push(16'h5A5A);
        pop_check();
        if (errors == e0) $display("  -> PASS: all words in order, counts back to zero");

        // ---------------- T5 stress ----------------
        $display("\n[TEST 5] Randomised concurrent traffic");
        do_reset();
        run_stress(4000, 90, 40, "fast writer / slow reader (wr 74.25, rd 64.8 MHz)");
        run_stress(4000, 40, 90, "slow writer / fast reader");
        wr_half = 10.0;   // 50 MHz
        rd_half = 3.367;  // 148.5 MHz
        repeat (4) @(posedge wr_clk);
        run_stress(4000, 95, 95, "wr 50 MHz / rd 148.5 MHz, full rate");
        wr_half = 3.367;
        rd_half = 10.0;
        repeat (4) @(posedge rd_clk);
        run_stress(4000, 95, 95, "wr 148.5 MHz / rd 50 MHz, full rate");
        wr_half = 6.734; rd_half = 7.716;

        // ---------------- T6 flush ----------------
        $display("\n[TEST 6] Asynchronous flush with data inside");
        e0 = errors;
        for (int i = 0; i < DEPTH / 2; i++) push(16'hF000 + i[15:0]);
        repeat (8) @(posedge rd_clk);
        #3.1 arst_n = 0;               // assert asynchronously, mid-cycle
        sb.delete();
        repeat (3) @(posedge rd_clk);
        if (!rd_empty) fail("rd_empty not asserted during reset");
        repeat (3) @(posedge wr_clk);
        arst_n = 1;
        repeat (6) @(posedge wr_clk);
        repeat (6) @(posedge rd_clk);
        if (!rd_empty || rd_count != 0 || wr_count != 0 || wr_full)
            fail("FIFO not empty after flush");
        for (int i = 0; i < 10; i++) push(16'h0A00 + i[15:0]);
        for (int i = 0; i < 10; i++) pop_check();
        if (errors == e0) $display("  -> PASS: flushed, then clean traffic");

        // ---------------- Summary ----------------
        $display("\n==================================================================");
        if (errors == 0)
            $display(" TEST PASSED: async_fifo_tb (%0d words written, %0d read)", n_written, n_read);
        else
            $display(" TEST FAILED: async_fifo_tb (%0d errors)", errors);
        $display("==================================================================\n");
        $finish;
    end

    // Watchdog
    initial begin
        #5ms;
        $display(" TEST FAILED: async_fifo_tb watchdog timeout");
        $finish;
    end

endmodule
