create_clock -name clk -period 10ns [get_ports clk]
set_clock_groups -asynchronous -group [get_clocks clk]
