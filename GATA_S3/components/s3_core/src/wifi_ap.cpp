// wifi_ap.cpp - WiFi Access Point Mode
// ESP32-C6 creates its own network for iPhone and RPi to connect
#include "wifi_ap.hpp"
#include "config.hpp"

#include "esp_wifi.h"
#include "esp_event.h"
#include "esp_netif.h"
#include "esp_mac.h"
#include "nvs_flash.h"
#include "freertos/FreeRTOS.h"
#include "freertos/event_groups.h"
#include "lwip/ip4_addr.h"

#include <string.h>

// State
static EventGroupHandle_t s_wifi_event_group = nullptr;
static const int WIFI_READY_BIT = BIT0;
static volatile bool s_ap_active = false;
static volatile int s_station_count = 0;
static char s_ip_str[16] = {0};

// Event handler
static void wifi_event_handler(void* arg, esp_event_base_t event_base,
                               int32_t event_id, void* event_data) {
    if (event_base == WIFI_EVENT) {
        switch (event_id) {
            case WIFI_EVENT_AP_START:
                s_ap_active = true;
                xEventGroupSetBits(s_wifi_event_group, WIFI_READY_BIT);
                break;

            case WIFI_EVENT_AP_STOP:
                s_ap_active = false;
                xEventGroupClearBits(s_wifi_event_group, WIFI_READY_BIT);
                break;

            case WIFI_EVENT_AP_STACONNECTED: {
                wifi_event_ap_staconnected_t* event =
                    (wifi_event_ap_staconnected_t*)event_data;
                s_station_count++;
                break;
            }

            case WIFI_EVENT_AP_STADISCONNECTED: {
                wifi_event_ap_stadisconnected_t* event =
                    (wifi_event_ap_stadisconnected_t*)event_data;
                if (s_station_count > 0) s_station_count--;
                break;
            }

            default:
                break;
        }
    }
}

void wifi_init_ap() {
    // Create event group
    s_wifi_event_group = xEventGroupCreate();

    // Initialize network interface
    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    esp_netif_t* ap_netif = esp_netif_create_default_wifi_ap();

    // Set static IP for SoftAP
    esp_netif_ip_info_t ip_info;
    if (!ip4addr_aton(WiFiConfig::AP_IP, reinterpret_cast<ip4_addr_t*>(&ip_info.ip))) {
        ip4addr_aton("192.168.4.1", reinterpret_cast<ip4_addr_t*>(&ip_info.ip));
    }
    ip_info.gw = ip_info.ip;
    IP4_ADDR(&ip_info.netmask, 255, 255, 255, 0);
    esp_netif_dhcps_stop(ap_netif);
    ESP_ERROR_CHECK(esp_netif_set_ip_info(ap_netif, &ip_info));
    esp_netif_dhcps_start(ap_netif);
    snprintf(s_ip_str, sizeof(s_ip_str), IPSTR, IP2STR(&ip_info.ip));

    // WiFi init
    wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
    cfg.static_rx_buf_num = WiFiConfig::STATIC_RX_BUFS;
    cfg.dynamic_rx_buf_num = WiFiConfig::DYNAMIC_RX_BUFS;
    cfg.tx_buf_type = 1;
    cfg.dynamic_tx_buf_num = WiFiConfig::DYNAMIC_TX_BUFS;
    cfg.ampdu_tx_enable = 1;
    cfg.ampdu_rx_enable = 1;
    cfg.nvs_enable = 0;
    ESP_ERROR_CHECK(esp_wifi_init(&cfg));

    // Register event handlers
    esp_event_handler_instance_t wifi_handler;
    ESP_ERROR_CHECK(esp_event_handler_instance_register(
        WIFI_EVENT, ESP_EVENT_ANY_ID, &wifi_event_handler, NULL, &wifi_handler));

    // AP configuration
    wifi_config_t ap_config = {};
    strncpy((char*)ap_config.ap.ssid, WiFiConfig::SSID, sizeof(ap_config.ap.ssid) - 1);
    strncpy((char*)ap_config.ap.password, WiFiConfig::PASSWORD, sizeof(ap_config.ap.password) - 1);
    ap_config.ap.ssid_len = strlen(WiFiConfig::SSID);
    ap_config.ap.channel = WiFiConfig::CHANNEL;
    ap_config.ap.max_connection = WiFiConfig::MAX_STA_CONN;
    ap_config.ap.authmode = WIFI_AUTH_WPA2_PSK;
    if (strlen(WiFiConfig::PASSWORD) < 8) {
        ap_config.ap.authmode = WIFI_AUTH_OPEN;
    }

    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_AP));
    ESP_ERROR_CHECK(esp_wifi_set_config(WIFI_IF_AP, &ap_config));

    // Disable power save for minimum latency
    ESP_ERROR_CHECK(esp_wifi_set_ps(WIFI_PS_NONE));

    // Start WiFi
    ESP_ERROR_CHECK(esp_wifi_start());

    // Set channel bandwidth (HT20 for stability, HT40 for throughput)
    wifi_bandwidth_t bw = (WiFiConfig::BANDWIDTH_MHZ == 40) ? WIFI_BW_HT40 : WIFI_BW_HT20;
    ESP_ERROR_CHECK(esp_wifi_set_bandwidth(WIFI_IF_AP, bw));

    // Set maximum TX power
    // esp_wifi_set_max_tx_power takes 0.25 dBm units; 80 = 20 dBm (upper spec).
    ESP_ERROR_CHECK(esp_wifi_set_max_tx_power(80));

    // Wait for AP start event
    EventBits_t bits = xEventGroupWaitBits(s_wifi_event_group,
                                           WIFI_READY_BIT,
                                           pdFALSE, pdFALSE,
                                           pdMS_TO_TICKS(5000));
}

bool wifi_is_ready() {
    return s_ap_active;
}

int wifi_get_station_count() {
    return s_station_count;
}

const char* wifi_get_ip_str() {
    return s_ip_str;
}
