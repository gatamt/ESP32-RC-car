// protocol.hpp - Network Protocol Definitions
// Compatible with iOS Gata_RC app (same as P4)
#pragma once

#include <stdint.h>
#include <stddef.h>

// ============================================================================
// Control Frame (FROM iPhone TO ESP32-C6)
// ============================================================================
#pragma pack(push, 1)
struct ControlFrame {
    uint8_t  magic[2];    // 0x5A 0xA5
    uint8_t  version;     // 0x01
    uint16_t throttle;    // R2 trigger: 0-1023
    uint16_t reverse;     // L2 trigger: 0-1023
    int16_t  steering;    // LX stick: -512 to +512
    uint8_t  brake;       // Square button: 0 or 1
    uint32_t sequence;    // Packet sequence number
    uint16_t crc16;       // CRC16-CCITT
};
#pragma pack(pop)

static_assert(sizeof(ControlFrame) == 16, "ControlFrame must be 16 bytes");

// ============================================================================
// Control Handshake (HEL0 -> OKAY)
// ============================================================================
#pragma pack(push, 1)
struct HelloPacket {
    char     magic[4];       // "HEL0"
    uint8_t  version;        // Protocol version
    uint8_t  flags;          // Reserved for future use
    uint16_t reserved;
};
#pragma pack(pop)

static_assert(sizeof(HelloPacket) == 8, "HelloPacket must be 8 bytes");

#pragma pack(push, 1)
struct HelloAckPacket {
    char     magic[4];       // "OKAY"
    uint8_t  version;        // Protocol version
    uint8_t  flags;          // Reserved for future use
    uint16_t reserved;
};
#pragma pack(pop)

static_assert(sizeof(HelloAckPacket) == 8, "HelloAckPacket must be 8 bytes");

// ============================================================================
// H.264 Video Header (FROM RPi, forwarded TO iPhone)
// ============================================================================
#pragma pack(push, 1)
struct H264Header {
    char     magic[4];       // "H264"
    uint32_t frame_id;
    uint16_t width;
    uint16_t height;
    uint32_t timestamp;
    uint32_t total_len;
    uint16_t chunk_idx;
    uint16_t chunk_count;
    uint8_t  frame_type;     // 0=P-frame, 1=I-frame
    uint8_t  reserved[3];
};
#pragma pack(pop)

static_assert(sizeof(H264Header) == 28, "H264Header must be 28 bytes");

// ============================================================================
// Telemetry Packet (TO iPhone)
// ============================================================================
#pragma pack(push, 1)
struct TelemetryPacket {
    char     magic[4];       // "TEL1"
    uint32_t timestamp;
    uint8_t  battery_pct;    // NOTE: Always 0 for C6 (no battery monitoring)
    int8_t   cpu_temp;
    uint16_t motor_speed_l;
    uint16_t motor_speed_r;
    int32_t  latitude;
    int32_t  longitude;
    uint16_t heading;
    uint8_t  gps_fix;
    uint8_t  wifi_rssi;
    uint16_t reserved;
};
#pragma pack(pop)

// Optional telemetry extension (app may ignore if absent)
#pragma pack(push, 1)
struct TelemetryExtV1 {
    uint32_t ctrl_last_seq;  // Last control sequence received
    uint32_t ctrl_lost;      // Estimated lost control packets
};
#pragma pack(pop)

static_assert(sizeof(TelemetryExtV1) == 8, "TelemetryExtV1 must be 8 bytes");

// Legacy CAM0 battery packet (for compatibility)
#pragma pack(push, 1)
struct BatteryPacket {
    char    magic[4];        // "CAM0"
    uint8_t battery_pct;
};
#pragma pack(pop)

// ============================================================================
// CRC16-CCITT Functions
// ============================================================================
uint16_t crc16_ccitt(const uint8_t* data, size_t len);
bool verify_control_frame(const ControlFrame* frame);
