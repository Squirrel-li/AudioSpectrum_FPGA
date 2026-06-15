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
    input  wire [1:0]  sensitivity,     // SW[7:6]: 00=1x, 01=2x, 10=4x, 11=8x
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
    // Map smoothed amplitude to bar count (0~18) with dynamic sensitivity
    //=========================================================================
    // boosted_amp = smooth_amp * (2^sensitivity)
    // bars = boosted_amp * 18 / 32768
    wire [23:0] boosted_amp;
    assign boosted_amp = {8'd0, smooth_amp} << sensitivity;

    // Max boosted_amp: 32767 * 8 = 262136.
    // bars_wide = boosted_amp * 18
    // Max bars_wide: 262136 * 18 = 4718448 (fits in 28-bit)
    wire [27:0] bars_wide;
    wire [12:0] bars_div;
    wire [4:0]  bars;

    assign bars_wide = boosted_amp * 28'd18;
    assign bars_div  = bars_wide[27:15]; // divide by 32768
    assign bars      = (bars_div > 13'd18) ? 5'd18 : bars_div[4:0];

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
