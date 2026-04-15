// main.cpp - GATA RC for Waveshare ESP32-S3-Zero
// Combined video bridge + motor control + telemetry
// DUAL-CORE Xtensa LX7 @ 240MHz
//   Core 0 (PRO): WiFi stack, video bridge, telemetry
//   Core 1 (APP): control task (motor timing, isolated from WiFi interrupts)

extern "C" {
#include "esp_system.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "nvs_flash.h"
}

#include "captive_portal.hpp"
#include "config.hpp"
#include "control_receiver.hpp"
#include "motor_control.hpp"
#include "network_mutex.hpp"
#include "telemetry.hpp"
#include "video_bridge.hpp"
#include "wifi_ap.hpp"

extern "C" void app_main() {
  // Initialize NVS
  esp_err_t ret = nvs_flash_init();
  if (ret == ESP_ERR_NVS_NO_FREE_PAGES ||
      ret == ESP_ERR_NVS_NEW_VERSION_FOUND) {
    ESP_ERROR_CHECK(nvs_flash_erase());
    ret = nvs_flash_init();
  }
  ESP_ERROR_CHECK(ret);

  // Initialize network mutex (required for dual-core socket safety)
  network_mutex_init();

  // Initialize PWM and set neutral positions
  pwm_init();
  esc_write_pct(0.0f);
  servo_write_us(ServoConfig::CENTER_US);

  // Initialize WiFi AP
  wifi_init_ap();
  captive_portal_start();

  // Initialize control receiver
  if (!control_init()) {
    // Control init failed; nothing else to log
  }

  // Start FreeRTOS tasks pinned to specific cores
  // Core 1 (APP): control task — isolated from WiFi interrupt load
  xTaskCreatePinnedToCore(control_task, "control", TaskConfig::CONTROL_STACK,
                          NULL, TaskConfig::CONTROL_PRIORITY, NULL,
                          TaskConfig::CORE_CTRL);

  // Core 0 (PRO): video bridge — same core as WiFi stack, reduces context
  // switches
  xTaskCreatePinnedToCore(video_bridge_task, "video", TaskConfig::VIDEO_STACK,
                          NULL, TaskConfig::VIDEO_PRIORITY, NULL,
                          TaskConfig::CORE_VIDEO);

  // Core 0 (PRO): telemetry — low priority, alongside video
  xTaskCreatePinnedToCore(
      telemetry_task, "telemetry", TaskConfig::TELEMETRY_STACK, NULL,
      TaskConfig::TELEMETRY_PRIORITY, NULL, TaskConfig::CORE_TELE);
}
