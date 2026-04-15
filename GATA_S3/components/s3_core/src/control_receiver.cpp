// control_receiver.cpp - Control Command Receiver with Motor Control Logic
// Combines UDP reception with drive logic from GATA_S3_zero
#include "control_receiver.hpp"
#include "motor_control.hpp"
#include "config.hpp"
#include "protocol.hpp"
#include "time_utils.hpp"

#include "lwip/sockets.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include <string.h>
#include <math.h>
#include <errno.h>
#include <fcntl.h>

// Socket
static int s_ctrl_sock = -1;

// Control state (protected by critical section)
static portMUX_TYPE s_rx_mux = portMUX_INITIALIZER_UNLOCKED;
static volatile ControlFrame s_rx_frame = {};
static volatile uint32_t s_last_cmd_ms = 0;

// Sequence tracking
static volatile uint32_t s_last_seq = 0;
static volatile bool s_have_seq = false;
static volatile bool s_seq_enabled = false;

// App address (from control channel)
static struct sockaddr_in s_app_addr = {};
static volatile bool s_app_addr_valid = false;

// Failsafe state
static volatile bool s_failsafe_active = true;
static volatile uint32_t s_failsafe_since_ms = 0;
static volatile uint32_t s_neutral_since_ms = 0;

// Brake state
static bool s_last_brake = false;
static bool s_brake_latched = false;
static int8_t s_brake_dir = 0;

// Movement tracking
static int8_t s_last_move_dir = 0;
static uint32_t s_last_move_ms = 0;

// Current motor state
static float s_current_pct = 0.0f;
static int s_servo_current = ServoConfig::CENTER_US;

// Statistics
static ControlStats s_stats = {};

// Pre-allocated receive buffer
static uint8_t s_ctrl_buf[128];

static void update_app_addr(const struct sockaddr_in* from) {
    if (!from) return;
    s_app_addr = *from;
    s_app_addr_valid = true;
}

static bool handle_hello_packet(int n, const struct sockaddr_in* from) {
    if (n < (int)sizeof(HelloPacket)) {
        return false;
    }

    const HelloPacket* hello = (const HelloPacket*)s_ctrl_buf;
    if (memcmp(hello->magic, "HEL0", 4) != 0) {
        return false;
    }

    update_app_addr(from);

    HelloAckPacket ack = {};
    memcpy(ack.magic, "OKAY", 4);
    ack.version = ControlConfig::VERSION;
    ack.flags = 0;
    ack.reserved = 0;

    sendto(s_ctrl_sock, &ack, sizeof(ack), 0,
           (const struct sockaddr*)from, sizeof(*from));

    return true;
}

static bool init_socket() {
    s_ctrl_sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_IP);
    if (s_ctrl_sock < 0) {
        return false;
    }

    // Larger receive buffer
    int optval = PerfConfig::UDP_RECV_BUFFER;
    setsockopt(s_ctrl_sock, SOL_SOCKET, SO_RCVBUF, &optval, sizeof(optval));
    optval = 1;
    setsockopt(s_ctrl_sock, SOL_SOCKET, SO_REUSEADDR, &optval, sizeof(optval));

    struct sockaddr_in local = {};
    local.sin_family = AF_INET;
    local.sin_port = htons(NetworkPorts::CONTROL);
    local.sin_addr.s_addr = htonl(INADDR_ANY);

    if (bind(s_ctrl_sock, (struct sockaddr*)&local, sizeof(local)) < 0) {
        close(s_ctrl_sock);
        s_ctrl_sock = -1;
        return false;
    }

    // Non-blocking mode
    fcntl(s_ctrl_sock, F_SETFL, O_NONBLOCK);
    return true;
}

