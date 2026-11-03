package require -exact qsys 18.1

set system_file soc_system.qsys
load_system $system_file

proc remove_if_present {instance_name} {
    if {[lsearch -exact [get_instances] $instance_name] >= 0} {
        remove_instance $instance_name
    }
}

proc connect_once {source sink} {
    set connection "$source/$sink"
    if {[lsearch -exact [get_connections] $connection] < 0} {
        add_connection $source $sink
    }
}

proc set_base {source sink base_address} {
    set connection "$source/$sink"
    set_connection_parameter_value $connection baseAddress $base_address
}

remove_if_present cnn_top_0
remove_if_present pure_cnn_accel_0
remove_if_present pure_cnn_engine_0

add_instance pure_cnn_engine_0 pure_cnn_engine 1.0

connect_once pll_1_cnn.outclk0 pure_cnn_engine_0.clock
connect_once rst_controller_0.reset_out pure_cnn_engine_0.reset
connect_once mm_bridge_0.m0 pure_cnn_engine_0.avalon_slave
connect_once pure_cnn_engine_0.activation_master mm_bridge_sdram0.s0
connect_once pure_cnn_engine_0.parameter_master mm_bridge_sdram0.s0
connect_once pure_cnn_engine_0.output_master mm_bridge_sdram0.s0

set_base mm_bridge_0.m0 pure_cnn_engine_0.avalon_slave 0x0000
if {[lsearch -exact [get_instances] sort_control_0] >= 0} {
    set_base mm_bridge_0.m0 sort_control_0.avalon_slave 0x0800
}
if {[lsearch -exact [get_instances] sysid_qsys_0] >= 0} {
    set_base mm_bridge_0.m0 sysid_qsys_0.control_slave 0x0C00
}

save_system $system_file
