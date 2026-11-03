module sort_control (
    input  wire        clk,
    input  wire        reset,
    input  wire [5:0]  avs_address,
    input  wire        avs_read,
    output reg  [31:0] avs_readdata,
    input  wire        avs_write,
    input  wire [31:0] avs_writedata,
    input  wire [3:0]  avs_byteenable
);

localparam [31:0] IP_ID      = 32'h534F5254;
localparam [31:0] IP_VERSION = 32'h0001_0000;

localparam [2:0] DECISION_UNKNOWN = 3'd0;
localparam [2:0] DECISION_OK      = 3'd1;
localparam [2:0] DECISION_NG      = 3'd2;

localparam [2:0] ACTION_HOLD       = 3'd0;
localparam [2:0] ACTION_SORT_RIGHT = 3'd1;
localparam [2:0] ACTION_SORT_LEFT  = 3'd2;

localparam [3:0] STATE_DISABLED = 4'd0;
localparam [3:0] STATE_READY    = 4'd1;
localparam [3:0] STATE_COLLECT  = 4'd2;
localparam [3:0] STATE_COMMAND  = 4'd3;
localparam [3:0] STATE_FAULT    = 4'd4;

localparam [3:0] FAULT_NONE         = 4'd0;
localparam [3:0] FAULT_DISABLED     = 4'd1;
localparam [3:0] FAULT_BUSY         = 4'd2;
localparam [3:0] FAULT_BAD_SEQUENCE = 4'd3;
localparam [3:0] FAULT_BAD_CLASS    = 4'd4;
localparam [3:0] FAULT_ACK_MISMATCH = 4'd6;
localparam [3:0] FAULT_EXECUTION    = 4'd7;
localparam [3:0] FAULT_WATCHDOG     = 4'd8;

localparam [5:0] REG_ID              = 6'h00;
localparam [5:0] REG_VERSION         = 6'h01;
localparam [5:0] REG_CONTROL         = 6'h02;
localparam [5:0] REG_STATUS          = 6'h03;
localparam [5:0] REG_EVENT_ID        = 6'h04;
localparam [5:0] REG_EVENT_FLAGS     = 6'h05;
localparam [5:0] REG_CANDIDATE       = 6'h06;
localparam [5:0] REG_COMMAND         = 6'h07;
localparam [5:0] REG_DECISION        = 6'h08;
localparam [5:0] REG_ACTION          = 6'h09;
localparam [5:0] REG_ALARM           = 6'h0A;
localparam [5:0] REG_COMMAND_EVENT   = 6'h0B;
localparam [5:0] REG_WATCHDOG_LIMIT  = 6'h0C;
localparam [5:0] REG_WATCHDOG_COUNT  = 6'h0D;
localparam [5:0] REG_FAULT_CODE      = 6'h0E;
localparam [5:0] REG_LAST_COMPLETED  = 6'h0F;
localparam [5:0] REG_THRESHOLD_0     = 6'h10;
localparam [5:0] REG_THRESHOLD_1     = 6'h11;
localparam [5:0] REG_THRESHOLD_2     = 6'h12;
localparam [5:0] REG_THRESHOLD_3     = 6'h13;
localparam [5:0] REG_THRESHOLD_4     = 6'h14;
localparam [5:0] REG_EVENT_COUNT     = 6'h18;
localparam [5:0] REG_OK_COUNT        = 6'h19;
localparam [5:0] REG_NG_COUNT        = 6'h1A;
localparam [5:0] REG_UNKNOWN_COUNT   = 6'h1B;
localparam [5:0] REG_ACK_COUNT       = 6'h1C;
localparam [5:0] REG_FAILURE_COUNT   = 6'h1D;
localparam [5:0] REG_DUPLICATE_COUNT = 6'h1E;
localparam [5:0] REG_CANDIDATE_COUNT = 6'h1F;

localparam [31:0] CMD_START_EVENT    = 32'h0000_0001;
localparam [31:0] CMD_PUSH_CANDIDATE = 32'h0000_0002;
localparam [31:0] CMD_COMMIT_EVENT   = 32'h0000_0004;
localparam [31:0] CMD_ACK_DONE       = 32'h0000_0008;
localparam [31:0] CMD_ACK_FAILED     = 32'h0000_0010;
localparam [31:0] CMD_CLEAR_FAULT    = 32'h0000_0020;

