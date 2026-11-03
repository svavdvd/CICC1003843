package require ::quartus::project
package require ::quartus::sta

set project_name C5MB_top
set report_file [file join output_files cnn_critical_paths.rpt]

project_open -revision $project_name $project_name
create_timing_netlist
read_sdc
update_timing_netlist

set cnn_clock [get_clocks {*pll_1_cnn*PLL_OUTPUT_COUNTER*divclk}]
if {[get_collection_size $cnn_clock] != 1} {
    post_message -type error "Expected one CNN clock, found [get_collection_size $cnn_clock]"
    delete_timing_netlist
    project_close
    qexit -error
}

report_timing \
    -setup \
    -npaths 20 \
    -detail full_path \
    -from $cnn_clock \
    -to $cnn_clock \
    -panel_name {CNN Critical Setup Paths} \
    -file $report_file

delete_timing_netlist
project_close
