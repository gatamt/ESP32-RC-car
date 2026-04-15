# ESP32-RC-car

> Low-latency RC car running dual-core ESP32-S3 firmware that pins a 200 Hz motor control loop on one Xtensa core and bridge-forwards a 1280x720 H.264 video stream on the other, controlled from an iOS/macOS SwiftUI app over WiFi SoftAP.

## Overview

The target MCU is a Waveshare ESP32-S3-Zero: dual Xtensa LX7 @ 240 MHz, WiFi 4 (802.11n), 4 MB flash, no PSRAM. That hardware budget forces every design decision here. A single-task firmware would let WiFi-driven interrupt bursts steal CPU from the servo/ESC update loop and jitter the PWM pulses, so the firmware splits the workload along core affinity: Core 0 (PRO) runs the WiFi stack, the captive portal, the H.264 video bridge, and the telemetry task, while Core 1 (APP) runs an isolated 200 Hz control loop that touches nothing but the LEDC PWM registers and one UDP socket.

The iOS/macOS client (`App_P4/Gata_RC`) is a SwiftUI app that speaks a tight 16-byte control frame with CRC-16/CCITT validation and a monotonically-increasing 32-bit sequence number. The client connects to the S3's SoftAP (`GATA_P4_HOST`), runs a burst hello handshake, then sends control frames on UDP 3333. A separate video path receives H.264 chunks on UDP 3334 and decodes them through `AVSampleBufferDisplayLayer`. PS4 and PS5 DualSense controllers are supported through Apple's GameController framework.

Because both cores end up talking to lwIP from different tasks — the control receiver on Core 1, the video bridge and telemetry sender on Core 0 — the firmware uses a FreeRTOS mutex wrapped in a C++ RAII helper called `NetworkLock`. Any task that calls `sendto` takes the lock with a bounded timeout (50 ms for the video bridge). If the lock cannot be acquired in time, the frame is dropped and counted, and the control loop keeps its real-time budget. The race between the two cores is observed in practice on ESP-IDF's lwIP port, and the mutex is initialised in `app_main` before any socket is opened.

## Hardware

| Component | Part | Purpose |
|---|---|---|
| MCU | Waveshare ESP32-S3-Zero (ESP32-S3, dual Xtensa LX7 @ 240 MHz, 4 MB flash, no PSRAM) | Firmware host, WiFi SoftAP |
| ESC | User choice (brushed or brushless, 1000-2000 us PWM, neutral 1500 us) | Motor drive |
| Servo | Standard RC steering servo (800-2200 us PWM, center 1500 us; Savox SB-2265MG used in reference build) | Front steering |
| Upstream camera | Raspberry Pi or compatible H.264 source at 1280x720, 30 fps (optional) | Video feed that the S3 bridges to iOS |
| Client | iPad, iPhone, or Mac running `Gata_RC` | Remote control and video display |

Pin map:

| GPIO | Function | Frequency / range |
|---|---|---|
| 14 | ESC PWM | 300 Hz, 1000-2000 us, 14-bit duty resolution |
| 13 | Servo PWM | 333 Hz, 800-2200 us (center 1500 us), 14-bit duty resolution |
| 43 | UART0 TX | 115200 baud (idf.py monitor / debug) |
| 44 | UART0 RX | 115200 baud (idf.py monitor / debug) |

## Architecture

```
                                   ESP32-S3-Zero
    +----------------+      Core 0 (PRO, WiFi)               Core 1 (APP)
    |   RPi camera   |     +---------------------+          +----------------+
    |  H.264 source  +---->| video_bridge_task   |          | control_task   |
    +----------------+ UDP | recv :4000          |          | recv :3333     |
                      4000 | send :3334          |          | 200 Hz loop    |
    +----------------+     | (NetworkLock 50 ms) |          | vTaskDelayUntil|
    |     iPhone     |<----+ sendto app          |          | LEDC PWM       |
    |   Gata_RC app  |     +---------------------+          +-------+--------+
    |                |                                               |
    |  :3333 control |                                               v
    |  :3334 H.264   |     +---------------------+          +----------------+
    |                |<----+ telemetry_task 1 Hz |          | ESC GPIO 14    |
    |  GameController|     | TEL1 over :3333     |          | Servo GPIO 13  |
    +----------------+     +---------------------+          +----------------+
                           +---------------------+
                           | captive_portal      |
                           | DNS :53 + HTTP :80  |
                           +---------------------+
                                    |
                                    v
                              WiFi SoftAP
                            SSID GATA_P4_HOST
                              192.168.4.1/24
```

Core 0 (PRO) hosts the lwIP stack, the SoftAP, the captive portal (DNS on port 53, HTTPD on port 80), the video bridge (ingest on UDP 4000, forward to the app on UDP 3334), and the telemetry task (1 Hz, `TEL1` + `TelemetryExtV1` sent back to the client on the control port so it shares one socket endpoint). Core 1 (APP) hosts only the `control_task`: it receives control frames on UDP 3333, runs the failsafe state machine, and writes LEDC duty updates on GPIO 13/14.

