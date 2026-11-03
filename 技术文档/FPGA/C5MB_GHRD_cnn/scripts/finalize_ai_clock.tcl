package require -exact qsys 18.1

load_system soc_system.qsys

# Match the proven 2023 accelerator memory interface width.
set_instance_parameter_value hps_0 F2SDRAM_Width 128

set old_clock clk_0.clk/hps_0.f2h_sdram0_clock
set new_clock pll_1_cnn.outclk0/hps_0.f2h_sdram0_clock

if {[lsearch -exact [get_connections] $old_clock] >= 0} {
    remove_connection $old_clock
}
if {[lsearch -exact [get_connections] $new_clock] < 0} {
    add_connection pll_1_cnn.outclk0 hps_0.f2h_sdram0_clock
}

save_system soc_system.qsys
