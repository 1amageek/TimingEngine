create_clock -name clk -period 10ns [get_ports in]
set_input_delay 1ns -clock clk [get_ports in]
set_output_delay 2ns -clock clk [get_ports out]
group_path -name io_paths -from [get_ports in] -to [get_ports out] -weight 1