reg        enabled;
reg        four_class_mode;
reg        swap_sides;
reg        event_active;
reg        command_valid;
reg        awaiting_ack;
reg        fault_latched;
reg        last_completed_valid;
reg        inference_ok;
reg        workpiece_present;
reg        defect_seen;
reg        normal_seen;
reg [3:0]  fault_code;
reg [2:0]  decision;
reg [2:0]  action;
reg        alarm;
reg [31:0] staged_event_id;
reg [31:0] command_event_id;
reg [31:0] last_completed_event_id;
reg [31:0] candidate_word;
reg [31:0] watchdog_limit;
reg [31:0] watchdog_count;
reg [15:0] threshold_0;
reg [15:0] threshold_1;
reg [15:0] threshold_2;
reg [15:0] threshold_3;
reg [15:0] threshold_4;
reg [31:0] event_count;
reg [31:0] ok_count;
reg [31:0] ng_count;
reg [31:0] unknown_count;
reg [31:0] ack_count;
reg [31:0] failure_count;
reg [31:0] duplicate_count;
reg [31:0] candidate_count;

wire ready = enabled && !event_active && !awaiting_ack && !fault_latched;
wire [3:0] state = !enabled       ? STATE_DISABLED :
                   fault_latched ? STATE_FAULT    :
                   event_active  ? STATE_COLLECT  :
                   awaiting_ack  ? STATE_COMMAND  : STATE_READY;

function [31:0] merge_bytes;
    input [31:0] old_value;
    input [31:0] new_value;
    input [3:0]  byteenable;
    integer index;
    begin
        merge_bytes = old_value;
        for (index = 0; index < 4; index = index + 1) begin
            if (byteenable[index])
                merge_bytes[index*8 +: 8] = new_value[index*8 +: 8];
        end
    end
endfunction

function [15:0] threshold_for_class;
    input [7:0] class_id;
    begin
        case (class_id)
            8'd0: threshold_for_class = threshold_0;
            8'd1: threshold_for_class = threshold_1;
            8'd2: threshold_for_class = threshold_2;
            8'd3: threshold_for_class = threshold_3;
            8'd4: threshold_for_class = threshold_4;
            default: threshold_for_class = 16'hFFFF;
        endcase
    end
endfunction

