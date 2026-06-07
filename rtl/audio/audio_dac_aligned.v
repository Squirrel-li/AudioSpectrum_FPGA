module audio_dac_aligned(
    clk,
    reset,
    write,
    writedata,
    full,
    clear,
    sample_tick,
    bclk,
    daclrc,
    dacdat
);

parameter DATA_WIDTH = 32;

input                     clk;
input                     reset;
input                     write;
input [(DATA_WIDTH-1):0]  writedata;
output                    full;
input                     clear;
output                    sample_tick;
input                     bclk;
input                     daclrc;
output                    dacdat;

reg                       request_bit;
reg                       bit_to_dac;
reg [4:0]                 bit_index;
reg                       dac_is_left;
reg [(DATA_WIDTH-1):0]    data_to_dac;
reg [(DATA_WIDTH-1):0]    shift_data_to_dac;
reg                       sample_toggle_bclk;

wire                      dacfifo_empty;
wire                      dacfifo_read;
wire [(DATA_WIDTH-1):0]   dacfifo_readdata;

wire is_left_ch = ~daclrc;

assign dacfifo_read = dacfifo_empty ? 1'b0 : 1'b1;

always @(negedge is_left_ch or posedge reset) begin
    if (reset) begin
        data_to_dac <= 32'd0;
        sample_toggle_bclk <= 1'b0;
    end else if (clear) begin
        data_to_dac <= 32'd0;
        sample_toggle_bclk <= 1'b0;
    end else begin
        if (dacfifo_empty)
            data_to_dac <= 32'd0;
        else
            data_to_dac <= dacfifo_readdata;
        sample_toggle_bclk <= ~sample_toggle_bclk;
    end
end

always @(negedge bclk) begin
    if (reset || clear) begin
        request_bit = 1'b0;
        bit_index = 5'd0;
        dac_is_left = is_left_ch;
        bit_to_dac = 1'b0;
    end else begin
        if (dac_is_left ^ is_left_ch) begin
            dac_is_left = is_left_ch;
            request_bit = 1'b1;
            if (dac_is_left) begin
                shift_data_to_dac = data_to_dac;
                bit_index = DATA_WIDTH;
            end
        end

        if (request_bit) begin
            bit_index = bit_index - 1'b1;
            bit_to_dac = shift_data_to_dac[bit_index];
            if ((bit_index == 0) || (bit_index == (DATA_WIDTH/2)))
                request_bit = 1'b0;
        end else begin
            bit_to_dac = 1'b0;
        end
    end
end

assign dacdat = bit_to_dac;

reg [2:0] sample_toggle_sync;
always @(posedge clk or posedge reset) begin
    if (reset)
        sample_toggle_sync <= 3'b000;
    else
        sample_toggle_sync <= {sample_toggle_sync[1:0], sample_toggle_bclk};
end

assign sample_tick = sample_toggle_sync[2] ^ sample_toggle_sync[1];

audio_fifo dac_fifo(
    .wrclk(clk),
    .wrreq(write),
    .data(writedata),
    .wrfull(full),
    .aclr(clear),
    .rdclk(is_left_ch),
    .rdreq(dacfifo_read),
    .q(dacfifo_readdata),
    .rdempty(dacfifo_empty)
);

endmodule
