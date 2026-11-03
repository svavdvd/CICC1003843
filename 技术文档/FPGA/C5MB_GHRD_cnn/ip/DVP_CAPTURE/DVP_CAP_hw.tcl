package require -exact qsys 16.1


# 
# module DVP_CAP
# 
set_module_property DESCRIPTION ""
set_module_property NAME DVP_CAP
set_module_property VERSION 1.0
set_module_property INTERNAL false
set_module_property OPAQUE_ADDRESS_MAP true
set_module_property GROUP CoreCourse
set_module_property AUTHOR ""
set_module_property DISPLAY_NAME DVP_CAP
set_module_property INSTANTIATE_IN_SYSTEM_MODULE true
set_module_property EDITABLE true
set_module_property REPORT_TO_TALKBACK false
set_module_property ALLOW_GREYBOX_GENERATION false
set_module_property REPORT_HIERARCHY false


# 
# file sets
# 
add_fileset QUARTUS_SYNTH QUARTUS_SYNTH "" ""
set_fileset_property QUARTUS_SYNTH TOP_LEVEL cmos_capture
set_fileset_property QUARTUS_SYNTH ENABLE_RELATIVE_INCLUDE_PATHS false
set_fileset_property QUARTUS_SYNTH ENABLE_FILE_OVERWRITE_MODE false
add_fileset_file cmos_capture.v VERILOG PATH cmos_capture.v TOP_LEVEL_FILE
add_fileset_file CMOS_Capture_RGB565.v VERILOG PATH CMOS_Capture_RGB565.v
add_fileset_file write_master.v VERILOG PATH write_master.v
add_fileset_file burst_write_master.v VERILOG PATH burst_write_master.v


# 
# parameters
# 
add_parameter DATAWIDTH INTEGER 16 "Width of the data path"
set_parameter_property DATAWIDTH DEFAULT_VALUE 16
set_parameter_property DATAWIDTH DISPLAY_NAME "Data Width"
set_parameter_property DATAWIDTH TYPE INTEGER
set_parameter_property DATAWIDTH UNITS None
set_parameter_property DATAWIDTH ALLOWED_RANGES {8 16 32 64 128 256 512 1024}
set_parameter_property DATAWIDTH DESCRIPTION "Width of the data path"
set_parameter_property DATAWIDTH HDL_PARAMETER true
add_parameter BYTEENABLEWIDTH INTEGER 2
set_parameter_property BYTEENABLEWIDTH DEFAULT_VALUE 2
set_parameter_property BYTEENABLEWIDTH DISPLAY_NAME BYTEENABLEWIDTH
set_parameter_property BYTEENABLEWIDTH TYPE INTEGER
set_parameter_property BYTEENABLEWIDTH UNITS None
set_parameter_property BYTEENABLEWIDTH ALLOWED_RANGES {2 4 6 8 16}
set_parameter_property BYTEENABLEWIDTH HDL_PARAMETER true
add_parameter ADDRESSWIDTH INTEGER 32 "Address Width"
set_parameter_property ADDRESSWIDTH DEFAULT_VALUE 32
set_parameter_property ADDRESSWIDTH DISPLAY_NAME "Address Width"
set_parameter_property ADDRESSWIDTH TYPE INTEGER
set_parameter_property ADDRESSWIDTH UNITS None
set_parameter_property ADDRESSWIDTH ALLOWED_RANGES {32 31 30 29 28 27 26 25 24 23 22 21 20 19 18 17 16 14 13 12 11 10 9 8 7 6 5 4}
set_parameter_property ADDRESSWIDTH DESCRIPTION "Address Width"
set_parameter_property ADDRESSWIDTH HDL_PARAMETER true
add_parameter BURST_CAPABLE INTEGER 0 "Enable bursting"
set_parameter_property BURST_CAPABLE DEFAULT_VALUE 0
set_parameter_property BURST_CAPABLE DISPLAY_NAME "Burst Capable"
set_parameter_property BURST_CAPABLE TYPE INTEGER
set_parameter_property BURST_CAPABLE UNITS None
set_parameter_property BURST_CAPABLE ALLOWED_RANGES {0:Disabled 1:Enabled}
set_parameter_property BURST_CAPABLE DESCRIPTION "Enable bursting"
set_parameter_property BURST_CAPABLE HDL_PARAMETER true
add_parameter MAXBURSTCOUNT INTEGER 2 "Maximum Burst Count"
set_parameter_property MAXBURSTCOUNT DEFAULT_VALUE 2
set_parameter_property MAXBURSTCOUNT DISPLAY_NAME "Maximum Burst Count"
set_parameter_property MAXBURSTCOUNT TYPE INTEGER
set_parameter_property MAXBURSTCOUNT UNITS None
set_parameter_property MAXBURSTCOUNT ALLOWED_RANGES {1 2 4 8 16 32 64 128}
set_parameter_property MAXBURSTCOUNT DESCRIPTION "Maximum Burst Count"
set_parameter_property MAXBURSTCOUNT HDL_PARAMETER true
add_parameter BURSTCOUNTWIDTH INTEGER 2 "Enable bursting"
set_parameter_property BURSTCOUNTWIDTH DEFAULT_VALUE 2
set_parameter_property BURSTCOUNTWIDTH DISPLAY_NAME "Burst Count Width"
set_parameter_property BURSTCOUNTWIDTH TYPE INTEGER
set_parameter_property BURSTCOUNTWIDTH UNITS None
set_parameter_property BURSTCOUNTWIDTH ALLOWED_RANGES {1 2 3 4 5 6 7 8}
set_parameter_property BURSTCOUNTWIDTH DESCRIPTION "Enable bursting"
set_parameter_property BURSTCOUNTWIDTH HDL_PARAMETER true
add_parameter FIFODEPTH INTEGER 512 "FIFO depth"
set_parameter_property FIFODEPTH DEFAULT_VALUE 512
set_parameter_property FIFODEPTH DISPLAY_NAME "FIFO Depth"
set_parameter_property FIFODEPTH TYPE INTEGER
set_parameter_property FIFODEPTH UNITS None
set_parameter_property FIFODEPTH ALLOWED_RANGES {4 8 16 32 64 128 256 512}
set_parameter_property FIFODEPTH DESCRIPTION "FIFO depth"
set_parameter_property FIFODEPTH AFFECTS_ELABORATION false
set_parameter_property FIFODEPTH HDL_PARAMETER true
add_parameter FIFODEPTH_LOG2 INTEGER 9 "log2(FIFO Depth)"
set_parameter_property FIFODEPTH_LOG2 DEFAULT_VALUE 9
set_parameter_property FIFODEPTH_LOG2 DISPLAY_NAME "log2(FIFO Depth)"
set_parameter_property FIFODEPTH_LOG2 TYPE INTEGER
set_parameter_property FIFODEPTH_LOG2 UNITS None
set_parameter_property FIFODEPTH_LOG2 ALLOWED_RANGES {2 3 4 5 6 7 8 9}
set_parameter_property FIFODEPTH_LOG2 DESCRIPTION "log2(FIFO Depth)"
set_parameter_property FIFODEPTH_LOG2 AFFECTS_ELABORATION false
set_parameter_property FIFODEPTH_LOG2 HDL_PARAMETER true
add_parameter FIFOUSEMEMORY INTEGER 1 "Select false if you want register based (0) FIFO instead of memory (1)"
set_parameter_property FIFOUSEMEMORY DEFAULT_VALUE 1
set_parameter_property FIFOUSEMEMORY DISPLAY_NAME "Memory based FIFO"
set_parameter_property FIFOUSEMEMORY TYPE INTEGER
set_parameter_property FIFOUSEMEMORY UNITS None
set_parameter_property FIFOUSEMEMORY ALLOWED_RANGES {1:Memory 0:Logic}
set_parameter_property FIFOUSEMEMORY DESCRIPTION "Select false if you want register based (0) FIFO instead of memory (1)"
set_parameter_property FIFOUSEMEMORY AFFECTS_ELABORATION false
set_parameter_property FIFOUSEMEMORY HDL_PARAMETER true


