# Replace the opaque cnn_top QXP with the project-owned pure-Verilog engine.
# Run from the Quartus project root with the project ip/ directory on the
# Platform Designer search path.

package require -exact qsys 18.1

proc ensure_connection {start_interface end_interface} {
    set connection "$start_interface/$end_interface"
    if {[lsearch -exact [get_connections] $connection] < 0} {
        add_connection $start_interface $end_interface
    }
}

load_system soc_system.qsys

if {[lsearch -exact [get_instances] cnn_top_0] >= 0} {
    remove_instance cnn_top_0
}

if {[lsearch -exact [get_instances] pure_cnn_accel_0] < 0} {
    add_instance pure_cnn_accel_0 pure_cnn_accel 1.0
}

# Preserve the software-visible accelerator base at 0xFF200000. The custom
# slave occupies 0x000-0x3ff relative to the lightweight HPS bridge.
ensure_connection mm_bridge_0.m0 pure_cnn_accel_0.avalon_slave
set_connection_parameter_value \
    mm_bridge_0.m0/pure_cnn_accel_0.avalon_slave baseAddress 0x00000000

ensure_connection mm_bridge_0.m0 sort_control_0.avalon_slave
set_connection_parameter_value \
    mm_bridge_0.m0/sort_control_0.avalon_slave baseAddress 0x00000800

ensure_connection mm_bridge_0.m0 sysid_qsys.control_slave
set_connection_parameter_value \
    mm_bridge_0.m0/sysid_qsys.control_slave baseAddress 0x00000C00

# Activation and parameter traffic are independent read masters. Output is a
# dedicated write master. Platform Designer arbitrates all three onto the HPS
# FPGA-to-SDRAM port.
foreach master {activation_master parameter_master output_master} {
    ensure_connection pure_cnn_accel_0.$master mm_bridge_sdram0.s0
    set_connection_parameter_value \
        pure_cnn_accel_0.$master/mm_bridge_sdram0.s0 baseAddress 0x00000000
}

ensure_connection mm_bridge_sdram0.m0 hps_0.f2h_sdram0_data
set_connection_parameter_value \
    mm_bridge_sdram0.m0/hps_0.f2h_sdram0_data baseAddress 0x00000000

# Keep the already timing-closed 70 MHz CNN/SDRAM clock domain.
ensure_connection pll_1_cnn.outclk0 pure_cnn_accel_0.clock
ensure_connection clk_0.clk_reset pure_cnn_accel_0.reset
ensure_connection pll_1_cnn.outclk0 mm_bridge_sdram0.clk
ensure_connection clk_0.clk_reset mm_bridge_sdram0.reset

save_system soc_system.qsys