always @(*) begin
    avs_readdata = 32'h0000_0000;
    if (avs_read) begin
        case (avs_address)
            REG_ID:              avs_readdata = IP_ID;
            REG_VERSION:         avs_readdata = IP_VERSION;
            REG_CONTROL:         avs_readdata = {28'd0, swap_sides, four_class_mode, 1'b0, enabled};
            REG_STATUS:          avs_readdata = {candidate_count[7:0], 4'd0, fault_code,
                                                 4'd0, state, last_completed_valid,
                                                 normal_seen, defect_seen, fault_latched,
                                                 awaiting_ack, command_valid, event_active, ready};
            REG_EVENT_ID:        avs_readdata = staged_event_id;
            REG_EVENT_FLAGS:     avs_readdata = {30'd0, workpiece_present, inference_ok};
            REG_CANDIDATE:       avs_readdata = candidate_word;
            REG_DECISION:        avs_readdata = {29'd0, decision};
            REG_ACTION:          avs_readdata = {29'd0, action};
            REG_ALARM:           avs_readdata = {31'd0, alarm};
            REG_COMMAND_EVENT:   avs_readdata = command_event_id;
            REG_WATCHDOG_LIMIT:  avs_readdata = watchdog_limit;
            REG_WATCHDOG_COUNT:  avs_readdata = watchdog_count;
            REG_FAULT_CODE:      avs_readdata = {28'd0, fault_code};
            REG_LAST_COMPLETED:  avs_readdata = last_completed_event_id;
            REG_THRESHOLD_0:     avs_readdata = {16'd0, threshold_0};
            REG_THRESHOLD_1:     avs_readdata = {16'd0, threshold_1};
            REG_THRESHOLD_2:     avs_readdata = {16'd0, threshold_2};
            REG_THRESHOLD_3:     avs_readdata = {16'd0, threshold_3};
            REG_THRESHOLD_4:     avs_readdata = {16'd0, threshold_4};
            REG_EVENT_COUNT:     avs_readdata = event_count;
            REG_OK_COUNT:        avs_readdata = ok_count;
            REG_NG_COUNT:        avs_readdata = ng_count;
            REG_UNKNOWN_COUNT:   avs_readdata = unknown_count;
            REG_ACK_COUNT:       avs_readdata = ack_count;
            REG_FAILURE_COUNT:   avs_readdata = failure_count;
            REG_DUPLICATE_COUNT: avs_readdata = duplicate_count;
            REG_CANDIDATE_COUNT: avs_readdata = candidate_count;
            default:             avs_readdata = 32'h0000_0000;
        endcase
    end
end

always @(posedge clk) begin
    if (reset) begin
        enabled                 <= 1'b0;
        four_class_mode         <= 1'b0;
        swap_sides              <= 1'b0;
        event_active            <= 1'b0;
        command_valid           <= 1'b0;
        awaiting_ack            <= 1'b0;
        fault_latched           <= 1'b0;
        last_completed_valid    <= 1'b0;
        inference_ok            <= 1'b0;
        workpiece_present       <= 1'b0;
        defect_seen             <= 1'b0;
        normal_seen             <= 1'b0;
        fault_code              <= FAULT_NONE;
        decision                <= DECISION_UNKNOWN;
        action                  <= ACTION_HOLD;
        alarm                   <= 1'b0;
        staged_event_id         <= 32'd0;
        command_event_id        <= 32'd0;
        last_completed_event_id <= 32'd0;
        candidate_word          <= 32'd0;
        watchdog_limit          <= 32'd1500000000;
        watchdog_count          <= 32'd0;
        threshold_0             <= 16'd45875;
        threshold_1             <= 16'd45875;
        threshold_2             <= 16'd45875;
        threshold_3             <= 16'd13107;
        threshold_4             <= 16'd45875;
        event_count             <= 32'd0;
        ok_count                <= 32'd0;
        ng_count                <= 32'd0;
        unknown_count           <= 32'd0;
        ack_count               <= 32'd0;
        failure_count           <= 32'd0;
        duplicate_count         <= 32'd0;
        candidate_count         <= 32'd0;
    end else begin
        if (awaiting_ack) begin
            if (watchdog_limit == 32'd0 || watchdog_count >= watchdog_limit - 1'b1) begin
                watchdog_count <= 32'd0;
                awaiting_ack   <= 1'b0;
                command_valid  <= 1'b0;
                fault_latched  <= 1'b1;
                fault_code     <= FAULT_WATCHDOG;
                decision       <= DECISION_UNKNOWN;
                action         <= ACTION_HOLD;
                alarm          <= 1'b1;
                failure_count  <= failure_count + 1'b1;
            end else begin
                watchdog_count <= watchdog_count + 1'b1;
            end
        end else begin
            watchdog_count <= 32'd0;
        end

        if (avs_write) begin
            case (avs_address)
                REG_CONTROL: begin
                    enabled         <= avs_writedata[0];
                    four_class_mode <= avs_writedata[2];
                    swap_sides      <= avs_writedata[3];
                    if (!avs_writedata[0]) begin
                        event_active  <= 1'b0;
                        command_valid <= 1'b0;
                        awaiting_ack  <= 1'b0;
                        decision      <= DECISION_UNKNOWN;
                        action        <= ACTION_HOLD;
                        alarm         <= 1'b0;
                    end
                    if (avs_writedata[1]) begin
                        event_active    <= 1'b0;
                        command_valid   <= 1'b0;
                        awaiting_ack    <= 1'b0;
                        fault_latched   <= 1'b0;
                        fault_code      <= FAULT_NONE;
                        defect_seen     <= 1'b0;
                        normal_seen     <= 1'b0;
                        candidate_count <= 32'd0;
                        decision        <= DECISION_UNKNOWN;
                        action          <= ACTION_HOLD;
                        alarm           <= 1'b0;
                    end
                end
                REG_EVENT_ID:
                    staged_event_id <= merge_bytes(staged_event_id, avs_writedata, avs_byteenable);
                REG_EVENT_FLAGS: begin
                    inference_ok      <= avs_writedata[0];
                    workpiece_present <= avs_writedata[1];
                end
                REG_CANDIDATE:
                    candidate_word <= merge_bytes(candidate_word, avs_writedata, avs_byteenable);
                REG_WATCHDOG_LIMIT:
                    watchdog_limit <= merge_bytes(watchdog_limit, avs_writedata, avs_byteenable);
                REG_THRESHOLD_0:
                    threshold_0 <= merge_bytes({16'd0, threshold_0}, avs_writedata, avs_byteenable);
                REG_THRESHOLD_1:
                    threshold_1 <= merge_bytes({16'd0, threshold_1}, avs_writedata, avs_byteenable);
                REG_THRESHOLD_2:
                    threshold_2 <= merge_bytes({16'd0, threshold_2}, avs_writedata, avs_byteenable);
                REG_THRESHOLD_3:
                    threshold_3 <= merge_bytes({16'd0, threshold_3}, avs_writedata, avs_byteenable);
                REG_THRESHOLD_4:
                    threshold_4 <= merge_bytes({16'd0, threshold_4}, avs_writedata, avs_byteenable);
                REG_COMMAND: begin
                    if (avs_writedata & CMD_CLEAR_FAULT) begin
                        fault_latched <= 1'b0;
                        fault_code    <= FAULT_NONE;
                        alarm         <= 1'b0;
                    end

                    if (avs_writedata & CMD_START_EVENT) begin
                        if (!enabled) begin
                            fault_latched <= 1'b1;
                            fault_code    <= FAULT_DISABLED;
                        end else if (event_active || awaiting_ack) begin
                            fault_latched <= 1'b1;
                            fault_code    <= FAULT_BUSY;
                        end else if ((last_completed_valid && staged_event_id == last_completed_event_id) ||
                                     (command_valid && staged_event_id == command_event_id)) begin
                            duplicate_count <= duplicate_count + 1'b1;
                        end else begin
                            event_active    <= 1'b1;
                            defect_seen     <= 1'b0;
                            normal_seen     <= 1'b0;
                            candidate_count <= 32'd0;
                            decision        <= DECISION_UNKNOWN;
                            action          <= ACTION_HOLD;
                            alarm           <= 1'b0;
                        end
                    end

                    if (avs_writedata & CMD_PUSH_CANDIDATE) begin
                        if (!event_active) begin
                            fault_latched <= 1'b1;
                            fault_code    <= FAULT_BAD_SEQUENCE;
                        end else if (candidate_word[7:0] > 8'd4) begin
                            fault_latched <= 1'b1;
                            fault_code    <= FAULT_BAD_CLASS;
                        end else begin
                            candidate_count <= candidate_count + 1'b1;
                            if (candidate_word[31:16] >= threshold_for_class(candidate_word[7:0])) begin
                                if (candidate_word[7:0] == 8'd4)
                                    normal_seen <= 1'b1;
                                else
                                    defect_seen <= 1'b1;
                            end
                        end
                    end

                    if (avs_writedata & CMD_COMMIT_EVENT) begin
                        if (!event_active) begin
                            fault_latched <= 1'b1;
                            fault_code    <= FAULT_BAD_SEQUENCE;
                        end else begin
                            event_active     <= 1'b0;
                            command_valid    <= 1'b1;
                            awaiting_ack     <= 1'b1;
                            command_event_id <= staged_event_id;
                            event_count      <= event_count + 1'b1;
                            watchdog_count   <= 32'd0;
                            if (!inference_ok || !workpiece_present) begin
                                decision      <= DECISION_UNKNOWN;
                                action        <= ACTION_HOLD;
                                alarm         <= 1'b0;
                                unknown_count <= unknown_count + 1'b1;
                            end else if (defect_seen) begin
                                decision <= DECISION_NG;
                                action   <= swap_sides ? ACTION_SORT_RIGHT : ACTION_SORT_LEFT;
                                alarm    <= 1'b1;
                                ng_count <= ng_count + 1'b1;
                            end else if (normal_seen || four_class_mode) begin
                                decision <= DECISION_OK;
                                action   <= swap_sides ? ACTION_SORT_LEFT : ACTION_SORT_RIGHT;
                                alarm    <= 1'b0;
                                ok_count <= ok_count + 1'b1;
                            end else begin
                                decision      <= DECISION_UNKNOWN;
                                action        <= ACTION_HOLD;
                                alarm         <= 1'b0;
                                unknown_count <= unknown_count + 1'b1;
                            end
                        end
                    end

                    if (avs_writedata & CMD_ACK_DONE) begin
                        if (!awaiting_ack) begin
                            fault_latched <= 1'b1;
                            fault_code    <= FAULT_BAD_SEQUENCE;
                        end else if (staged_event_id != command_event_id) begin
                            fault_latched <= 1'b1;
                            fault_code    <= FAULT_ACK_MISMATCH;
                        end else begin
                            awaiting_ack             <= 1'b0;
                            command_valid            <= 1'b0;
                            last_completed_valid     <= 1'b1;
                            last_completed_event_id  <= command_event_id;
                            ack_count                <= ack_count + 1'b1;
                        end
                    end

                    if (avs_writedata & CMD_ACK_FAILED) begin
                        if (!awaiting_ack || staged_event_id != command_event_id) begin
                            fault_latched <= 1'b1;
                            fault_code    <= FAULT_ACK_MISMATCH;
                        end else begin
                            awaiting_ack  <= 1'b0;
                            command_valid <= 1'b0;
                            fault_latched <= 1'b1;
                            fault_code    <= FAULT_EXECUTION;
                            decision      <= DECISION_UNKNOWN;
                            action        <= ACTION_HOLD;
                            alarm         <= 1'b1;
                            failure_count <= failure_count + 1'b1;
                        end
                    end
                end
                default: begin end
            endcase
        end
    end
end

endmodule
