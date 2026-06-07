module audio_adc_aligned(
    clk,
    reset,
    read,
    readdata,
    empty,
    clear,
    sample_tick,
    bclk,
    adclrc,
    adcdat
);

parameter DATA_WIDTH = 32;

input                         clk;
input                         reset;
input                         read;
output [(DATA_WIDTH-1):0]     readdata;
output                        empty;
input                         clear;
output                        sample_tick;
input                         bclk;
input                         adclrc;
input                         adcdat;

reg [4:0]                 bit_index;
reg                       valid_bit;
reg                       reg_adc_left;
reg [(DATA_WIDTH-1):0]    reg_adc_serial_data;
reg [(DATA_WIDTH-1):0]    adcfifo_writedata;
reg                       adcfifo_write;
wire                      adcfifo_full;
reg                       wait_one_clk;
reg                       sample_toggle_bclk;

wire is_left_ch = ~adclrc;

always @(posedge bclk) begin
    if (reset || clear) begin
        bit_index = DATA_WIDTH;
        reg_adc_left = is_left_ch;
        adcfifo_write = 1'b0;
        valid_bit = 1'b0;
        wait_one_clk = 1'b0;
        sample_toggle_bclk = 1'b0;
    end else begin
        if (adcfifo_write)
            adcfifo_write = 1'b0;

        if (reg_adc_left ^ is_left_ch) begin
            reg_adc_left = is_left_ch;
            valid_bit = 1'b1;
            wait_one_clk = 1'b1;
            if (reg_adc_left)
                bit_index = DATA_WIDTH;
        end

        if (valid_bit && wait_one_clk) begin
            wait_one_clk = 1'b0;
        end else if (valid_bit && !wait_one_clk) begin
            bit_index = bit_index - 1'b1;
            reg_adc_serial_data[bit_index] = adcdat;
            if ((bit_index == 0) || (bit_index == (DATA_WIDTH/2))) begin
                if (bit_index == 0 && !adcfifo_full) begin
                    adcfifo_writedata = reg_adc_serial_data;
                    adcfifo_write = 1'b1;
                    sample_toggle_bclk = ~sample_toggle_bclk;
                end
                valid_bit = 1'b0;
            end
        end
    end
end

reg [2:0] sample_toggle_sync;
always @(posedge clk or posedge reset) begin
    if (reset)
        sample_toggle_sync <= 3'b000;
    else
        sample_toggle_sync <= {sample_toggle_sync[1:0], sample_toggle_bclk};
end

assign sample_tick = sample_toggle_sync[2] ^ sample_toggle_sync[1];

audio_fifo adc_fifo(
    .wrclk(bclk),
    .wrreq(adcfifo_write),
    .data(adcfifo_writedata),
    .wrfull(adcfifo_full),
    .aclr(clear),
    .rdclk(clk),
    .rdreq(read),
    .q(readdata),
    .rdempty(empty)
);

endmodule
