package require -exact qsys 18.1
load_system soc_system.qsys
if {[catch {remove_connection clk_0.clk/hps_0.f2h_sdram0_clock} message]} {
    send_message error "one-argument remove_connection failed: $message"
} else {
    send_message info "one-argument remove_connection succeeded"
}
