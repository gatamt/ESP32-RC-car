// wifi_ap.hpp - WiFi Access Point Mode
// ESP32-C6 creates its own network (SoftAP)
#pragma once

#include <stdbool.h>
#include <stdint.h>

// Initialize WiFi in SoftAP mode
void wifi_init_ap();

// Check if WiFi AP is active and ready
bool wifi_is_ready();

// Get number of connected stations
int wifi_get_station_count();

// Get AP IP address as string
const char* wifi_get_ip_str();