# 
# display items
# 
add_display_item "" "Avalon-MM Master Properties" GROUP ""
add_display_item "Avalon-MM Master Properties" DATAWIDTH PARAMETER ""
add_display_item "Avalon-MM Master Properties" ADDRESSWIDTH PARAMETER ""
add_display_item "" "Burst Properties" GROUP ""
add_display_item "Burst Properties" BURST_CAPABLE PARAMETER ""
add_display_item "Burst Properties" MAXBURSTCOUNT PARAMETER ""
add_display_item "Burst Properties" BURSTCOUNTWIDTH PARAMETER ""
add_display_item "" "Other Properties" GROUP ""
add_display_item "Other Properties" FIFODEPTH PARAMETER ""
add_display_item "Other Properties" FIFODEPTH_LOG2 PARAMETER ""
add_display_item "Other Properties" FIFOUSEMEMORY PARAMETER ""


# 
# connection point clock
# 
add_interface clock clock end
set_interface_property clock clockRate 0
set_interface_property clock ENABLED true
set_interface_property clock EXPORT_OF ""
set_interface_property clock PORT_NAME_MAP ""
set_interface_property clock CMSIS_SVD_VARIABLES ""
set_interface_property clock SVD_ADDRESS_GROUP ""

add_interface_port clock clk clk Input 1


# 
# connection point clock_cmos
# 
add_interface clock_cmos clock end
set_interface_property clock_cmos clockRate 0
set_interface_property clock_cmos ENABLED true
set_interface_property clock_cmos EXPORT_OF ""
set_interface_property clock_cmos PORT_NAME_MAP ""
set_interface_property clock_cmos CMSIS_SVD_VARIABLES ""
set_interface_property clock_cmos SVD_ADDRESS_GROUP ""

add_interface_port clock_cmos clk_cmos clk Input 1


