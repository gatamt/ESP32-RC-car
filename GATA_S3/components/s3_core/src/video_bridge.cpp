// video_bridge.cpp - UDP Video Bridge
// Receives H.264 packets from RPi and forwards to iOS app
#include "video_bridge.hpp"
#include "wifi_ap.hpp"
#include "config.hpp"
#include "protocol.hpp"
#include "time_utils.hpp"
#include "network_mutex.hpp"

#include "lwip/sockets.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <string.h>

// Sockets
static int s_ingest_sock = -1;   // RPi -> C6
static int s_forward_sock = -1;  // C6 -> App

// Remote endpoint for app
static struct sockaddr_in s_app_addr = {};
static bool s_app_registered = false;

// Stats
static VideoBridgeStats s_stats = {};
static uint32_t s_frames_this_second = 0;
static uint32_t s_last_fps_tick = 0;

// Track last frame id
static uint32_t s_last_frame_id = 0;

static bool set_nonblocking(int sock) {
    int flags = fcntl(sock, F_GETFL, 0);
    if (flags < 0) return false;
    return fcntl(sock, F_SETFL, flags | O_NONBLOCK) == 0;
}

static void close_socket(int& sock) {
    if (sock >= 0) {
        close(sock);
        sock = -1;
    }
}

static bool init_ingest_socket() {
    s_ingest_sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_IP);
    if (s_ingest_sock < 0) {
        return false;
    }

    // Larger receive buffer
    int optval = PerfConfig::UDP_RECV_BUFFER;
    setsockopt(s_ingest_sock, SOL_SOCKET, SO_RCVBUF, &optval, sizeof(optval));

    struct sockaddr_in local = {};
    local.sin_family = AF_INET;
    local.sin_port = htons(VideoBridgeConfig::INGEST_PORT);
    local.sin_addr.s_addr = htonl(INADDR_ANY);

    if (bind(s_ingest_sock, (struct sockaddr*)&local, sizeof(local)) < 0) {
        close_socket(s_ingest_sock);
        return false;
    }

    set_nonblocking(s_ingest_sock);
    return true;
}

static bool init_forward_socket() {
    s_forward_sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_IP);
    if (s_forward_sock < 0) {
        return false;
    }

    // Send buffer
    int optval = PerfConfig::UDP_SEND_BUFFER;
    setsockopt(s_forward_sock, SOL_SOCKET, SO_SNDBUF, &optval, sizeof(optval));

    // Low delay TOS
    optval = 0x10;  // IPTOS_LOWDELAY
    setsockopt(s_forward_sock, IPPROTO_IP, IP_TOS, &optval, sizeof(optval));

    // Bind to video port to receive registration
    struct sockaddr_in local = {};
    local.sin_family = AF_INET;
    local.sin_port = htons(NetworkPorts::VIDEO);
    local.sin_addr.s_addr = htonl(INADDR_ANY);

    if (bind(s_forward_sock, (struct sockaddr*)&local, sizeof(local)) < 0) {
        close_socket(s_forward_sock);
        return false;
    }

    set_nonblocking(s_forward_sock);

    return true;
}

static void poll_app_registration() {
    if (s_forward_sock < 0) return;

    uint8_t buf[8];
    struct sockaddr_in from = {};
    socklen_t from_len = sizeof(from);

    int n = recvfrom(s_forward_sock, buf, sizeof(buf), MSG_DONTWAIT,
                     (struct sockaddr*)&from, &from_len);
    if (n >= 4 && buf[0] == 'V' && buf[1] == 'I' && buf[2] == 'D' && buf[3] == '0') {
        s_app_addr = from;
        s_app_addr.sin_port = htons(NetworkPorts::VIDEO);
        s_app_registered = true;

        // Reset stats
        s_stats.frames_forwarded = 0;
        s_stats.frames_dropped = 0;
        s_stats.bytes_sent = 0;
        s_frames_this_second = 0;
        s_last_fps_tick = millis32();
    }
}

