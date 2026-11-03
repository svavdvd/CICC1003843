set_global_assignment -entity "pll_tv" -library "lib_pll_tv" -name IP_TOOL_NAME "altera_pll"
set_global_assignment -entity "pll_tv" -library "lib_pll_tv" -name IP_TOOL_VERSION "18.1"
set_global_assignment -entity "pll_tv" -library "lib_pll_tv" -name IP_TOOL_ENV "mwpim"
set_global_assignment -library "lib_pll_tv" -name SPD_FILE [file join $::quartus(sip_path) "pll_tv.spd"]

set_global_assignment -library "lib_pll_tv" -name MISC_FILE [file join $::quartus(sip_path) "pll_tv_sim/pll_tv.vo"]
