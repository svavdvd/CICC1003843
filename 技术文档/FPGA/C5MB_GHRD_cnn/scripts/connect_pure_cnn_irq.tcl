package require -exact qsys 18.1

load_system soc_system.qsys

set irq_connection "pure_cnn_engine_0.irq/hps_0.f2h_irq0"
if {[lsearch -exact [get_connections] $irq_connection] < 0} {
    add_connection pure_cnn_engine_0.irq hps_0.f2h_irq0
}

save_system soc_system.qsys
