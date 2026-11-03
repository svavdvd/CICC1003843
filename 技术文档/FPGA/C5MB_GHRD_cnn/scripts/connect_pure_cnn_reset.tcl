package require -exact qsys 18.1

load_system soc_system.qsys

set reset_connection "clk_0.clk_reset/pure_cnn_engine_0.reset"
if {[lsearch -exact [get_connections] $reset_connection] < 0} {
    add_connection clk_0.clk_reset pure_cnn_engine_0.reset
}

save_system soc_system.qsys