# 
# connection point reset
# 
add_interface reset reset end
set_interface_property reset associatedClock clock
set_interface_property reset synchronousEdges DEASSERT
set_interface_property reset ENABLED true
set_interface_property reset EXPORT_OF ""
set_interface_property reset PORT_NAME_MAP ""
set_interface_property reset CMSIS_SVD_VARIABLES ""
set_interface_property reset SVD_ADDRESS_GROUP ""

add_interface_port reset reset_i reset Input 1


# 
# connection point wire
# 
add_interface wire conduit end
set_interface_property wire associatedClock ""
set_interface_property wire associatedReset ""
set_interface_property wire ENABLED true
set_interface_property wire EXPORT_OF ""
set_interface_property wire PORT_NAME_MAP ""
set_interface_property wire CMSIS_SVD_VARIABLES ""
set_interface_property wire SVD_ADDRESS_GROUP ""

add_interface_port wire cmos_pclk cmos_pclk Input 1
add_interface_port wire cmos_xclk cmos_xclk Output 1
add_interface_port wire cmos_vsync cmos_vsync Input 1
add_interface_port wire cmos_href cmos_href Input 1
add_interface_port wire cmos_din cmos_din Input 8
add_interface_port wire cmos_pwdn cmos_pwdn Output 1
add_interface_port wire cmos_rst_n cmos_rst_n Output 1


# 
# connection point avalon_slave
# 
add_interface avalon_slave avalon end
set_interface_property avalon_slave addressUnits WORDS
set_interface_property avalon_slave associatedClock clock
set_interface_property avalon_slave associatedReset reset
set_interface_property avalon_slave bitsPerSymbol 8
set_interface_property avalon_slave burstOnBurstBoundariesOnly false
set_interface_property avalon_slave burstcountUnits WORDS
set_interface_property avalon_slave explicitAddressSpan 0
set_interface_property avalon_slave holdTime 0
set_interface_property avalon_slave linewrapBursts false
set_interface_property avalon_slave maximumPendingReadTransactions 0
set_interface_property avalon_slave maximumPendingWriteTransactions 0
set_interface_property avalon_slave readLatency 0
set_interface_property avalon_slave readWaitTime 1
set_interface_property avalon_slave setupTime 0
set_interface_property avalon_slave timingUnits Cycles
set_interface_property avalon_slave writeWaitTime 0
set_interface_property avalon_slave ENABLED true
set_interface_property avalon_slave EXPORT_OF ""
set_interface_property avalon_slave PORT_NAME_MAP ""
set_interface_property avalon_slave CMSIS_SVD_VARIABLES ""
set_interface_property avalon_slave SVD_ADDRESS_GROUP ""

add_interface_port avalon_slave as_chipselect chipselect Input 1
add_interface_port avalon_slave as_write write Input 1
add_interface_port avalon_slave as_readdata readdata Output 32
add_interface_port avalon_slave as_writedata writedata Input 32
add_interface_port avalon_slave as_address address Input 3
add_interface_port avalon_slave as_read read Input 1
set_interface_assignment avalon_slave embeddedsw.configuration.isFlash 0
set_interface_assignment avalon_slave embeddedsw.configuration.isMemoryDevice 0
set_interface_assignment avalon_slave embeddedsw.configuration.isNonVolatileStorage 0
set_interface_assignment avalon_slave embeddedsw.configuration.isPrintableDevice 0


# 
# connection point avalon_master
# 
add_interface avalon_master avalon start
set_interface_property avalon_master addressUnits SYMBOLS
set_interface_property avalon_master associatedClock clock
set_interface_property avalon_master associatedReset reset
set_interface_property avalon_master bitsPerSymbol 8
set_interface_property avalon_master burstOnBurstBoundariesOnly false
set_interface_property avalon_master burstcountUnits WORDS
set_interface_property avalon_master doStreamReads false
set_interface_property avalon_master doStreamWrites false
set_interface_property avalon_master holdTime 0
set_interface_property avalon_master linewrapBursts false
set_interface_property avalon_master maximumPendingReadTransactions 0
set_interface_property avalon_master maximumPendingWriteTransactions 0
set_interface_property avalon_master readLatency 0
set_interface_property avalon_master readWaitTime 1
set_interface_property avalon_master setupTime 0
set_interface_property avalon_master timingUnits Cycles
set_interface_property avalon_master writeWaitTime 0
set_interface_property avalon_master ENABLED true
set_interface_property avalon_master EXPORT_OF ""
set_interface_property avalon_master PORT_NAME_MAP ""
set_interface_property avalon_master CMSIS_SVD_VARIABLES ""
set_interface_property avalon_master SVD_ADDRESS_GROUP ""

add_interface_port avalon_master am_write write Output 1
add_interface_port avalon_master am_waitrequest waitrequest Input 1
add_interface_port avalon_master am_writedata writedata Output 16
add_interface_port avalon_master am_address address Output 32
add_interface_port avalon_master am_burstcount burstcount Output 2