The `network_mutex` + RAII `NetworkLock` pattern prevents two tasks on different cores from holding an lwIP socket simultaneously. The video bridge wraps its `sendto` call in `NetworkLock lock(50)`; if the lock is not acquired within 50 ms, the frame is counted in `VideoBridgeStats::frames_dropped` and dropped. This serializes cross-core `sendto`/`recvfrom` interleaving without letting a stuck socket starve the control loop.

Task priorities and core affinity (from `TaskConfig` in `GATA_S3/components/s3_core/include/config.hpp`):

| Task | Core | Priority | Stack | Period |
|---|---|---|---|---|
| `control_task` | 1 (APP) | 20 | 4096 | 5 ms (200 Hz) via `vTaskDelayUntil` |
| `video_bridge_task` | 0 (PRO) | 15 | 6144 | Non-blocking recv, yields every 1 ms |
| `telemetry_task` | 0 (PRO) | 5 | 3072 | 1 Hz, 100 ms check interval |

`sdkconfig.defaults` raises `CONFIG_LWIP_UDP_RECVMBOX_SIZE` and `CONFIG_LWIP_TCPIP_RECVMBOX_SIZE` to 64 slots each so H.264 keyframe bursts from the Pi do not drop chunks under high motion.

## Directory layout

```
ESP32-RC-car/
├── GATA_S3/                           # ESP-IDF firmware (C++17, CMake)
│   ├── CMakeLists.txt
│   ├── sdkconfig.defaults              # 64-slot lwIP mailboxes, WiFi tuning
│   ├── main/
│   │   └── main.cpp                    # app_main: NVS, mutex, PWM, AP, tasks
│   └── components/
│       └── s3_core/
│           ├── include/
│           │   ├── config.hpp          # Pins, ports, core affinity, timing
│           │   ├── protocol.hpp        # ControlFrame, H264Header, TelemetryPacket
│           │   ├── network_mutex.hpp   # RAII NetworkLock wrapper
│           │   ├── motor_control.hpp
│           │   ├── control_receiver.hpp
│           │   ├── video_bridge.hpp
│           │   ├── telemetry.hpp
│           │   ├── wifi_ap.hpp
│           │   ├── captive_portal.hpp
│           │   └── time_utils.hpp
│           └── src/                    # Matching .cpp implementations
└── App_P4/                             # iOS/macOS SwiftUI client
    ├── Gata_RC.xcodeproj
    ├── Gata_RC.xcworkspace
    ├── Podfile                         # CocoaPods (MediaPipeTasksVision)
    ├── pose_landmarker_lite.task       # MediaPipe model, 5.5 MB
    ├── pose_landmarker_full.task       # MediaPipe model, 9.0 MB
    └── Gata_RC/
        ├── GATA_RC_P4App.swift
        ├── ContentView.swift
        ├── VehicleControl.swift
        ├── Core/                       # Constants, NetHolder
        ├── Models/                     # AppModel, DataModels
        ├── Networking/                 # ControlUDPManager, ControllerBridge
        ├── Video/                      # HardwareH264Decoder, UDPVideoClient
        ├── Audio/                      # UDPAudioClient
        ├── HUD/                        # HUDView, Shapes
        ├── UI/                         # VideoViews, CyberText, AIOverlayView
        ├── AI/                         # MediaPipeVisionManager, Kalman, PID
        └── Utilities/                  # CRC16, ByteHelpers, Threading
```

The `App_P4` folder name is historical — it was the ESP32-P4 variant of the same project. The current firmware under `GATA_S3/` targets the Waveshare ESP32-S3-Zero, and the app speaks the same wire protocol to both.

## Build and run

### ESP32-S3 firmware

Requires ESP-IDF 5.2 or newer on your PATH (`. $IDF_PATH/export.sh`).

```bash
cd GATA_S3
idf.py set-target esp32s3
idf.py build
idf.py -p /dev/cu.usbmodem1101 flash monitor
```

Replace `/dev/cu.usbmodem1101` with the serial port your S3-Zero enumerates as. UART0 debug output is 115200 baud on GPIO 43/44. Exit `monitor` with `Ctrl-]`.

### iOS/macOS remote controller

```bash
cd App_P4
pod install       # MediaPipeTasksVision
open Gata_RC.xcworkspace
# In Xcode: set your Team ID under Signing & Capabilities, then Run
```

Xcode 15 or newer. iOS 15 deployment target (defined in `Podfile`). Use the `.xcworkspace` (not the `.xcodeproj`) because CocoaPods is required for MediaPipe.

## Configuration

Before building, set these placeholders:

| Placeholder | File | What it is |
|---|---|---|
| `YOUR_TEAM_ID` | `App_P4/Gata_RC.xcodeproj/project.pbxproj` | Apple developer Team ID (Signing and Capabilities) |
| `your-wifi-password` | `GATA_S3/components/s3_core/include/config.hpp` | SoftAP password, minimum 8 characters (`WiFiConfig::PASSWORD`) |