static void update_fps_stats() {
    uint32_t now = millis32();
    if (s_last_fps_tick == 0) {
        s_last_fps_tick = now;
        return;
    }

    if (now - s_last_fps_tick >= 1000) {
        s_stats.current_fps = s_frames_this_second;
        s_frames_this_second = 0;
        s_last_fps_tick = now;
    }
}

static void process_packet(const uint8_t* data, size_t len) {
    if (len < sizeof(H264Header)) {
        return;
    }

    const H264Header* hdr = reinterpret_cast<const H264Header*>(data);

    // Validate magic
    if (memcmp(hdr->magic, "H264", 4) != 0 || hdr->chunk_count == 0) {
        return;
    }

    size_t payload_len = len - sizeof(H264Header);
    if (payload_len > VideoBridgeConfig::MAX_INGEST_PACKET) {
        return;
    }

    bool frame_complete = (hdr->chunk_idx + 1) == hdr->chunk_count;
    if (hdr->frame_id != s_last_frame_id && hdr->chunk_idx == 0) {
        s_last_frame_id = hdr->frame_id;
    }

    // Check conditions for forwarding
    if (!wifi_is_ready() || !s_app_registered) {
        if (frame_complete) {
            s_stats.frames_dropped++;
        }
        return;
    }

    // Forward to app (serialize with other network users)
    NetworkLock lock(50);
    if (!lock) {
        if (frame_complete) {
            s_stats.frames_dropped++;
        }
        return;
    }

    ssize_t sent = sendto(
        s_forward_sock,
        data,
        len,
        0,
        reinterpret_cast<struct sockaddr*>(&s_app_addr),
        sizeof(s_app_addr));

    if (sent < 0) {
        if (frame_complete) {
            s_stats.frames_dropped++;
        }
        return;
    }

    s_stats.bytes_sent += sent;
    if (frame_complete) {
        s_stats.frames_forwarded++;
        s_frames_this_second++;
    }
}

static void pump_ingest() {
    if (s_ingest_sock < 0) return;

    uint8_t buffer[VideoBridgeConfig::MAX_INGEST_PACKET];
    struct sockaddr_in from = {};
    socklen_t from_len = sizeof(from);

    int n = recvfrom(s_ingest_sock, buffer, sizeof(buffer), MSG_DONTWAIT,
                     reinterpret_cast<struct sockaddr*>(&from), &from_len);

    while (n > 0) {
        process_packet(buffer, static_cast<size_t>(n));
        n = recvfrom(s_ingest_sock, buffer, sizeof(buffer), MSG_DONTWAIT,
                     reinterpret_cast<struct sockaddr*>(&from), &from_len);
    }
}

bool video_bridge_init() {
    close_socket(s_ingest_sock);
    close_socket(s_forward_sock);

    if (!init_ingest_socket()) {
        return false;
    }

    if (!init_forward_socket()) {
        close_socket(s_ingest_sock);
        return false;
    }

    s_app_registered = false;
    s_stats = {};
    s_frames_this_second = 0;
    s_last_fps_tick = millis32();
    s_last_frame_id = 0;
    return true;
}

void video_bridge_deinit() {
    close_socket(s_ingest_sock);
    close_socket(s_forward_sock);
    s_app_registered = false;
}

bool video_app_ready() {
    return s_app_registered && wifi_is_ready();
}

bool video_get_app_addr(struct sockaddr_in* out_addr) {
    if (!s_app_registered || !out_addr) {
        return false;
    }
    *out_addr = s_app_addr;
    return true;
}

void video_bridge_task(void* pvParameters) {
    // Wait for WiFi
    while (!wifi_is_ready()) {
        vTaskDelay(pdMS_TO_TICKS(100));
    }

    // Init sockets
    while (!video_bridge_init()) {
        vTaskDelay(pdMS_TO_TICKS(1000));
    }

    for (;;) {
        poll_app_registration();
        pump_ingest();
        update_fps_stats();
        vTaskDelay(pdMS_TO_TICKS(1));  // Yield to other tasks
    }
}

VideoBridgeStats video_get_stats() {
    return s_stats;
}
