// control_receiver.hpp - Control Command Receiver
// Receives control commands from iPhone app
#pragma once

#include <stdint.h>
#include <stdbool.h>
#include <netinet/in.h>
#include "protocol.hpp"

// Initialize control receiver
bool control_init();

// Deinitialize
void control_deinit();

// Control receiver FreeRTOS task
void control_task(void* pvParameters);

// Get last received control frame
bool control_get_last_frame(ControlFrame* out_frame);

// Get time since last control frame (ms)
uint32_t control_get_last_frame_age();

// Check if control is connected
bool control_is_connected();

// Statistics
struct ControlStats {
    uint32_t frames_received;
    uint32_t frames_invalid;
    uint32_t crc_errors;
    uint32_t timeout_count;
    uint32_t last_sequence;
    uint32_t seq_gaps;
    uint32_t seq_duplicates;
    uint32_t seq_out_of_order;
};
ControlStats control_get_stats();

// Get last known app address from control channel
bool control_get_app_addr(struct sockaddr_in* out_addr);
