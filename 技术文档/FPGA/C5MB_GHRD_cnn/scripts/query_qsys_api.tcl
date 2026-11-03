package require -exact qsys 18.1
load_system soc_system.qsys
send_message info "connection commands: [lsort [info commands *connection*]]"
send_message info "instance commands: [lsort [info commands *instance*]]"
send_message info "connections: [get_connections]"
