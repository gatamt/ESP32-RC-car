// network_mutex.cpp - Network access serialization
#include "network_mutex.hpp"
static SemaphoreHandle_t s_network_mutex = nullptr;

extern "C" {

void network_mutex_init(void) {
    if (s_network_mutex == nullptr) {
        s_network_mutex = xSemaphoreCreateMutex();
    }
}

bool network_mutex_take(uint32_t timeout_ms) {
    if (s_network_mutex == nullptr) {
        return true;  // If not initialized, do not block
    }
    return xSemaphoreTake(s_network_mutex, pdMS_TO_TICKS(timeout_ms)) == pdTRUE;
}

void network_mutex_give(void) {
    if (s_network_mutex != nullptr) {
        xSemaphoreGive(s_network_mutex);
    }
}

}  // extern "C"
