// motor_control.hpp - ESC + Servo PWM Control
// Controls ESC (motor) and steering servo via LEDC
#pragma once

#include <stdint.h>
#include <stdbool.h>

// Initialize LEDC PWM for ESC and Servo
void pwm_init();

// Deinitialize PWM
void pwm_deinit();

// ESC Control
void esc_write_us(int us);
void esc_write_pct(float pct);
int pct_to_us(float pct);
float esc_get_current_pct();

// Servo Control
void servo_write_us(int us);
int stick_x_to_servo_us(int ax);
int servo_get_current_us();

// Utility functions
int constrain_int(int v, int lo, int hi);
float constrain_f(float v, float lo, float hi);
