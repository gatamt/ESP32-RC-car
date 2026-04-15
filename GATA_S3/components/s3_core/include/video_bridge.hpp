// video_bridge.hpp - UDP Video Bridge
// Receives H.264 packets from RPi and forwards to iOS app
#pragma once

#include <stdint.h>
#include <stdbool.h>
#include <netinet/in.h>

// Initialize video bridge
bool video_bridge_init();

// Deinitialize
void video_bridge_deinit();

// Check if app is registered (sent VID0)
bool video_app_ready();

// Get app address for telemetry
bool video_get_app_addr(struct sockaddr_in* out_addr);

// Video bridge task (call from main loop or as FreeRTOS task)
void video_bridge_task(void* pvParameters);

// Statistics
struct VideoBridgeStats {
    uint32_t frames_forwarded;
    uint32_t frames_dropped;
    uint32_t bytes_sent;
    uint32_t current_fps;
};
VideoBridgeStats video_get_stats();
