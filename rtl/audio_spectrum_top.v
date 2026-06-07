//=============================================================================
// Module: AudioSpectrum_FPGA
// Description: Top-level module for DE2-115 Audio Recorder and Player.
//              Wires PLL, I2C, WM8731 Audio Path (ADC/DAC), FSM, LCD, SRAM,
//              FLASH, LEDR volume bar, and 7-segment display logic together.
// Target: Cyclone IV E (EP4CE115F29C7)
//=============================================================================

module AudioSpectrum_FPGA(
	//////////// CLOCK //////////
	CLOCK_50,
	CLOCK2_50,
	CLOCK3_50,

	//////////// LED //////////
	LEDG,
	LEDR,

	//////////// KEY //////////
	KEY,

	//////////// SW //////////
	SW,

	//////////// SEG7 //////////
	HEX0,
	HEX1,
	HEX2,
	HEX3,
	HEX4,
	HEX5,
	HEX6,
	HEX7,

	//////////// LCD //////////
	LCD_BLON,
	LCD_DATA,
	LCD_EN,
	LCD_ON,
	LCD_RS,
	LCD_RW,

	//////////// Audio //////////
	AUD_ADCDAT,
	AUD_ADCLRCK,
	AUD_BCLK,
	AUD_DACDAT,
	AUD_DACLRCK,
	AUD_XCK,

	//////////// I2C for Audio  //////////
	I2C_SCLK,
	I2C_SDAT,

	//////////// SRAM //////////
	SRAM_ADDR,
	SRAM_CE_N,
	SRAM_DQ,
	SRAM_LB_N,
	SRAM_OE_N,
	SRAM_UB_N,
	SRAM_WE_N,

	//////////// Flash //////////
	FL_ADDR,
	FL_CE_N,
	FL_DQ,
	FL_OE_N,
	FL_RST_N,
	FL_RY,
	FL_WE_N,
	FL_WP_N 
);

//=============================================================================
//  PORT declarations
//=============================================================================

//////////// CLOCK //////////
input 		          		CLOCK_50;
input 		          		CLOCK2_50;
input 		          		CLOCK3_50;

//////////// LED //////////
output		     [8:0]		LEDG;
output		    [17:0]		LEDR;

//////////// KEY //////////
input 		     [3:0]		KEY;

//////////// SW //////////
input 		    [17:0]		SW;

//////////// SEG7 //////////
output		     [6:0]		HEX0;
output		     [6:0]		HEX1;
output		     [6:0]		HEX2;
output		     [6:0]		HEX3;
output		     [6:0]		HEX4;
output		     [6:0]		HEX5;
output		     [6:0]		HEX6;
output		     [6:0]		HEX7;

//////////// LCD //////////
output		          		LCD_BLON;
inout 		     [7:0]		LCD_DATA;
output		          		LCD_EN;
output		          		LCD_ON;
output		          		LCD_RS;
output		          		LCD_RW;

//////////// Audio //////////
input 		          		AUD_ADCDAT;
input 		          		AUD_ADCLRCK;
input 		          		AUD_BCLK;
output		          		AUD_DACDAT;
input 		          		AUD_DACLRCK;
output		          		AUD_XCK;

//////////// I2C for Audio  //////////
output		          		I2C_SCLK;
inout 		          		I2C_SDAT;

//////////// SRAM //////////
output		    [19:0]		SRAM_ADDR;
output		          		SRAM_CE_N;
inout 		    [15:0]		SRAM_DQ;
output		          		SRAM_LB_N;
output		          		SRAM_OE_N;
output		          		SRAM_UB_N;
output		          		SRAM_WE_N;

//////////// Flash //////////
output		    [22:0]		FL_ADDR;
output		          		FL_CE_N;
inout 		     [7:0]		FL_DQ;
output		          		FL_OE_N;
output		          		FL_RST_N;
input 		          		FL_RY;
output		          		FL_WE_N;
output		          		FL_WP_N;

//=============================================================================
//  REG/WIRE declarations
//=============================================================================

// Reset & Clock signals
wire rst_n_0, rst_n_1, rst_n;
wire audio_clk;
wire pll_locked;

// Debounced button pulses
wire key1_pulse, key2_pulse, key3_pulse;
wire key1_deb, key2_deb, key3_deb;

// System FSM internal wires
wire [3:0]  fsm_state;
wire [7:0]  mode_code;
wire [7:0]  status_code;
wire [19:0] record_length_words;
wire [19:0] sram_addr_fsm;
wire [15:0] sram_wdata_fsm;
wire [15:0] sram_rdata_fsm;
wire        sram_we_n_fsm, sram_oe_n_fsm, sram_ce_n_fsm;
wire        sram_ub_n_fsm, sram_lb_n_fsm, sram_dq_oe_fsm;

wire [22:0] fl_addr_fsm;
wire [7:0]  fl_wdata_fsm;
wire [7:0]  fl_rdata_fsm;
wire        fl_ce_n_fsm, fl_oe_n_fsm, fl_we_n_fsm, fl_rst_n_fsm, fl_wp_n_fsm, fl_dq_oe_fsm;

