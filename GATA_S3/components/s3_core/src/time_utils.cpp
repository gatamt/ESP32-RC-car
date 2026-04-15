// time_utils.cpp - Time utility functions
#include "time_utils.hpp"
#include "esp_timer.h"

uint32_t millis32() {
    return (uint32_t)(esp_timer_get_time() / 1000ULL);
}

uint64_t micros64() {
    return esp_timer_get_time();
}
