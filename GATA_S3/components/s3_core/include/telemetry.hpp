// telemetry.hpp - Telemetry Data Transmission
// Sends status data to iPhone app
#pragma once

#include <stdint.h>
#include <stdbool.h>

// Telemetry data structure
struct TelemetryData {
    uint8_t  battery_percent;   // Always 0 (disabled)
    int8_t   cpu_temperature;
    uint16_t motor_speed_left;
    uint16_t motor_speed_right;
    int8_t   wifi_rssi;
    uint32_t uptime_ms;
};

// Initialize telemetry system
bool telemetry_init();

// Deinitialize
void telemetry_deinit();

// Telemetry FreeRTOS task
void telemetry_task(void* pvParameters);

// Get current telemetry data
TelemetryData telemetry_get_data();

// Read CPU temperature
int8_t telemetry_read_cpu_temp();
