// config.hpp - GATA RC Waveshare ESP32-S3-Zero Configuration
// Dual-core Xtensa LX7 @ 240MHz with WiFi 4 (802.11n)
#pragma once

#include <stddef.h>
#include <stdint.h>

// ============================================================================
// WiFi Configuration (S3 as SoftAP - same SSID/password as C6 for app compat)
// ============================================================================
namespace WiFiConfig {
static constexpr const char *SSID =
    "GATA_P4_HOST"; // Same as C6/P4 for app compatibility
static constexpr const char *PASSWORD = "your-wifi-password"; // Same as C6/P4
static constexpr uint8_t CHANNEL = 6;                // 1-13
static constexpr uint8_t MAX_STA_CONN = 4; // iPhone + RPi + headroom for extras
static constexpr const char *AP_IP = "192.168.4.1"; // Standard SoftAP IP
static constexpr uint8_t BANDWIDTH_MHZ = 20;        // 20 or 40
static constexpr uint16_t STATIC_RX_BUFS = 16;
static constexpr uint16_t DYNAMIC_RX_BUFS = 64;
static constexpr uint16_t DYNAMIC_TX_BUFS = 64;
} // namespace WiFiConfig

// ============================================================================
// Network Ports (same as C6/iOS app expects)
// ============================================================================
namespace NetworkPorts {
static constexpr uint16_t CONTROL = 3333; // Control commands FROM iPhone
static constexpr uint16_t VIDEO = 3334;   // Video stream TO iPhone
static constexpr uint16_t AUDIO =
    3335; // Audio stream TO iPhone (unused for now)
} // namespace NetworkPorts

// ============================================================================
// Video Bridge Configuration (RPi -> S3 -> App)
// ============================================================================
namespace VideoConfig {
// Expected H.264 stream from Raspberry Pi
static constexpr uint16_t WIDTH = 1280;
static constexpr uint16_t HEIGHT = 720;
static constexpr uint32_t TARGET_FPS = 30;
static constexpr size_t MAX_UDP_PAYLOAD = 1400;
} // namespace VideoConfig

namespace VideoBridgeConfig {
static constexpr uint16_t INGEST_PORT = 4000; // RPi sends here
static constexpr size_t MAX_INGEST_PACKET = 1500;
static constexpr uint32_t DROP_LOG_INTERVAL = 120;
} // namespace VideoBridgeConfig

// ============================================================================
// ESC Configuration (LEDC PWM - Electronic Speed Controller)
// DFRobot FireBeetle 2 ESP32-S3 pin mapping
// ============================================================================
namespace ESCConfig {
static constexpr int PIN = 14; // GPIO 14 (FireBeetle ESC pin)

// ESC PWM Timing
static constexpr uint32_t FREQ_HZ = 300;
static constexpr uint32_t PERIOD_US = 1000000 / FREQ_HZ;

// ESC pulse widths
static constexpr int MIN_US = 1000;     // full reverse / min throttle
static constexpr int MAX_US = 2000;     // full forward / max throttle
static constexpr int NEUTRAL_US = 1500; // neutral

// PWM Resolution
static constexpr int RESOLUTION_BITS = 14;
static constexpr uint32_t MAX_DUTY = (1U << RESOLUTION_BITS) - 1;
} // namespace ESCConfig

// ============================================================================
// Servo Configuration (LEDC PWM - Steering Servo)
// ============================================================================
namespace ServoConfig {
static constexpr int PIN = 13; // GPIO 13 (FireBeetle Servo pin)

// ===== Savox SB-2265MG =====
static constexpr uint32_t FREQ_HZ = 333;
static constexpr uint32_t PERIOD_US = 1000000 / FREQ_HZ; // ≈3003 µs

static constexpr int MIN_US = 800;
static constexpr int MAX_US = 2200;
static constexpr int CENTER_US = 1500;

// PWM
static constexpr int RESOLUTION_BITS = 14;
static constexpr uint32_t MAX_DUTY = (1U << RESOLUTION_BITS) - 1;

// Response
static constexpr int TAU_MS = 0; // instant
} // namespace ServoConfig

// ============================================================================
// Drive Tuning Parameters
// ============================================================================
namespace DriveConfig {
static constexpr int REVERSE_MAX_PCT = 100;
static constexpr int BRAKE_STRENGTH_PCT = 100;
static constexpr int STICK_ABS_MAX = 512;
static constexpr int TRIGGER_MAX = 1023;
static constexpr float STOP_EPS_PCT = 1.0f;
static constexpr uint32_t LAST_DIR_HOLD_MS = 1200;
static constexpr int TAU_MS = 0;
} // namespace DriveConfig

// ============================================================================
// Failsafe Configuration
// ============================================================================
namespace FailsafeConfig {
static constexpr uint32_t TIMEOUT_MS = 120;
static constexpr uint32_t REARM_GUARD_MS = 300;
static constexpr uint16_t ARM_EPS = 60;
static constexpr uint32_t ARM_HOLD_MS = 150;
} // namespace FailsafeConfig

// ============================================================================
// Control Protocol Configuration
// ============================================================================
namespace ControlConfig {
static constexpr uint8_t MAGIC_0 = 0x5A;
static constexpr uint8_t MAGIC_1 = 0xA5;
static constexpr uint8_t VERSION = 0x01;
static constexpr uint32_t TIMEOUT_MS = 500;
static constexpr size_t FRAME_SIZE = 16;
} // namespace ControlConfig

// ============================================================================
// Telemetry Configuration
// ============================================================================
namespace TelemetryConfig {
static constexpr uint32_t SEND_INTERVAL_MS = 1000; // 1 Hz

// Battery monitoring disabled
static constexpr int BATTERY_ADC_CHANNEL = 0;
static constexpr float VOLTAGE_DIVIDER_RATIO = 2.0f;
static constexpr float LIPO_VOLTAGE_MAX = 4.2f;
static constexpr float LIPO_VOLTAGE_MIN = 3.0f;
} // namespace TelemetryConfig

// ============================================================================
// FreeRTOS Task Configuration
// ESP32-S3: DUAL-CORE Xtensa LX7 @ 240MHz
//   Core 0 (PRO): WiFi stack + video_bridge + telemetry
//   Core 1 (APP): control (motor timing, isolated from WiFi interrupts)
// ============================================================================
namespace TaskConfig {
// Core assignments
static constexpr int CORE_WIFI = 0; // WiFi stack lives here (ESP-IDF default)
static constexpr int CORE_VIDEO =
    0; // Video bridge on same core as WiFi = fewer context switches
static constexpr int CORE_TELE = 0; // Telemetry alongside video
static constexpr int CORE_CTRL = 1; // Control task isolated on APP core

// Stack sizes
static constexpr uint32_t VIDEO_STACK = 6144;
static constexpr uint32_t CONTROL_STACK = 4096;
static constexpr uint32_t TELEMETRY_STACK = 3072;

// Priorities
static constexpr int CONTROL_PRIORITY = 20;  // Highest - motor control
static constexpr int VIDEO_PRIORITY = 15;    // Medium - video bridge
static constexpr int TELEMETRY_PRIORITY = 5; // Lowest - telemetry
} // namespace TaskConfig

// ============================================================================
// Performance Tuning
// ============================================================================
namespace PerfConfig {
static constexpr size_t UDP_SEND_BUFFER = 512 * 1024;
static constexpr size_t UDP_RECV_BUFFER = 512 * 1024;
} // namespace PerfConfig