wire        record_active, play_active;
wire        sample_valid_out;
wire signed [15:0] current_sample;
wire        clear_record_time, clear_play_time;
wire        audio_fifo_clear;

wire        flash_header_valid, sram_full, flash_error;

// Record/Play time in seconds
wire [6:0] record_seconds;
wire [6:0] play_seconds;

// Audio ADC/DAC internal signals
wire        adc_empty;
wire        adc_read;
wire [31:0] adc_data;
wire        adc_sample_tick;

wire        dac_full;
wire        dac_write;
wire [31:0] dac_data;
wire        dac_sample_tick;

// Debug LEDs
assign LEDG = {pll_locked, flash_header_valid, sram_full, flash_error, fsm_state[3:0], rst_n};

//=============================================================================
//  Structural coding
//=============================================================================

// 1. Reset Delay Sequencer
Reset_Delay u_reset_delay (
    .iCLK(CLOCK_50),
    .iRST(KEY[0]),
    .oRST_0(rst_n_0),
    .oRST_1(rst_n_1),
    .oRST_2(rst_n)
);

// 2. Audio PLL (50 MHz -> 18.4375 MHz)
audio_pll u_audio_pll (
    .areset(~KEY[0]),
    .inclk0(CLOCK_50),
    .c0(audio_clk),
    .locked(pll_locked)
);

assign AUD_XCK = audio_clk;

// 3. I2C Config (WM8731 registers initialization)
I2C_AV_Config u_i2c_av_config (
    .iCLK(CLOCK_50),
    .iRST_N(rst_n),
    .iSW_INPUT_SOURCE(SW[17]),
    .I2C_SCLK(I2C_SCLK),
    .I2C_SDAT(I2C_SDAT)
);

// 4. Audio ADC / DAC Interfaces
audio_adc_aligned u_audio_adc (
    .clk(CLOCK_50),
    .reset(~rst_n),
    .read(adc_read),
    .readdata(adc_data),
    .empty(adc_empty),
    .clear(audio_fifo_clear),
    .sample_tick(adc_sample_tick),
    .bclk(AUD_BCLK),
    .adclrc(AUD_ADCLRCK),
    .adcdat(AUD_ADCDAT)
);

audio_dac_aligned u_audio_dac (
    .clk(CLOCK_50),
    .reset(~rst_n),
    .write(dac_write),
    .writedata(dac_data),
    .full(dac_full),
    .clear(audio_fifo_clear),
    .sample_tick(dac_sample_tick),
    .bclk(AUD_BCLK),
    .daclrc(AUD_DACLRCK),
    .dacdat(AUD_DACDAT)
);

// 5. Button Debouncing & Edge Detection
key_debounce #(.DEBOUNCE_CYCLES(1_000_000)) u_key_deb1 (
    .clk(CLOCK_50),
    .rst_n(rst_n),
    .key_in(KEY[1]),
    .key_out(key1_deb)
);
one_pulse u_pulse1 (
    .clk(CLOCK_50),
    .rst_n(rst_n),
    .trigger(key1_deb),
    .pulse(key1_pulse)
);

key_debounce #(.DEBOUNCE_CYCLES(1_000_000)) u_key_deb2 (
    .clk(CLOCK_50),
    .rst_n(rst_n),
    .key_in(KEY[2]),
    .key_out(key2_deb)
);
one_pulse u_pulse2 (
    .clk(CLOCK_50),
    .rst_n(rst_n),
    .trigger(key2_deb),
    .pulse(key2_pulse)
);

key_debounce #(.DEBOUNCE_CYCLES(1_000_000)) u_key_deb3 (
    .clk(CLOCK_50),
    .rst_n(rst_n),
    .key_in(KEY[3]),
    .key_out(key3_deb)
);
one_pulse u_pulse3 (
    .clk(CLOCK_50),
    .rst_n(rst_n),
    .trigger(key3_deb),
    .pulse(key3_pulse)
);

