module AUDIO_DAC(
	// host
	clk,
	reset,
	write,
	writedata,
	full,
	clear,
	// dac
	bclk,
	daclrc,
	dacdat
);

/*****************************************************************************
 *                           Parameter Declarations                          *
 *****************************************************************************/
parameter	DATA_WIDTH = 32;

/*****************************************************************************
 *                             Port Declarations                             *
 *****************************************************************************/
input						clk;
input						reset;
input						write;
input	[(DATA_WIDTH-1):0]	writedata;
output						full;
input						clear;

input						bclk;
input						daclrc;
output						dacdat;


/*****************************************************************************
 *                           Constant Declarations                           *
 *****************************************************************************/


/*****************************************************************************
 *                 Internal wires and registers Declarations                 *
 *****************************************************************************/

// Note. Left Justified Mode
reg							request_bit;
reg							bit_to_dac;
reg		[4:0]				bit_index;  //0~31
reg							dac_is_left;
reg		[(DATA_WIDTH-1):0]	data_to_dac;		
reg		[(DATA_WIDTH-1):0]	shift_data_to_dac;	

//
wire						dacfifo_empty;
wire 						dacfifo_read;
wire	[(DATA_WIDTH-1):0]	dacfifo_readdata;
wire						is_left_ch;

/*****************************************************************************
 *                         Finite State Machine(s)                           *
 *****************************************************************************/


/*****************************************************************************
 *                             Sequential logic                              *
 *****************************************************************************/


//////////// read data from fifo
// Synchronize asynchronous daclrc to 50 MHz clk domain
reg [1:0] daclrc_sync_clk;
always @(posedge clk or posedge reset) begin
	if (reset)
		daclrc_sync_clk <= 2'b11;
	else
		daclrc_sync_clk <= {daclrc_sync_clk[0], daclrc};
end
wire daclrc_sync_val = daclrc_sync_clk[1];

// Debounce synchronized daclrc in 50 MHz clk domain (filters transitions < 2 us)
reg [6:0] daclrc_cnt;
reg       daclrc_filt;

always @(posedge clk or posedge reset) begin
	if (reset) begin
		daclrc_cnt  <= 7'd0;
		daclrc_filt <= 1'b1;
	end else begin
		if (daclrc_sync_val == daclrc_filt) begin
			daclrc_cnt <= 7'd0;
		end else begin
			if (daclrc_cnt >= 7'd100) begin
				daclrc_filt <= daclrc_sync_val;
				daclrc_cnt  <= 7'd0;
			end else begin
				daclrc_cnt <= daclrc_cnt + 7'd1;
			end
		end
	end
end

// Synchronize debounced signal to bclk domain and delay it
reg [2:0] daclrc_sync_bclk;
always @(posedge bclk or posedge reset) begin
	if (reset) begin
		daclrc_sync_bclk <= 3'b111;
	end else begin
		daclrc_sync_bclk <= {daclrc_sync_bclk[1:0], daclrc_filt};
	end
end

assign is_left_ch = ~daclrc_sync_bclk[1];
wire is_left_ch_d = ~daclrc_sync_bclk[2];
wire dacfifo_read_trigger = is_left_ch && !is_left_ch_d;

assign dacfifo_read = dacfifo_read_trigger && !dacfifo_empty;

reg        read_active_d;
always @(posedge bclk or posedge reset) begin
	if (reset) begin
		data_to_dac     <= 32'd0;
		read_active_d   <= 1'b0;
	end else if (clear) begin
		data_to_dac     <= 32'd0;
		read_active_d   <= 1'b0;
	end else begin
		read_active_d <= dacfifo_read;
		if (read_active_d) begin
			data_to_dac <= dacfifo_readdata;
		end
	end
end

//////////// streaming data(32-bits) to dac chip(I2S 1-bits port)
always @ (negedge bclk) 
begin
	if (reset || clear)
	begin
		request_bit = 0;
		bit_index = 0;
		dac_is_left = is_left_ch;
		bit_to_dac = 1'b0;
	end
	else
	begin
		if (dac_is_left ^ is_left_ch)
		begin		// channel change
			dac_is_left = is_left_ch;
			request_bit = 1; 
			if (dac_is_left)
			begin
				shift_data_to_dac = data_to_dac;
				bit_index = DATA_WIDTH;
			end
		end
		
		
		// serial data to dac		
		if (request_bit)
		begin
			bit_index = bit_index - 1'b1;
			bit_to_dac = shift_data_to_dac[bit_index];  // MSB as first bit
			if ((bit_index == 0) || (bit_index == (DATA_WIDTH/2)))
				request_bit = 0;
		end			
		else
			bit_to_dac = 1'b0;
	end
end


/*****************************************************************************
 *                            Combinational logic                            *
 *****************************************************************************/

assign	dacdat = bit_to_dac;

/*****************************************************************************
 *                              Internal Modules                             *
 *****************************************************************************/

audio_fifo dac_fifo(
	// write
	.wrclk(clk),
	.wrreq(write),
	.data(writedata),
	.wrfull(full),
	.aclr(clear),  // sync with wrclk
	// read
	.rdclk(bclk),
	.rdreq(dacfifo_read),
	.q(dacfifo_readdata),
	.rdempty(dacfifo_empty)
);

endmodule



