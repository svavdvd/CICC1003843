package require -exact qsys 18.1
send_message info "module commands: [lsort [info commands *module*]]"
send_message info "component commands: [lsort [info commands *component*]]"
send_message info "instance commands: [lsort [info commands *instance*]]"
