package require -exact qsys 18.1

load_system soc_system.qsys

set wrong_connection "pure_cnn_engine_0.irq/hps_0.f2h_irq0"
if {[lsearch -exact [get_connections] $wrong_connection] >= 0} {
    remove_connection $wrong_connection
}

set correct_connection "hps_0.f2h_irq0/pure_cnn_engine_0.irq"
if {[lsearch -exact [get_connections] $correct_connection] < 0} {
    add_connection hps_0.f2h_irq0 pure_cnn_engine_0.irq
}

save_system soc_system.qsys