static void poll_control() {
    if (s_ctrl_sock < 0) return;

    struct sockaddr_in from = {};
    socklen_t from_len = sizeof(from);

    // Read up to 4 packets per call
    for (int batch = 0; batch < 4; batch++) {
        int n = recvfrom(s_ctrl_sock, s_ctrl_buf, sizeof(s_ctrl_buf), MSG_DONTWAIT,
                         (struct sockaddr*)&from, &from_len);
        if (n <= 0) break;

        if (handle_hello_packet(n, &from)) {
            continue;
        }

        // Minimum packet size check
        if (n < (int)sizeof(ControlFrame)) {
            s_stats.frames_invalid++;
            continue;
        }

        // Cast to frame
        const ControlFrame* frame = (const ControlFrame*)s_ctrl_buf;

        // Magic check
        if (frame->magic[0] != ControlConfig::MAGIC_0 ||
            frame->magic[1] != ControlConfig::MAGIC_1) {
            s_stats.frames_invalid++;
            continue;
        }

        // CRC validation
        if (!verify_control_frame(frame)) {
            s_stats.crc_errors++;
            continue;
        }

        // Sequence gating
        uint32_t seq = frame->sequence;
        if (!s_have_seq) {
            s_last_seq = seq;
            s_have_seq = true;
        } else if (!s_seq_enabled) {
            if (seq != s_last_seq) {
                s_seq_enabled = true;
                s_last_seq = seq;
            }
        } else {
            uint32_t diff = seq - s_last_seq;
            if (diff == 0) {
                s_stats.seq_duplicates++;
                continue;  // Duplicate
            }
            if (diff > 0x80000000UL) {
                s_stats.seq_out_of_order++;
                continue;  // Out of order
            }
            if (diff > 1) {
                s_stats.seq_gaps += (diff - 1);
            }
            s_last_seq = seq;
        }

        uint32_t now = millis32();

        update_app_addr(&from);

        // Update shared state
        portENTER_CRITICAL(&s_rx_mux);
        memcpy((void*)&s_rx_frame, frame, sizeof(ControlFrame));
        s_last_cmd_ms = now;
        portEXIT_CRITICAL(&s_rx_mux);

        s_stats.frames_received++;
        s_stats.last_sequence = seq;
    }
}

static void process_control_loop(uint32_t now, uint32_t dt) {
    // Read shared state
    ControlFrame cmd;
    uint32_t local_last_cmd;

    portENTER_CRITICAL(&s_rx_mux);
    memcpy(&cmd, (const void*)&s_rx_frame, sizeof(ControlFrame));
    local_last_cmd = s_last_cmd_ms;
    portEXIT_CRITICAL(&s_rx_mux);

    // Failsafe logic
    float target_pct = 0.0f;
    int servo_tgt = ServoConfig::CENTER_US;

    uint32_t since_cmd = (local_last_cmd == 0)
                         ? 0xFFFFFFFFUL
                         : (now - local_last_cmd);
    bool timeout = (since_cmd > FailsafeConfig::TIMEOUT_MS);

    // Enter failsafe on timeout
    if ((timeout || local_last_cmd == 0) && !s_failsafe_active) {
        s_failsafe_active = true;
        s_failsafe_since_ms = now;
        s_neutral_since_ms = 0;
        s_stats.timeout_count++;
    }

    // Failsafe mode
    if (s_failsafe_active) {
        // Check for rearm conditions
        if (!timeout && local_last_cmd != 0 &&
            (now - s_failsafe_since_ms) > FailsafeConfig::REARM_GUARD_MS) {

            const int r2v = constrain_int(cmd.throttle, 0, DriveConfig::TRIGGER_MAX);
            const int l2v = constrain_int(cmd.reverse, 0, DriveConfig::TRIGGER_MAX);
            const bool do_brake = (cmd.brake != 0);

            bool neutral = (r2v <= FailsafeConfig::ARM_EPS) &&
                          (l2v <= FailsafeConfig::ARM_EPS) &&
                          (!do_brake);

            if (neutral) {
                if (s_neutral_since_ms == 0) s_neutral_since_ms = now;
                if (now - s_neutral_since_ms >= FailsafeConfig::ARM_HOLD_MS) {
                    s_failsafe_active = false;
                    s_neutral_since_ms = 0;
                }
            } else {
                s_neutral_since_ms = 0;
            }
        }

        // Stay in failsafe
        if (s_failsafe_active) {
            target_pct = 0.0f;
            servo_tgt = ServoConfig::CENTER_US;
            s_brake_latched = false;
            s_brake_dir = 0;
            s_last_brake = false;

            esc_write_pct(0.0f);
            s_servo_current = ServoConfig::CENTER_US;
            servo_write_us(s_servo_current);
            return;
        }
    }

    // Normal control logic (from GATA_S3_zero)
    {
        const int r2v = constrain_int(cmd.throttle, 0, DriveConfig::TRIGGER_MAX);
        const int l2v = constrain_int(cmd.reverse, 0, DriveConfig::TRIGGER_MAX);
        const bool do_brake = (cmd.brake != 0);

        // Determine instantaneous direction
        int8_t inst_dir = 0;
        if (r2v > 0 && l2v == 0)      inst_dir = +1;
        else if (l2v > 0 && r2v == 0) inst_dir = -1;
        else if (fabsf(s_current_pct) > DriveConfig::STOP_EPS_PCT) {
            inst_dir = (s_current_pct > 0.0f) ? +1 : -1;
        }

        if (inst_dir != 0) {
            s_last_move_dir = inst_dir;
            s_last_move_ms = now;
        }

        // Brake logic
        if (do_brake && !s_last_brake) {
            int8_t dir = 0;
            if (inst_dir != 0) {
                dir = inst_dir;
            } else if (now - s_last_move_ms <= DriveConfig::LAST_DIR_HOLD_MS) {
                dir = s_last_move_dir;
            }
            s_brake_dir = dir;
            s_brake_latched = true;
        }

        if (!do_brake && s_last_brake) {
            s_brake_latched = false;
            s_brake_dir = 0;
        }

        s_last_brake = do_brake;

        // Calculate target outputs
        if (do_brake && s_brake_latched) {
            if (s_brake_dir < 0) {
                target_pct = 0.0f;
            } else {
                target_pct = -(float)DriveConfig::BRAKE_STRENGTH_PCT;
            }
        } else {
            float fwd_pct = (r2v * 100.0f) / (float)DriveConfig::TRIGGER_MAX;
            float rev_pct = -((l2v * (float)DriveConfig::REVERSE_MAX_PCT) / (float)DriveConfig::TRIGGER_MAX);
            target_pct = (r2v > 0) ? fwd_pct : rev_pct;
        }

        // Steering (note: negated lx for correct direction)
        servo_tgt = stick_x_to_servo_us(-cmd.steering);
    }

    // Apply smoothing
    bool braking_now = s_brake_latched && s_last_brake;
    float alpha_esc = (braking_now || DriveConfig::TAU_MS <= 0)
                      ? 1.0f
                      : fminf(1.0f, (float)dt / (float)DriveConfig::TAU_MS);

    float alpha_servo = (ServoConfig::TAU_MS <= 0)
                        ? 1.0f
                        : fminf(1.0f, (float)dt / (float)ServoConfig::TAU_MS);

    float next_pct = s_current_pct + alpha_esc * (target_pct - s_current_pct);
    s_current_pct = next_pct;
    esc_write_pct(next_pct);

    s_servo_current = (int)lroundf(
        s_servo_current + alpha_servo * (servo_tgt - s_servo_current)
    );
    servo_write_us(s_servo_current);
}

