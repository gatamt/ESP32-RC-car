// network_mutex.hpp - Shared mutex for network access serialization
// Mirrored from P4 implementation to serialize bursts between tasks
#pragma once

#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"

#ifdef __cplusplus
extern "C" {
#endif

void network_mutex_init(void);
bool network_mutex_take(uint32_t timeout_ms);
void network_mutex_give(void);

#ifdef __cplusplus
}

// RAII helper for C++ code
class NetworkLock {
public:
    explicit NetworkLock(uint32_t timeout_ms = 100)
        : m_acquired(network_mutex_take(timeout_ms)) {}
    ~NetworkLock() { if (m_acquired) network_mutex_give(); }
    bool acquired() const { return m_acquired; }
    explicit operator bool() const { return m_acquired; }
private:
    bool m_acquired;
};
#endif
