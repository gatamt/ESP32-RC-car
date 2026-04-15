// telemetry.cpp - Telemetry Data Transmission
// Sends status data to iPhone app
#include "telemetry.hpp"
#include "config.hpp"
#include "control_receiver.hpp"
#include "motor_control.hpp"
#include "protocol.hpp"
#include "time_utils.hpp"
#include "video_bridge.hpp"
#include "wifi_ap.hpp"

#include "esp_wifi.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "lwip/sockets.h"
#include <cmath>

// ESP32-S3 temperature sensor
#if CONFIG_IDF_TARGET_ESP32S3
#include "driver/temperature_sensor.h"
static temperature_sensor_handle_t s_temp_sensor = NULL;
#endif

#include <arpa/inet.h>
#include <errno.h>
#include <string.h>

// Socket
static int s_tele_sock = -1;

// Statistics
static uint32_t s_packets_sent = 0;
static uint32_t s_send_errors = 0;

static uint8_t telemetry_get_wifi_rssi() {
  wifi_sta_list_t sta_list = {};
  if (esp_wifi_ap_get_sta_list(&sta_list) != ESP_OK || sta_list.num == 0) {
    return 0;
  }

  int8_t best_rssi = -127;
  for (int i = 0; i < sta_list.num; i++) {
    const int8_t rssi = sta_list.sta[i].rssi;
    if (rssi > best_rssi) {
      best_rssi = rssi;
    }
  }

  int mag = (best_rssi < 0) ? -best_rssi : best_rssi;
  if (mag > 100)
    mag = 100;
  return (uint8_t)mag;
}

bool telemetry_init() {
  // Create UDP socket
  s_tele_sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_IP);
  if (s_tele_sock < 0) {
    return false;
  }

  // Initialize temperature sensor (ESP32-S3)
#if CONFIG_IDF_TARGET_ESP32S3
  temperature_sensor_config_t temp_cfg =
      TEMPERATURE_SENSOR_CONFIG_DEFAULT(-10, 80);
  esp_err_t err = temperature_sensor_install(&temp_cfg, &s_temp_sensor);
  if (err == ESP_OK) {
    temperature_sensor_enable(s_temp_sensor);
  } else {
    s_temp_sensor = NULL;
  }
#endif

  return true;
}

void telemetry_deinit() {
  if (s_tele_sock >= 0) {
    close(s_tele_sock);
    s_tele_sock = -1;
  }

#if CONFIG_IDF_TARGET_ESP32S3
  if (s_temp_sensor) {
    temperature_sensor_disable(s_temp_sensor);
    temperature_sensor_uninstall(s_temp_sensor);
    s_temp_sensor = NULL;
  }
#endif
}

int8_t telemetry_read_cpu_temp() {
#if CONFIG_IDF_TARGET_ESP32S3
  if (s_temp_sensor) {
    float temp = 0.0f;
    if (temperature_sensor_get_celsius(s_temp_sensor, &temp) == ESP_OK) {
      return (int8_t)temp;
    }
  }
#endif
  return 0;
}

TelemetryData telemetry_get_data() {
  TelemetryData data = {};

  // Battery: Always 0 (disabled for S3 setup)
  data.battery_percent = 0;

  // CPU temperature
  data.cpu_temperature = telemetry_read_cpu_temp();

  // Motor speeds (we don't have real motor feedback, use throttle value)
  float pct = esc_get_current_pct();
  uint16_t speed = (uint16_t)(fabsf(pct) * 10.0f); // Scale to 0-1000
  data.motor_speed_left = speed;
  data.motor_speed_right = speed;

  // WiFi RSSI (use best station RSSI as a link quality indicator)
  data.wifi_rssi = (int8_t)telemetry_get_wifi_rssi();

  // Uptime
  data.uptime_ms = millis32();

  return data;
}

static void send_telemetry() {
  // Get app address from video bridge
  struct sockaddr_in app_addr;
  if (!control_get_app_addr(&app_addr) && !video_get_app_addr(&app_addr)) {
    // No app registered yet
    return;
  }

  // Change port to control port for telemetry
  app_addr.sin_port = htons(NetworkPorts::CONTROL);

  // Get telemetry data
  TelemetryData data = telemetry_get_data();

  // Build TEL1 packet
  TelemetryPacket pkt = {};
  memcpy(pkt.magic, "TEL1", 4);
  pkt.timestamp = millis32();
  pkt.battery_pct = data.battery_percent; // Always 0
  pkt.cpu_temp = data.cpu_temperature;
  pkt.motor_speed_l = data.motor_speed_left;
  pkt.motor_speed_r = data.motor_speed_right;
  pkt.latitude = 0; // No GPS
  pkt.longitude = 0;
  pkt.heading = 0;
  pkt.gps_fix = 0;
  pkt.wifi_rssi = data.wifi_rssi;
  pkt.reserved = 0;

  // Telemetry extension (control seq/loss)
  TelemetryExtV1 ext = {};
  ControlStats stats = control_get_stats();
  ext.ctrl_last_seq = stats.last_sequence;
  ext.ctrl_lost = stats.seq_gaps;

  // Send
  uint8_t buf[sizeof(TelemetryPacket) + sizeof(TelemetryExtV1)];
  memcpy(buf, &pkt, sizeof(pkt));
  memcpy(buf + sizeof(pkt), &ext, sizeof(ext));

  ssize_t sent = sendto(s_tele_sock, buf, sizeof(buf), 0,
                        (struct sockaddr *)&app_addr, sizeof(app_addr));

  if (sent < 0) {
    s_send_errors++;
  } else {
    s_packets_sent++;
  }
}

void telemetry_task(void *pvParameters) {
  // Wait for WiFi
  while (!wifi_is_ready()) {
    vTaskDelay(pdMS_TO_TICKS(100));
  }

  // Init
  if (!telemetry_init()) {
    vTaskDelete(NULL);
    return;
  }

  uint32_t last_send = 0;

  for (;;) {
    uint32_t now = millis32();

    // Send at configured interval
    if (now - last_send >= TelemetryConfig::SEND_INTERVAL_MS) {
      send_telemetry();
      last_send = now;
    }

    vTaskDelay(pdMS_TO_TICKS(100)); // Check every 100ms
  }
}