// 6. System Controller FSM
system_fsm #(
    .SAMPLE_RATE_HZ(48000),
    .SRAM_MAX_ADDR(20'hFFFFF),
    .FLASH_HEADER_WORDS(16),
    .FLASH_AUDIO_BASE(23'd32)
) u_system_fsm (
    .clk(CLOCK_50),
    .rst_n(rst_n),
    .cancel_pulse(key3_pulse),
    .key1_pulse(key1_pulse),
    .key2_pulse(key2_pulse),
    .key3_pulse(key3_pulse),
    .sw(SW),
    .adc_empty(adc_empty),
    .adc_read(adc_read),
    .adc_data(adc_data),
    .dac_full(dac_full),
    .dac_sample_tick(dac_sample_tick),
    .dac_write(dac_write),
    .dac_data(dac_data),
    .audio_fifo_clear(audio_fifo_clear),
    
    // SRAM direct interface
    .sram_addr(sram_addr_fsm),
    .sram_wdata(sram_wdata_fsm),
    .sram_rdata(sram_rdata_fsm),
    .sram_we_n(sram_we_n_fsm),
    .sram_oe_n(sram_oe_n_fsm),
    .sram_ce_n(sram_ce_n_fsm),
    .sram_ub_n(sram_ub_n_fsm),
    .sram_lb_n(sram_lb_n_fsm),
    .sram_dq_oe(sram_dq_oe_fsm),
    
    // FLASH direct interface
    .fl_addr(fl_addr_fsm),
    .fl_wdata(fl_wdata_fsm),
    .fl_rdata(fl_rdata_fsm),
    .fl_ce_n(fl_ce_n_fsm),
    .fl_oe_n(fl_oe_n_fsm),
    .fl_we_n(fl_we_n_fsm),
    .fl_rst_n(fl_rst_n_fsm),
    .fl_wp_n(fl_wp_n_fsm),
    .fl_dq_oe(fl_dq_oe_fsm),
    .fl_ry(FL_RY),
    
    // Control / Status Outputs
    .fsm_state(fsm_state),
    .mode_code(mode_code),
    .status_code(status_code),
    .record_active(record_active),
    .play_active(play_active),
    .sample_valid_out(sample_valid_out),
    .current_sample(current_sample),
    .clear_record_time(clear_record_time),
    .clear_play_time(clear_play_time),
    
    .flash_header_valid(flash_header_valid),
    .sram_full(sram_full),
    .flash_error(flash_error),
    .record_length_words(record_length_words)
);

// 7. SRAM Control Bidirectional/Tri-state Buffers
assign SRAM_ADDR = sram_addr_fsm;
assign SRAM_CE_N = sram_ce_n_fsm;
assign SRAM_OE_N = sram_oe_n_fsm;
assign SRAM_WE_N = sram_we_n_fsm;
assign SRAM_UB_N = sram_ub_n_fsm;
assign SRAM_LB_N = sram_lb_n_fsm;
assign SRAM_DQ   = sram_dq_oe_fsm ? sram_wdata_fsm : 16'hZZZZ;
assign sram_rdata_fsm = SRAM_DQ;

// 8. FLASH Control Bidirectional/Tri-state Buffers
assign FL_ADDR  = fl_addr_fsm;
assign FL_CE_N  = fl_ce_n_fsm;
assign FL_OE_N  = fl_oe_n_fsm;
assign FL_WE_N  = fl_we_n_fsm;
assign FL_RST_N = fl_rst_n_fsm;
assign FL_WP_N  = fl_wp_n_fsm;
assign FL_DQ    = fl_dq_oe_fsm ? fl_wdata_fsm : 8'hZZ;
assign fl_rdata_fsm = FL_DQ;

// 9. LEDR Volume Meter (SW0 enable)
ledr_volume_meter u_volume_meter (
    .clk(CLOCK_50),
    .rst_n(rst_n),
    .enable(SW[0]),
    .sample_valid(sample_valid_out),
    .sample_in(current_sample),
    .ledr(LEDR)
);

// 10. Time Counter
record_time_counter #(.SAMPLE_RATE_HZ(48000)) u_time_counter (
    .clk(CLOCK_50),
    .rst_n(rst_n),
    .record_active(record_active),
    .play_active(play_active),
    .record_sample_tick(adc_sample_tick),
    .play_sample_tick(dac_sample_tick),
    .clear_record_time(clear_record_time),
    .clear_play_time(clear_play_time),
    .record_seconds(record_seconds),
    .play_seconds(play_seconds)
);

// 11. HEX Display Decoder and Multiplexer
wire [6:0] current_seconds;
assign current_seconds = play_active ? play_seconds : record_seconds;

hex_status_timer_display u_hex_display (
    .mode_code_bcd(mode_code),
    .status_code_bcd(status_code),
    .time_seconds(current_seconds),
    .flash_slot(SW[11:10]),
    .sw_input_source(SW[17]),
    .HEX0(HEX0),
    .HEX1(HEX1),
    .HEX2(HEX2),
    .HEX3(HEX3),
    .HEX4(HEX4),
    .HEX5(HEX5),
    .HEX6(HEX6),
    .HEX7(HEX7)
);

// 12. LCD Display Controller
assign LCD_ON = 1'b1;
assign LCD_BLON = 1'b1;

lcd_status_controller u_lcd_status (
    .clk(CLOCK_50),
    .rst_n(rst_n),
    .fsm_state(fsm_state),
    .record_seconds(record_seconds),
    .play_seconds(play_seconds),
    .sram_full(sram_full),
    .flash_error(flash_error),
    .flash_header_valid(flash_header_valid),
    .sw_input_source(SW[17]),
    .sw_flash_unlock(SW[3]),
    .LCD_DATA(LCD_DATA),
    .LCD_RW(LCD_RW),
    .LCD_EN(LCD_EN),
    .LCD_RS(LCD_RS)
);

endmodule
