// time_utils.hpp - Time utility functions
#pragma once

#include <stdint.h>

// Get current time in milliseconds (wraps around ~49 days)
uint32_t millis32();

// Get current time in microseconds
uint64_t micros64();
