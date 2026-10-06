`timescale 1ns / 1ps

/*
 Behavioural SDR SDRAM Model (simulation only) — with protocol checking

 Models the GW2AR-18 embedded SDRAM: 4 banks x 2048 rows x 256 cols x 32 bit.

 Functional:
   - Mode register (CL 2/3, sequential burst length 1/2/4/8)
   - ACTIVE / READ / WRITE (with/without auto-precharge) / PRECHARGE (one/all)
   - AUTO REFRESH, LOAD MODE REGISTER, burst interruption by a new READ/WRITE
   - DQM byte masking on writes
   - Read data is driven T_AC (+ T_IO) after the clock edge and goes invalid
     ('x) T_OH (+ T_IO) after the next edge, so a controller sampling at the
     wrong time reads X and fails.

 Checks (each violation increments `errors` and prints a message):
   - Power-up: >= T_INIT_NS of NOP/INHIBIT before the first command,
     PRECHARGE ALL and >= 2 AUTO REFRESH before LOAD MODE REGISTER
   - ACTIVE/READ/WRITE before the mode register is loaded
   - tRCD, tRP, tRC, tRAS, tRFC, tWR, tMRD
   - ACTIVE to an already-open bank, READ/WRITE to a closed bank
   - REFRESH / MRS with any bank open
   - Refresh starvation: gap between refreshes > T_REFI_MAX_NS
   - X/Z on control lines, X/Z on DQ during a write burst
   - Bus contention: WRITE issued while read data is still scheduled
   - BURST TERMINATE (not supported by the controller spec), CKE low

 Backdoor (for testbenches):  peek(bank, row, col) / poke(bank, row, col, data)

 Board delays: delay the clock into this model in the testbench to model the
 clock path; use T_IO for the data return path.
*/

module sdram_model #(
    parameter real T_AC          = 6.0,      // ns, clock -> data valid
    parameter real T_OH          = 2.5,      // ns, data hold after next clock
    parameter real T_IO          = 0.0,      // ns, extra data return delay (board/IO)
    parameter real T_RCD_NS      = 18.0,
    parameter real T_RP_NS       = 18.0,
    parameter real T_RC_NS       = 60.0,
    parameter real T_RAS_NS      = 42.0,
    parameter real T_RFC_NS      = 60.0,
    parameter int  T_WR_CK       = 2,
    parameter int  T_MRD_CK      = 2,
    parameter real T_INIT_NS     = 200_000.0,
    parameter real T_REFI_MAX_NS = 15_625.0,
    parameter bit  VERBOSE       = 1'b0
)(
    input  wire        clk,
    input  wire        cke,
    input  wire        cs_n,
    input  wire        ras_n,
    input  wire        cas_n,
    input  wire        we_n,
    input  wire [10:0] addr,
    input  wire [1:0]  ba,
    input  wire [3:0]  dqm,
    inout  wire [31:0] dq
);

    // ------------------------------------------------------------------
    // Storage: index = {bank, row, col}
    // ------------------------------------------------------------------
    bit [31:0] mem [0:(1<<21)-1];

    function automatic int idx(input int b, input int r, input int c);
        idx = (b << 19) | (r << 8) | c;
    endfunction

    function automatic bit [31:0] peek(input int b, input int r, input int c);
        peek = mem[idx(b, r, c)];
    endfunction

    task automatic poke(input int b, input int r, input int c, input bit [31:0] d);
        mem[idx(b, r, c)] = d;
    endtask

    // ------------------------------------------------------------------
    // Statistics / status (readable hierarchically by testbenches)
    // ------------------------------------------------------------------
    int  errors      = 0;
    int  n_activate  = 0;
    int  n_read_cmd  = 0;
    int  n_write_cmd = 0;
    int  n_refresh   = 0;
    int  n_words_wr  = 0;
    int  n_words_rd  = 0;
    bit  mode_set    = 0;
    int  cas_latency = 0;
    int  burst_len   = 0;

    task automatic err(input string msg);
        errors++;
        if (errors <= 25)
            $display("[sdram_model] ERROR @ %0t ns: %s", $realtime, msg);
        if (errors == 25)
            $display("[sdram_model] (further errors suppressed)");
    endtask

    // ------------------------------------------------------------------
    // Bank state
    // ------------------------------------------------------------------
    bit      bank_open   [4];
    int      bank_row    [4];
    realtime t_act       [4];
    bit      act_seen    [4];
    realtime t_idle_at   [4];   // precharge complete
    bit      ap_pending  [4];
    longint  ap_cycle    [4];   // cycle at which auto-precharge begins
    longint  last_wr_cyc [4];   // cycle of last write data into the bank

    realtime t_first_clk = -1;
    realtime t_last_ref  = 0;
    realtime t_starve_ref = 0;  // refresh-starvation reference time
    bit      ref_seen    = 0;
    bit      starve_flag = 0;
    bit      init_cmd_seen = 0;
    bit      pre_all_seen  = 0;
    int      init_refreshes = 0;
    longint  mrs_cyc     = -1000;
    longint  cyc         = 0;

    // Write burst state
    int wr_left = 0, wr_bank, wr_row, wr_col, wr_k;

    // Read output schedule, indexed by cycle % 32
    bit        rd_q_valid [32];
    bit [31:0] rd_q_data  [32];
    logic [31:0] dq_drv = 32'bz;
    bit        driving = 0;

    assign dq = dq_drv;

    initial begin
        for (int b = 0; b < 4; b++) begin
            bank_open[b]   = 0;
            act_seen[b]    = 0;
            t_idle_at[b]   = 0;
            ap_pending[b]  = 0;
            last_wr_cyc[b] = -1000;
        end
        for (int i = 0; i < 32; i++) rd_q_valid[i] = 0;
    end

    function automatic int burst_col(input int col, input int k);
        // Sequential burst wraps within a burst_len-aligned block
        burst_col = (col & ~(burst_len - 1)) | ((col + k) & (burst_len - 1));
    endfunction

    function automatic bit all_idle(input realtime now);
        all_idle = 1;
        for (int b = 0; b < 4; b++)
            if (bank_open[b] || ap_pending[b] || now < t_idle_at[b] - 0.001)
                all_idle = 0;
    endfunction

    task automatic write_word(input int b, input int r, input int c);
        bit [31:0] cur;
        if ($isunknown(dq)) begin
            err($sformatf("X/Z on DQ during write burst (bank %0d row %0d col %0d): %h", b, r, c, dq));
        end
        if ($isunknown(dqm)) err("X/Z on DQM during write burst");
        cur = mem[idx(b, r, c)];
        for (int i = 0; i < 4; i++)
            if (!dqm[i]) cur[i*8 +: 8] = dq[i*8 +: 8];
        mem[idx(b, r, c)] = cur;
        last_wr_cyc[b] = cyc;
        n_words_wr++;
    endtask

    // ------------------------------------------------------------------
    // Main command processing
    // ------------------------------------------------------------------
    always @(posedge clk) begin : proc
        realtime now;
        logic [3:0] cmd;
        int b, slot;
        now = $realtime;
        cyc = cyc + 1;
        cmd = {cs_n, ras_n, cas_n, we_n};

        if (t_first_clk < 0) t_first_clk = now;

        // ---- auto-precharge completion ----
        for (int i = 0; i < 4; i++) begin
            if (ap_pending[i] && cyc >= ap_cycle[i]) begin
                ap_pending[i] = 0;
                bank_open[i]  = 0;
                t_idle_at[i]  = now + T_RP_NS;
            end
        end

        // ---- sanity on control pins ----
        if (cke !== 1'b1 && now - t_first_clk > 100.0)
            err("CKE is not high (power-down / self-refresh not supported)");
        if ($isunknown(cs_n) || (cs_n === 1'b0 && $isunknown({ras_n, cas_n, we_n}))) begin
            if (now - t_first_clk > 100.0) err($sformatf("X/Z on command pins: %b", cmd));
            cmd = 4'b1111;
        end

        // ---- refresh starvation ----
        if (mode_set && !starve_flag && (now - t_starve_ref) > T_REFI_MAX_NS) begin
            err($sformatf("refresh starvation: %0.1f ns since last AUTO REFRESH", now - t_starve_ref));
            starve_flag = 1;
        end

        // ---- continue an ongoing write burst (unless interrupted below) ----
        if (wr_left > 0 && !(cmd == 4'b0101 || cmd == 4'b0100)) begin
            write_word(wr_bank, wr_row, burst_col(wr_col, wr_k));
            wr_k++;
            wr_left--;
        end else if (cmd == 4'b0101 || cmd == 4'b0100) begin
            wr_left = 0;   // interrupted (or no burst active)
        end

        // ---- first real command: power-up wait ----
        if (cmd[3] == 1'b0 && cmd != 4'b0111 && !init_cmd_seen) begin
            init_cmd_seen = 1;
            if (now - t_first_clk < T_INIT_NS)
                err($sformatf("first command after only %0.1f ns (need %0.1f ns power-up wait)",
                              now - t_first_clk, T_INIT_NS));
        end

        // ---- tMRD ----
        if (cmd[3] == 1'b0 && cmd != 4'b0111 && (cyc - mrs_cyc) < T_MRD_CK)
            err("tMRD violation: command too soon after LOAD MODE REGISTER");

        b = ba;
        case (cmd)
            4'b1111, 4'b0111: ; // INHIBIT / NOP

            4'b0011: begin // ACTIVE
                n_activate++;
                if (!mode_set) err("ACTIVE before mode register set");
                if (bank_open[b] || ap_pending[b]) err($sformatf("ACTIVE to open bank %0d", b));
                if (now < t_idle_at[b] - 0.001)
                    err($sformatf("tRP violation on bank %0d (%0.2f ns early)", b, t_idle_at[b] - now));
                if (act_seen[b] && (now - t_act[b]) < T_RC_NS - 0.001)
                    err($sformatf("tRC violation on bank %0d (%0.2f ns)", b, now - t_act[b]));
                if (ref_seen && (now - t_last_ref) < T_RFC_NS - 0.001)
                    err("tRFC violation: ACTIVE too soon after REFRESH");
                bank_open[b] = 1;
                bank_row[b]  = addr;
                t_act[b]     = now;
                act_seen[b]  = 1;
                if (VERBOSE) $display("[sdram_model] %0t ACT  bank %0d row %0d", now, b, addr);
            end

            4'b0101, 4'b0100: begin // READ / WRITE
                bit is_wr;
                int col;
                is_wr = (cmd == 4'b0100);
                col   = addr[7:0];
                if (is_wr) n_write_cmd++; else n_read_cmd++;
                if (!mode_set) err("READ/WRITE before mode register set");
                if (!bank_open[b] || ap_pending[b])
                    err($sformatf("%s to closed bank %0d", is_wr ? "WRITE" : "READ", b));
                else if ((now - t_act[b]) < T_RCD_NS - 0.001)
                    err($sformatf("tRCD violation on bank %0d (%0.2f ns)", b, now - t_act[b]));

                // Cancel read data not yet started (burst interruption)
                for (int k = 0; k < 32; k++) begin
                    longint c2;
                    c2 = cyc + k;
                    if (k >= cas_latency - 1 || is_wr) begin
                        if (is_wr && rd_q_valid[c2 % 32] && k >= 0)
                            err("bus contention: WRITE issued while read data still pending");
                        rd_q_valid[c2 % 32] = 0;
                    end
                end

                if (is_wr) begin
                    wr_bank = b; wr_row = bank_row[b]; wr_col = col; wr_k = 0;
                    write_word(wr_bank, wr_row, burst_col(wr_col, 0));
                    wr_k = 1;
                    wr_left = burst_len - 1;
                end else begin
                    if ($isunknown(dqm) || dqm != 4'b0000)
                        err("DQM must be 0 during reads (controller spec)");
                    for (int k = 0; k < burst_len; k++) begin
                        slot = (cyc + cas_latency - 1 + k) % 32;
                        rd_q_valid[slot] = 1;
                        rd_q_data[slot]  = mem[idx(b, bank_row[b], burst_col(col, k))];
                    end
                end

                if (addr[10]) begin // auto-precharge
                    ap_pending[b] = 1;
                    ap_cycle[b]   = is_wr ? (cyc + burst_len - 1 + T_WR_CK) : (cyc + burst_len);
                end
                if (VERBOSE) $display("[sdram_model] %0t %s bank %0d col %0d%s", now,
                                      is_wr ? "WR  " : "RD  ", b, col, addr[10] ? " (AP)" : "");
            end

            4'b0010: begin // PRECHARGE
                for (int i = 0; i < 4; i++) begin
                    if (addr[10] || i == b) begin
                        if (bank_open[i]) begin
                            if ((now - t_act[i]) < T_RAS_NS - 0.001)
                                err($sformatf("tRAS violation on bank %0d", i));
                            if ((cyc - last_wr_cyc[i]) < T_WR_CK)
                                err($sformatf("tWR violation on bank %0d", i));
                        end
                        if (ap_pending[i]) err($sformatf("PRECHARGE to bank %0d with auto-precharge pending", i));
                        bank_open[i] = 0;
                        t_idle_at[i] = now + T_RP_NS;
                    end
                end
                if (addr[10]) pre_all_seen = 1;
            end

            4'b0001: begin // AUTO REFRESH
                if (!all_idle(now)) err("AUTO REFRESH with a bank open / precharging");
                if (ref_seen && (now - t_last_ref) < T_RFC_NS - 0.001)
                    err("tRFC violation: REFRESH too soon after REFRESH");
                for (int i = 0; i < 4; i++)
                    if (act_seen[i] && (now - t_act[i]) < T_RC_NS - 0.001)
                        err("tRC violation: REFRESH too soon after ACTIVE");
                if (!mode_set) init_refreshes++;
                n_refresh++;
                t_last_ref  = now;
                t_starve_ref = now;
                ref_seen    = 1;
                starve_flag = 0;
            end

            4'b0000: begin // LOAD MODE REGISTER
                int bl_code;
                if (!all_idle(now)) err("LOAD MODE REGISTER with a bank open");
                if (!pre_all_seen)  err("LOAD MODE REGISTER before PRECHARGE ALL");
                if (init_refreshes < 2 && !mode_set)
                    err($sformatf("LOAD MODE REGISTER after only %0d init refreshes (need >= 2)", init_refreshes));
                bl_code = addr[2:0];
                case (bl_code)
                    0: burst_len = 1;
                    1: burst_len = 2;
                    2: burst_len = 4;
                    3: burst_len = 8;
                    default: begin err("unsupported burst length code"); burst_len = 8; end
                endcase
                if (addr[3])  err("interleaved burst not supported");
                cas_latency = addr[6:4];
                if (cas_latency != 2 && cas_latency != 3) begin
                    err($sformatf("unsupported CAS latency %0d", cas_latency));
                    cas_latency = 2;
                end
                if (addr[9]) err("single-location write mode not supported");
                mode_set = 1;
                mrs_cyc  = cyc;
                t_starve_ref = now; // start refresh-starvation tracking from init end
                $display("[sdram_model] Mode register set @ %0t ns: CL=%0d BL=%0d",
                         now, cas_latency, burst_len);
            end

            4'b0110: err("BURST TERMINATE not supported by this design");

            default: err($sformatf("unknown command %b", cmd));
        endcase

        // ---- drive read data for this cycle ----
        slot = cyc % 32;
        if (rd_q_valid[slot]) begin
            dq_drv <= #(T_OH + T_IO) 32'bx;
            dq_drv <= #(T_AC + T_IO) rd_q_data[slot];
            rd_q_valid[slot] = 0;
            driving = 1;
            n_words_rd++;
        end else if (driving) begin
            dq_drv <= #(T_OH + T_IO) 32'bz;
            driving = 0;
        end
    end

endmodule
