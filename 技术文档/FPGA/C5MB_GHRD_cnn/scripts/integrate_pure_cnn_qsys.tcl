# Canonical C5MB Platform Designer integration for the project-owned
# pure-Verilog CNN engine and PL sorting controller.

package require -exact qsys 18.1

proc instance_exists {name} {
    expr {[lsearch -exact [get_instances] $name] >= 0}
}

proc remove_instance_if_present {name} {
    if {[instance_exists $name]} {
        remove_instance $name
    }
}

proc connection_exists {source sink} {
    expr {[lsearch -exact [get_connections] "$source/$sink"] >= 0}
}

proc remove_connection_if_present {source sink} {
    if {[connection_exists $source $sink]} {
        remove_connection "$source/$sink"
    }
}

proc connect_once {source sink} {
    if {![connection_exists $source $sink]} {
        add_connection $source $sink
    }
}

proc set_base {source sink address} {
    set_connection_parameter_value "$source/$sink" baseAddress $address
}

load_system soc_system.qsys

# Application traffic leaves the FPGA board through HPS EMAC1 only. Camera,
# pump, alarm and arm interfaces are owned by the Raspberry Pi.
set_instance_parameter_value hps_0 UART0_PinMuxing Unused
set_instance_parameter_value hps_0 UART0_Mode {N/A}
set_instance_parameter_value hps_0 USB1_PinMuxing Unused
set_instance_parameter_value hps_0 USB1_Mode {N/A}

foreach legacy_instance {DVP_CAP_0 clock_bridge_24} {
    remove_instance_if_present $legacy_instance
}

if {![instance_exists sort_control_0]} {
    add_instance sort_control_0 sort_control 1.0
}
if {![instance_exists mm_bridge_sdram0]} {
    add_instance mm_bridge_sdram0 altera_avalon_mm_bridge 18.1
}
foreach {name value} {
    ADDRESS_UNITS SYMBOLS
    ADDRESS_WIDTH 32
    DATA_WIDTH 128
    LINEWRAPBURSTS 0
    MAX_BURST_SIZE 16
    MAX_PENDING_RESPONSES 4
    PIPELINE_COMMAND 1
    PIPELINE_RESPONSE 1
    SYMBOL_WIDTH 8
    SYSINFO_ADDR_WIDTH 32
    USE_AUTO_ADDRESS_WIDTH 0
    USE_RESPONSE 0
} {
    set_instance_parameter_value mm_bridge_sdram0 $name $value
}

if {![instance_exists pll_1_cnn]} {
    add_instance pll_1_cnn altera_pll 18.1
}
foreach {name value} {
    device 5CSEBA6U23I7
    device_family {Cyclone V}
    gui_number_of_clocks 1
    gui_operation_mode direct
    gui_reference_clock_frequency 50.0
    gui_output_clock_frequency0 70.0
    gui_duty_cycle0 50
    gui_phase_shift0 0
    gui_use_locked false
} {
    set_instance_parameter_value pll_1_cnn $name $value
}

# Recreate the accelerator so this script is idempotent across the official
# QXP design, earlier development revisions and the current pure RTL design.
foreach accelerator {cnn_top_0 pure_cnn_accel_0 pure_cnn_engine_0} {
    remove_instance_if_present $accelerator
}
add_instance pure_cnn_engine_0 pure_cnn_engine 1.0

connect_once mm_bridge_0.m0 pure_cnn_engine_0.avalon_slave
set_base mm_bridge_0.m0 pure_cnn_engine_0.avalon_slave 0x00000000
connect_once mm_bridge_0.m0 sort_control_0.avalon_slave
set_base mm_bridge_0.m0 sort_control_0.avalon_slave 0x00000800
connect_once mm_bridge_0.m0 sysid_qsys.control_slave
set_base mm_bridge_0.m0 sysid_qsys.control_slave 0x00000C00

foreach master {activation_master parameter_master output_master} {
    connect_once pure_cnn_engine_0.$master mm_bridge_sdram0.s0
    set_base pure_cnn_engine_0.$master mm_bridge_sdram0.s0 0x00000000
}
connect_once mm_bridge_sdram0.m0 hps_0.f2h_sdram0_data
set_base mm_bridge_sdram0.m0 hps_0.f2h_sdram0_data 0x00000000

connect_once clk_0.clk pll_1_cnn.refclk
connect_once pll_1_cnn.outclk0 mm_bridge_sdram0.clk
connect_once pll_1_cnn.outclk0 pure_cnn_engine_0.clock
connect_once clk_0.clk_reset pll_1_cnn.reset
connect_once clk_0.clk_reset mm_bridge_sdram0.reset
connect_once clk_0.clk_reset pure_cnn_engine_0.reset
connect_once clk_0.clk sort_control_0.clock
connect_once clk_0.clk_reset sort_control_0.reset

# Qsys represents the HPS interrupt receiver first in the connection name.
remove_connection_if_present pure_cnn_engine_0.irq hps_0.f2h_irq0
connect_once hps_0.f2h_irq0 pure_cnn_engine_0.irq

save_system soc_system.qsys
