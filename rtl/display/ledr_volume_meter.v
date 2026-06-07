//=============================================================================
// Module: ledr_volume_meter
// Description: Maps audio amplitude to 18 red LEDs on DE2-115 as a volume
//              bar graph. Uses IIR smoothing on the absolute sample value
//              and generates a thermometer-coded LED pattern.
// Target: Cyclone IV E (EP4CE115F29C7)
//=============================================================================

module ledr_volume_meter (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        enable,          // SW0: 0=all off, 1=show volume
    input  wire        sample_valid,    // pulse when new sample arrives
    input  wire signed [15:0] sample_in,
    output reg  [17:0] ledr
);

    //=========================================================================
    // Absolute value computation
    //=========================================================================
    wire [15:0] abs_sample;
    assign abs_sample = sample_in[15] ? (~sample_in + 16'd1) : sample_in;

    //=========================================================================
    // IIR smoothing filter
    // smooth_amp <= smooth_amp - (smooth_amp >> 3) + (abs_sample >> 3)
    //=========================================================================
    reg [15:0] smooth_amp;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            smooth_amp <= 16'd0;
        end else if (sample_valid && enable) begin
            smooth_amp <= smooth_amp - (smooth_amp >> 3) + (abs_sample >> 3);
        end
    end

    //=========================================================================
    // Map smoothed amplitude to bar count (0~18)
    //=========================================================================
    // bars = smooth_amp * 18 / 32768  (>> 15)
    // Max: 65535 * 18 = 1,179,630 → needs 21 bits to avoid overflow
    wire [20:0] bars_wide;
    wire [4:0]  bars;

    assign bars_wide = {1'b0, smooth_amp} * 21'd18;  // zero-extend to 21-bit
    assign bars      = (bars_wide[20:15] > 5'd18) ? 5'd18 : bars_wide[20:15];

    //=========================================================================
    // Generate thermometer-coded LED pattern
    //=========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ledr <= 18'd0;
        end else if (!enable) begin
            ledr <= 18'd0;
        end else begin
            if (bars == 5'd0)
                ledr <= 18'd0;
            else
                ledr <= (18'd1 << bars) - 18'd1;
        end
    end

endmodule
