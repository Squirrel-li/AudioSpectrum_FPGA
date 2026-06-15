`timescale 1ns/1ps

module tb_ledr_volume_meter;
    reg clk;
    reg rst_n;
    reg enable;
    reg [1:0] sensitivity;
    reg sample_valid;
    reg signed [15:0] sample_in;
    wire [17:0] ledr;

    ledr_volume_meter uut (
        .clk(clk),
        .rst_n(rst_n),
        .enable(enable),
        .sensitivity(sensitivity),
        .sample_valid(sample_valid),
        .sample_in(sample_in),
        .ledr(ledr)
    );

    // Clock generation: 50 MHz (20ns period)
    always #10 clk = ~clk;

    // Helper task to pulse sample_valid multiple times to let the IIR filter settle
    task feed_samples;
        input signed [15:0] val;
        input integer count;
        integer k;
        begin
            sample_in = val;
            for (k = 0; k < count; k = k + 1) begin
                @(posedge clk);
                sample_valid = 1'b1;
                @(posedge clk);
                sample_valid = 1'b0;
                // wait a few cycles
                repeat (3) @(posedge clk);
            end
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        enable = 1'b0;
        sensitivity = 2'b00;
        sample_valid = 1'b0;
        sample_in = 16'd0;

        #100;
        rst_n = 1'b1;
        #100;

        // Test 1: Disabled
        $display("[TB] Test 1: Checking disabled volume meter...");
        feed_samples(16'd32767, 20);
        if (ledr !== 18'd0) begin
            $display("[TB] ERROR: LEDs active when disabled: ledr = %b", ledr);
            $finish;
        end

        // Test 2: Enable at 1x sensitivity (00)
        enable = 1'b1;
        sensitivity = 2'b00;
        $display("[TB] Test 2: Checking 1x sensitivity with full scale...");
        feed_samples(16'd32767, 50); // let IIR settle
        // Expect full scale output (either 17 or 18 LEDs: 18'h1FFFF or 18'h3FFFF)
        if (ledr !== 18'h3FFFF && ledr !== 18'h1FFFF) begin
            $display("[TB] ERROR: 1x full-scale expected 18'h3FFFF or 18'h1FFFF, got %b (smooth_amp=%d)", ledr, uut.smooth_amp);
            $finish;
        end

        // Test 3: Checking half scale at 1x sensitivity
        $display("[TB] Test 3: Checking 1x sensitivity with half scale...");
        feed_samples(16'd16384, 50);
        // Expect roughly half of LEDs: 9 LEDs (18'h01FF)
        // Let's verify it is within a reasonable range (8 to 10 LEDs)
        if (ledr < 18'h00FF || ledr > 18'h03FF) begin
            $display("[TB] ERROR: 1x half-scale expected ~9 LEDs, got %b (smooth_amp=%d)", ledr, uut.smooth_amp);
            $finish;
        end
        $display("[TB] Half-scale output ledr = %b (smooth_amp=%d)", ledr, uut.smooth_amp);

        // Test 4: 2x sensitivity (01) with half scale sample
        $display("[TB] Test 4: Checking 2x sensitivity with half scale...");
        sensitivity = 2'b01;
        feed_samples(16'd16384, 50);
        // Half scale boosted 2x should light up full scale (17 or 18 LEDs)
        if (ledr !== 18'h3FFFF && ledr !== 18'h1FFFF) begin
            $display("[TB] ERROR: 2x half-scale expected 18'h3FFFF or 18'h1FFFF, got %b (smooth_amp=%d)", ledr, uut.smooth_amp);
            $finish;
        end

        // Test 5: 4x sensitivity (10) with quarter scale sample
        $display("[TB] Test 5: Checking 4x sensitivity with quarter scale...");
        sensitivity = 2'b10;
        feed_samples(16'd8192, 50);
        // Quarter scale boosted 4x should light up full scale (17 or 18 LEDs)
        if (ledr !== 18'h3FFFF && ledr !== 18'h1FFFF) begin
            $display("[TB] ERROR: 4x quarter-scale expected 18'h3FFFF or 18'h1FFFF, got %b", ledr);
            $finish;
        end

        // Test 6: 8x sensitivity (11) with 1/8 scale sample
        $display("[TB] Test 6: Checking 8x sensitivity with 1/8 scale...");
        sensitivity = 2'b11;
        feed_samples(16'd4096, 50);
        // 1/8 scale boosted 8x should light up full scale (17 or 18 LEDs)
        if (ledr !== 18'h3FFFF && ledr !== 18'h1FFFF) begin
            $display("[TB] ERROR: 8x 1/8-scale expected 18'h3FFFF or 18'h1FFFF, got %b", ledr);
            $finish;
        end

        // Test 7: Overflow / Saturation safety test
        $display("[TB] Test 7: Checking overflow safety (8x boost on larger sample)...");
        sensitivity = 2'b11;
        feed_samples(16'd16384, 50);
        // 16384 boosted 8x is 131072, which is > 32767 (overflow).
        // It must saturate cleanly at 18 LEDs, and NOT wrap around/overflow.
        if (ledr !== 18'h3FFFF) begin
            $display("[TB] ERROR: Overflow safety failed! Expected 18'h3FFFF, got %b", ledr);
            $finish;
        end

        $display("[TB] SUCCESS: ledr_volume_meter testbench passed!");
        $finish;
    end
endmodule