The WiFi SSID default is `GATA_P4_HOST` and lives in the same header at `WiFiConfig::SSID`. Change it there if you want a different AP name — the iOS app reads the hardcoded host IP `192.168.4.1` from `App_P4/Gata_RC/Core/Constants.swift` (`P4Host.ip`), so the SSID is free to rename as long as the client joins the right network.

Port numbers are defined in both places so client and firmware stay in sync:

- `GATA_S3/components/s3_core/include/config.hpp` → `NetworkPorts::{CONTROL=3333, VIDEO=3334, AUDIO=3335}`
- `App_P4/Gata_RC/Core/Constants.swift` → `NetworkPorts.{control, video, audio}`

UDP 3335 is reserved for a future audio return path and is currently unused. The video bridge ingest port (UDP 4000) is set in `VideoBridgeConfig::INGEST_PORT` in the same header.

## Control protocol

16-byte control frame, unidirectional iPhone → S3 on UDP 3333, little-endian, `#pragma pack(1)`:

```
offset  size  field       notes
0       2     magic       0x5A 0xA5
2       1     version     0x01
3       2     throttle    uint16, R2 trigger, 0..1023
5       2     reverse     uint16, L2 trigger, 0..1023
7       2     steering    int16,  LX stick, -512..+512 (positive = right)
9       1     brake       uint8,  Square button, 0 or 1
10      4     sequence    uint32, strictly increasing
14      2     crc16       CRC-16/CCITT over bytes 0..13
```

The firmware validates the magic bytes, then the CRC-16/CCITT over the first 14 bytes, then runs a sequence gate that tracks duplicates, out-of-order frames, and gaps (all exposed via `ControlStats` and echoed back through the telemetry extension). `poll_control` drains up to 4 frames per tick on `MSG_DONTWAIT` so a burst never backs up the socket.

Handshake: the client sends a burst of `HEL0` 8-byte hello packets to UDP 3333. The firmware replies `OKAY` on the same socket and latches the client address for use by the telemetry sender.

Failsafe: if no valid control frame is received for more than 120 ms, the failsafe state machine cuts the ESC to neutral (1500 us) and centers the servo. Rearm requires a 300 ms guard window plus 150 ms of continuous neutral input (both triggers below `FailsafeConfig::ARM_EPS = 60`, brake released) before control is handed back to the normal path. All of this is in `control_receiver.cpp::process_control_loop`.

Video path: H.264 Annex-B over UDP, 28-byte `H264Header` + up to 1400-byte chunked NAL payload. The Pi sends to UDP 4000 on the S3. The S3 validates the `"H264"` magic, takes the `NetworkLock` with a 50 ms timeout, and forwards to the registered client on UDP 3334. The iOS side reassembles chunks in `HardwareH264Decoder.swift` and feeds `AVSampleBufferDisplayLayer`.

Telemetry: 1 Hz `TEL1` packet plus an 8-byte `TelemetryExtV1` extension (last control sequence + estimated lost packets) is sent back to the registered client. The sender shares the client address captured by the control receiver, so one registered endpoint serves both channels.

## Captive portal

On first power-up the firmware brings up the SoftAP and starts a minimal captive-portal pair: a DNS spoofer bound to UDP 53 that answers every A-record query with `192.168.4.1`, plus `esp_http_server` on TCP 80 that returns `"Success"` on any URI. This clears iOS's "Log in to network" sheet and stops the phone from dropping the SoftAP because it failed the Apple captive-portal check. The implementation is in `captive_portal.cpp` and is started unconditionally from `app_main`.

## Pose-landmark auto-steering (experimental, optional)

The iOS app bundles Google MediaPipe's `pose_landmarker_lite.task` (5.5 MB) and `pose_landmarker_full.task` (9.0 MB) models, wired up through `AI/MediaPipeVisionManager.swift`. When enabled in the HUD, the app runs pose inference on the camera preview and derives a steering suggestion from the driver's upper-body lean angle, smoothed through a SIMD Kalman filter (`AI/SIMDKalmanFilter.swift`) and a PID (`AI/PIDController.swift`). This is off by default, intended as a hands-free experiment, and is not a production control mode.

## Status

- **Firmware:** builds on ESP-IDF 5.2 with `idf.py set-target esp32s3`. Verified on Waveshare ESP32-S3-Zero (4 MB flash, no PSRAM). Running simultaneously: 200 Hz control, 1 Hz telemetry, 30 fps 1280x720 H.264 bridge, captive portal, all on one chip.
- **iOS/macOS app:** builds on Xcode 15+, CocoaPods for MediaPipeTasksVision. Tested with PS4 and PS5 DualSense controllers over Apple's GameController framework.
- **Pose landmark:** experimental, models bundled, UI toggle hidden by default.

## License

MIT — see `LICENSE`.
