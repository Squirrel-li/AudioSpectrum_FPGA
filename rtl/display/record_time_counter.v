//=============================================================================
// Module: record_time_counter
// Description: Counts recording and playback time in seconds based on
//              codec sample ticks. When sample count reaches SAMPLE_RATE_HZ,
//              the seconds counter increments and the sample count resets.
//              Both record and play counters saturate at 59 seconds.
// Target: Cyclone IV E (EP4CE115F29C7)
//=============================================================================

module record_time_counter #(
    parameter SAMPLE_RATE_HZ = 48000
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        record_active,
    input  wire        play_active,
    input  wire        record_sample_tick,
    input  wire        play_sample_tick,
    input  wire        clear_record_time,
    input  wire        clear_play_time,
    output reg  [6:0]  record_seconds,   // 0~59, saturate
    output reg  [6:0]  play_seconds      // 0~59, saturate
);

    //=========================================================================
    // Record sample counter and seconds
    //=========================================================================
    reg [31:0] record_sample_count;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            record_sample_count <= 32'd0;
            record_seconds      <= 7'd0;
        end else if (clear_record_time) begin
            record_sample_count <= 32'd0;
            record_seconds      <= 7'd0;
        end else if (record_active && record_sample_tick) begin
            if (record_sample_count >= (SAMPLE_RATE_HZ - 1)) begin
                record_sample_count <= 32'd0;
                if (record_seconds < 7'd59)
                    record_seconds <= record_seconds + 7'd1;
            end else begin
                record_sample_count <= record_sample_count + 32'd1;
            end
        end
    end

    //=========================================================================
    // Play sample counter and seconds
    //=========================================================================
    reg [31:0] play_sample_count;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            play_sample_count <= 32'd0;
            play_seconds      <= 7'd0;
        end else if (clear_play_time) begin
            play_sample_count <= 32'd0;
            play_seconds      <= 7'd0;
        end else if (play_active && play_sample_tick) begin
            if (play_sample_count >= (SAMPLE_RATE_HZ - 1)) begin
                play_sample_count <= 32'd0;
                if (play_seconds < 7'd59)
                    play_seconds <= play_seconds + 7'd1;
            end else begin
                play_sample_count <= play_sample_count + 32'd1;
            end
        end
    end

endmodule
