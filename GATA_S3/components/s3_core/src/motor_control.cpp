// motor_control.cpp - ESC + Servo PWM Control
// Uses LEDC peripheral for PWM generation
#include "motor_control.hpp"
#include "config.hpp"

#include "driver/ledc.h"
#include "esp_attr.h"

#include <math.h>

// PWM configuration
static const ledc_mode_t PWM_MODE = LEDC_LOW_SPEED_MODE;
static const ledc_timer_bit_t PWM_RES = LEDC_TIMER_14_BIT;

// Current state
static float s_current_pct = 0.0f;
static int s_servo_current = ServoConfig::CENTER_US;

// Helper functions
int constrain_int(int v, int lo, int hi) {
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

float constrain_f(float v, float lo, float hi) {
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

static inline IRAM_ATTR uint32_t us_to_duty_esc(uint32_t us) {
    return (us * ESCConfig::MAX_DUTY) / ESCConfig::PERIOD_US;
}

static inline IRAM_ATTR uint32_t us_to_duty_servo(uint32_t us) {
    return (us * ServoConfig::MAX_DUTY) / ServoConfig::PERIOD_US;
}

void pwm_init() {
    // ESC Timer (250 Hz for ESC)
    ledc_timer_config_t esc_timer = {};
    esc_timer.speed_mode = PWM_MODE;
    esc_timer.timer_num = LEDC_TIMER_0;
    esc_timer.freq_hz = ESCConfig::FREQ_HZ;
    esc_timer.duty_resolution = (ledc_timer_bit_t)ESCConfig::RESOLUTION_BITS;
    esc_timer.clk_cfg = LEDC_AUTO_CLK;
    ESP_ERROR_CHECK(ledc_timer_config(&esc_timer));

    // ESC Channel
    ledc_channel_config_t esc_ch = {};
    esc_ch.gpio_num = ESCConfig::PIN;
    esc_ch.speed_mode = PWM_MODE;
    esc_ch.channel = LEDC_CHANNEL_0;
    esc_ch.timer_sel = LEDC_TIMER_0;
    esc_ch.duty = us_to_duty_esc(ESCConfig::NEUTRAL_US);
    esc_ch.hpoint = 0;
    ESP_ERROR_CHECK(ledc_channel_config(&esc_ch));

    // Servo Timer (50 Hz for standard servo)
    ledc_timer_config_t srv_timer = {};
    srv_timer.speed_mode = PWM_MODE;
    srv_timer.timer_num = LEDC_TIMER_1;
    srv_timer.freq_hz = ServoConfig::FREQ_HZ;
    srv_timer.duty_resolution = (ledc_timer_bit_t)ServoConfig::RESOLUTION_BITS;
    srv_timer.clk_cfg = LEDC_AUTO_CLK;
    ESP_ERROR_CHECK(ledc_timer_config(&srv_timer));

    // Servo Channel
    ledc_channel_config_t srv_ch = {};
    srv_ch.gpio_num = ServoConfig::PIN;
    srv_ch.speed_mode = PWM_MODE;
    srv_ch.channel = LEDC_CHANNEL_1;
    srv_ch.timer_sel = LEDC_TIMER_1;
    srv_ch.duty = us_to_duty_servo(ServoConfig::CENTER_US);
    srv_ch.hpoint = 0;
    ESP_ERROR_CHECK(ledc_channel_config(&srv_ch));
}

void pwm_deinit() {
    ledc_stop(PWM_MODE, LEDC_CHANNEL_0, 0);
    ledc_stop(PWM_MODE, LEDC_CHANNEL_1, 0);
}

IRAM_ATTR void esc_write_us(int us) {
    us = constrain_int(us, ESCConfig::MIN_US, ESCConfig::MAX_US);
    uint32_t duty = us_to_duty_esc((uint32_t)us);
    ledc_set_duty(PWM_MODE, LEDC_CHANNEL_0, duty);
    ledc_update_duty(PWM_MODE, LEDC_CHANNEL_0);
}

int pct_to_us(float pct) {
    pct = constrain_f(pct, -100.0f, 100.0f);
    const float upSpan = (float)(ESCConfig::MAX_US - ESCConfig::NEUTRAL_US);
    const float downSpan = (float)(ESCConfig::NEUTRAL_US - ESCConfig::MIN_US);

    if (pct >= 0.0f) {
        return (int)lroundf(ESCConfig::NEUTRAL_US + upSpan * (pct / 100.0f));
    } else {
        return (int)lroundf(ESCConfig::NEUTRAL_US - downSpan * ((-pct) / 100.0f));
    }
}

IRAM_ATTR void esc_write_pct(float pct) {
    s_current_pct = constrain_f(pct, -100.0f, 100.0f);
    esc_write_us(pct_to_us(s_current_pct));
}

float esc_get_current_pct() {
    return s_current_pct;
}

IRAM_ATTR void servo_write_us(int us) {
    us = constrain_int(us, ServoConfig::MIN_US, ServoConfig::MAX_US);
    s_servo_current = us;
    uint32_t duty = us_to_duty_servo((uint32_t)us);
    ledc_set_duty(PWM_MODE, LEDC_CHANNEL_1, duty);
    ledc_update_duty(PWM_MODE, LEDC_CHANNEL_1);
}

int stick_x_to_servo_us(int ax) {
    ax = constrain_int(ax, -DriveConfig::STICK_ABS_MAX, DriveConfig::STICK_ABS_MAX);
    const float x = (float)ax / (float)DriveConfig::STICK_ABS_MAX;
    const float amp = (ServoConfig::MAX_US - ServoConfig::MIN_US) * 0.5f;
    const int us = (int)lroundf(ServoConfig::CENTER_US + x * amp);
    return constrain_int(us, ServoConfig::MIN_US, ServoConfig::MAX_US);
}

int servo_get_current_us() {
    return s_servo_current;
}