bool control_init() {
    if (!init_socket()) {
        return false;
    }

    // Initialize failsafe state
    s_failsafe_active = true;
    s_failsafe_since_ms = millis32();
    s_neutral_since_ms = 0;

    // Reset sequence tracking
    s_have_seq = false;
    s_seq_enabled = false;
    s_last_seq = 0;

    return true;
}

void control_deinit() {
    if (s_ctrl_sock >= 0) {
        close(s_ctrl_sock);
        s_ctrl_sock = -1;
    }
}

void control_task(void* pvParameters) {
    TickType_t last_wake = xTaskGetTickCount();
    uint32_t last_ms = millis32();

    while (true) {
        // 200 Hz timing (5ms)
        vTaskDelayUntil(&last_wake, pdMS_TO_TICKS(5));

        // Poll for incoming UDP commands
        poll_control();

        // Calculate dt
        uint32_t now = millis32();
        uint32_t dt = now - last_ms;
        if (dt == 0) dt = 1;
        last_ms = now;

        // Process control logic
        process_control_loop(now, dt);
    }
}

bool control_get_last_frame(ControlFrame* out_frame) {
    if (!out_frame) return false;

    portENTER_CRITICAL(&s_rx_mux);
    memcpy(out_frame, (const void*)&s_rx_frame, sizeof(ControlFrame));
    portEXIT_CRITICAL(&s_rx_mux);

    return s_last_cmd_ms != 0;
}

uint32_t control_get_last_frame_age() {
    uint32_t last;
    portENTER_CRITICAL(&s_rx_mux);
    last = s_last_cmd_ms;
    portEXIT_CRITICAL(&s_rx_mux);

    if (last == 0) return 0xFFFFFFFF;
    return millis32() - last;
}

bool control_is_connected() {
    return !s_failsafe_active && s_last_cmd_ms != 0;
}

ControlStats control_get_stats() {
    return s_stats;
}

bool control_get_app_addr(struct sockaddr_in* out_addr) {
    if (!out_addr || !s_app_addr_valid) {
        return false;
    }
    *out_addr = s_app_addr;
    return true;
}
