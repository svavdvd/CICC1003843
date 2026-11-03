package require -exact qsys 18.1
load_system soc_system.qsys
send_message info "validation commands: [lsort [info commands *valid*]]"
if {[lsearch -exact [info commands] validate_system] >= 0} {
    validate_system
    send_message info "validate_system completed"
}
