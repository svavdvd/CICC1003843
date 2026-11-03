#**************************************************************
# This .sdc file is created by Terasic Tool.
# Users are recommended to modify this file to match users logic.
#**************************************************************

#**************************************************************
# Create Clock
#**************************************************************
create_clock -period 20.0 [get_ports FPGA_CLK1_50]
##create_clock -period 20.0 [get_ports FPGA_CLK2_50]


#**************************************************************
# Create Generated Clock
#**************************************************************
derive_pll_clocks


#**************************************************************
# Set Clock Latency
#**************************************************************



#**************************************************************
# Set Clock Uncertainty
#**************************************************************
derive_clock_uncertainty


#**************************************************************
# Set Input Delay
#**************************************************************



#**************************************************************
# Set Output Delay
#**************************************************************



#**************************************************************
# Set Clock Groups
#**************************************************************



#**************************************************************
# Set False Path
#**************************************************************

# Dedicated HPS EMAC, SDMMC, and GPIO pins bypass FPGA fabric timing.
# The generated HPS border SDC uses pre-wrapper port names, so mirror
# those exceptions here for the board-level top-level names.
set hps_io_inputs [get_ports -nowarn {HPS_ENET_RX_CLK HPS_ENET_RX_DATA[*] HPS_ENET_RX_DV HPS_ENET_MDIO HPS_ENET_INT_n HPS_SDMMC_CMD HPS_SDMMC_DATA[*] HPS_EMMC_SEL}]
if {[get_collection_size $hps_io_inputs] > 0} {
    set_false_path -from $hps_io_inputs
}

set hps_io_outputs [get_ports -nowarn {HPS_ENET_GTX_CLK HPS_ENET_MDC HPS_ENET_MDIO HPS_ENET_TX_DATA[*] HPS_ENET_TX_EN HPS_ENET_INT_n HPS_SDMMC_CLK HPS_SDMMC_CMD HPS_SDMMC_DATA[*] HPS_EMMC_RST_n HPS_EMMC_SEL}]
if {[get_collection_size $hps_io_outputs] > 0} {
    set_false_path -to $hps_io_outputs
}

# Reserved JTAG data pins are asynchronous to user logic.
set reserved_jtag_inputs [get_ports -nowarn {altera_reserved_tdi altera_reserved_tms}]
if {[get_collection_size $reserved_jtag_inputs] > 0} {
    set_false_path -from $reserved_jtag_inputs
}
set reserved_jtag_outputs [get_ports -nowarn {altera_reserved_tdo}]
if {[get_collection_size $reserved_jtag_outputs] > 0} {
    set_false_path -to $reserved_jtag_outputs
}

#**************************************************************
# Set Multicycle Path
#**************************************************************



#**************************************************************
# Set Maximum Delay
#**************************************************************



#**************************************************************
# Set Minimum Delay
#**************************************************************



#**************************************************************
# Set Input Transition
#**************************************************************



#**************************************************************
# Set Load
#**************************************************************



