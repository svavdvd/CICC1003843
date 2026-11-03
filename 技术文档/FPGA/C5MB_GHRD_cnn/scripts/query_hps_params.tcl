package require -exact qsys 18.1

load_system soc_system.qsys

foreach parameter {UART0_Mode UART0_PinMuxing USB1_Mode USB1_PinMuxing} {
    puts "PARAMETER $parameter"
    puts "  value=[get_instance_parameter_value hps_0 $parameter]"
    foreach property {TYPE ALLOWED_RANGES VISIBLE ENABLED} {
        if {[catch {
            set value [get_instance_parameter_property hps_0 $parameter $property]
        } message]} {
            puts "  $property=<error: $message>"
        } else {
            puts "  $property=$value"
        }
    }
}

puts "PARAMETER_COMMANDS [lsort [info commands *parameter*]]"
