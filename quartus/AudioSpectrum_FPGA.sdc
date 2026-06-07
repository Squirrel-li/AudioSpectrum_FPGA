#**************************************************************
# This .sdc file is created by Terasic Tool.
# Users are recommended to modify this file to match users logic.
#**************************************************************

#**************************************************************
# Create Clock
#**************************************************************
create_clock -period 20 [get_ports CLOCK_50]
create_clock -period 20 [get_ports CLOCK2_50]
create_clock -period 20 [get_ports CLOCK3_50]

# WM8731 runs the audio serial interface in codec-master mode for this design.
# AUD_BCLK is therefore an external input clock used by the audio FIFO logic.
# 48 kHz stereo, 32 bits per channel => 64 BCLKs/sample => 3.072 MHz.
create_clock -name AUD_BCLK -period 325.520 [get_ports AUD_BCLK]
create_clock -name AUD_ADCLRCK -period 20833.333 [get_ports AUD_ADCLRCK]
create_clock -name AUD_DACLRCK -period 20833.333 [get_ports AUD_DACLRCK]

# I2C_AV_Config divides CLOCK_50 into mI2C_CTRL_CLK by toggling after
# CLK_Freq/I2C_Freq counts. With 50 MHz / 20 kHz this is about 10 kHz.
create_clock -name I2C_CTRL_CLK -period 100040.000 [get_registers {*|mI2C_CTRL_CLK}]

#**************************************************************
# Create Generated Clock
#**************************************************************
derive_pll_clocks

# Keep the codec bit-clock domain independent from the 50 MHz/PLL system
# clocks; the audio IP crosses domains through FIFOs.
set_clock_groups -asynchronous \
    -group [get_clocks {CLOCK_50 CLOCK2_50 CLOCK3_50}] \
    -group [get_clocks {AUD_BCLK AUD_ADCLRCK AUD_DACLRCK}] \
    -group [get_clocks {I2C_CTRL_CLK}]



#**************************************************************
# Set Clock Latency
#**************************************************************



#**************************************************************
# Set Clock Uncertainty
#**************************************************************
derive_clock_uncertainty



#**************************************************************
# Set Input Delay
#**************************************************************



#**************************************************************
# Set Output Delay
#**************************************************************



#**************************************************************
# Set Clock Groups
#**************************************************************



#**************************************************************
# Set False Path
#**************************************************************



#**************************************************************
# Set Multicycle Path
#**************************************************************



#**************************************************************
# Set Maximum Delay
#**************************************************************



#**************************************************************
# Set Minimum Delay
#**************************************************************



#**************************************************************
# Set Input Transition
#**************************************************************



#**************************************************************
# Set Load
#**************************************************************



