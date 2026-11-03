# Integrate the 2023 cnn_top accelerator into the official C5MB system.
# Run from the Quartus project root through scripts/build_fpga.ps1.

package require -exact qsys 18.1

proc ensure_connection {start_interface end_interface} {
    set connection "$start_interface/$end_interface"
    if {[lsearch -exact [get_connections] $connection] < 0} {
        add_connection $start_interface $end_interface
    }
}

load_system soc_system.qsys

# The FPGA board exchanges application data with the Raspberry Pi only through
# HPS EMAC1. Disable unused HPS USB/UART pin muxing at the source.
set_instance_parameter_value hps_0 UART0_PinMuxing Unused
set_instance_parameter_value hps_0 UART0_Mode {N/A}
set_instance_parameter_value hps_0 USB1_PinMuxing Unused
set_instance_parameter_value hps_0 USB1_Mode {N/A}

# The competition camera is USB-connected to Raspberry Pi. Remove the legacy
# OV5640 DVP capture path so Ethernet is the only application data link.
foreach legacy_instance {DVP_CAP_0 clock_bridge_24} {
    if {[lsearch -exact [get_instances] $legacy_instance] >= 0} {
        remove_instance $legacy_instance
    }
}

if {[lsearch -exact [get_instances] sort_control_0] < 0} {
    add_instance sort_control_0 sort_control 1.0
}

if {[lsearch -exact [get_instances] cnn_top_0] < 0} {
    add_instance cnn_top_0 cnn_top 2.0
}

foreach {name value} {
    CFG_M_AXI_ADDR_WIDTH 32
    CFG_M_AXI_DATA_WIDTH 32
    CFG_PARAM_WIDTH 32
    CNN_RELU_WIDTH 3
    CNN_STRIDE_WIDTH 2
    CNN_TYPE_WIDTH 3
    IMAGE_MAX_W 302
    INPUT_CHANNEL_TILE 8
    INPUT_PAD_WIDTH 2
    INPUT_RAM_DATA_WIDTH 64
    INPUT_ROW_TILE 11
    INPUT_WIDTH 8
    IN_C_WIDTH 11
    IN_H_WIDTH 9
    IN_W_WIDTH 9
    KERNAL_SIZE 9
    KERNEL_SIZE_WIDTH 4
    KERNEL_WIDTH 2
    LOAD_M_AXI_ADDR_WIDTH 32
    LOAD_M_AXI_DATA_WIDTH 64
    OUTPUT_ADDR_WIDTH 10
    OUTPUT_CHANNEL_TILE 8
    OUTPUT_C_WIDTH 11
    OUTPUT_H_WIDTH 9
    OUTPUT_MAX_W 150
    OUTPUT_M_AXI_ADDR_WIDTH 32
    OUTPUT_M_AXI_DATA_WIDTH 64
    OUTPUT_PAD_WIDTH 2
    OUTPUT_ROW_TILE 5
    OUTPUT_WIDTH 32
    OUTPUT_W_WIDTH 9
    REORGANIZE_BUFF_DEEP 2048
    REORG_M_AXI_ADDR_WIDTH 32
    REORG_M_AXI_DATA_WIDTH 8
    REORG_RAM_ADDR_WIDTH 7
    REORG_RAM_DATA_WIDTH 128
    REORG_RAM_SEL_WIDTH 16
    SCALE_6 1086324736
    SCALE_M_AXI_ADDR_WIDTH 32
    SCALE_M_AXI_DATA_WIDTH 32
    WEIGHT_WIDTH 8
} {
    set_instance_parameter_value cnn_top_0 $name $value
}

if {[lsearch -exact [get_instances] mm_bridge_sdram0] < 0} {
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

if {[lsearch -exact [get_instances] pll_1_cnn] < 0} {
    add_instance pll_1_cnn altera_pll 18.1
}

# The packaged QXP fails slow-corner timing at 150 MHz in this C5MB design.
# A full C5MB compile closes timing at the 70 MHz competition target.
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

# The FPGA image's ARM32 NNA SDK hard-codes the CNN register base to
# 0xFF200000. The slave spans 0x000-0x3ff, so move SYSID out of that window.
ensure_connection mm_bridge_0.m0 cnn_top_0.hps2cnn_avs
set_connection_parameter_value mm_bridge_0.m0/cnn_top_0.hps2cnn_avs baseAddress 0x00000000

ensure_connection mm_bridge_0.m0 sysid_qsys.control_slave
set_connection_parameter_value mm_bridge_0.m0/sysid_qsys.control_slave baseAddress 0x00000C00

# HPS submits canonical detections to the PL-owned sorting state machine.
ensure_connection mm_bridge_0.m0 sort_control_0.avalon_slave
set_connection_parameter_value mm_bridge_0.m0/sort_control_0.avalon_slave baseAddress 0x00000800

foreach master {
    load_read_avalon
    output_read_avalon
    param_read_avalon
    scale_avm_avalon
} {
    ensure_connection cnn_top_0.$master mm_bridge_sdram0.s0
    set_connection_parameter_value cnn_top_0.$master/mm_bridge_sdram0.s0 baseAddress 0x00000000
}
ensure_connection mm_bridge_sdram0.m0 hps_0.f2h_sdram0_data
set_connection_parameter_value mm_bridge_sdram0.m0/hps_0.f2h_sdram0_data baseAddress 0x00000000

ensure_connection clk_0.clk pll_1_cnn.refclk
ensure_connection pll_1_cnn.outclk0 cnn_top_0.clock_1
ensure_connection pll_1_cnn.outclk0 mm_bridge_sdram0.clk
ensure_connection clk_0.clk_reset pll_1_cnn.reset
ensure_connection clk_0.clk_reset cnn_top_0.reset
ensure_connection clk_0.clk_reset mm_bridge_sdram0.reset
ensure_connection clk_0.clk sort_control_0.clock
ensure_connection clk_0.clk_reset sort_control_0.reset

save_system soc_system.qsys
