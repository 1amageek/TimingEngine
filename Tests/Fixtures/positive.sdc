create_clock -name clk -period 10ns [get_ports clk]
set_input_delay 1ns -clock clk [get_ports in]
set_output_delay 2ns -clock clk [get_ports out]
