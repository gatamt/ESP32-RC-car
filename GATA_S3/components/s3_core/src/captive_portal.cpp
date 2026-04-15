// captive_portal.cpp - Minimal DNS+HTTP responders for captive portal bypass
#include "captive_portal.hpp"
#include "config.hpp"

#include "esp_http_server.h"
#include "lwip/sockets.h"
#include "lwip/ip4_addr.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include <string.h>

// DNS server task
static int s_dns_sock = -1;
static TaskHandle_t s_dns_task = nullptr;
static uint32_t s_ap_ip = 0;

// Convert WiFiConfig::AP_IP to uint32
static uint32_t ap_ip_u32() {
    ip4_addr_t ip = {};
    ip4addr_aton(WiFiConfig::AP_IP, &ip);
    return ip.addr;
}

// Minimal DNS response: answer A record with AP IP for any query
static void dns_task(void* pv) {
    uint8_t buf[512];
    struct sockaddr_in from = {};
    socklen_t fromlen = sizeof(from);

    while (true) {
        int n = recvfrom(s_dns_sock, buf, sizeof(buf), 0, (struct sockaddr*)&from, &fromlen);
        if (n <= 0) {
            vTaskDelay(pdMS_TO_TICKS(10));
            continue;
        }

        // Minimal header check (12 bytes)
        if (n < 12) continue;

        uint16_t qdcount = (buf[4] << 8) | buf[5];
        if (qdcount == 0) continue;

        // Parse question to find end of QNAME
        int idx = 12;
        while (idx < n && buf[idx] != 0) {
            uint8_t len = buf[idx];
            idx += 1 + len;
        }
        if (idx + 5 >= n) continue;  // need zero byte + type(2) + class(2)

        int qname_end = idx;
        int question_len = (qname_end + 5) - 12;

        // Build response
        uint8_t resp[512];
        int pos = 0;
        // Copy header
        memcpy(resp, buf, 12);
        // Set flags: response, recursion not available, no error
        resp[2] = 0x81;
        resp[3] = 0x80;
        // QDCOUNT unchanged
        resp[4] = buf[4];
        resp[5] = buf[5];
        // ANCOUNT = 1
        resp[6] = 0x00;
        resp[7] = 0x01;
        // NSCOUNT, ARCOUNT = 0
        resp[8] = resp[9] = resp[10] = resp[11] = 0;
        pos = 12;
        // Copy question
        memcpy(resp + pos, buf + 12, question_len);
        pos += question_len;
        // Name pointer to question (offset 12 = 0x0c)
        resp[pos++] = 0xC0;
        resp[pos++] = 0x0C;
        // Type A
        resp[pos++] = 0x00;
        resp[pos++] = 0x01;
        // Class IN
        resp[pos++] = 0x00;
        resp[pos++] = 0x01;
        // TTL 60s
        resp[pos++] = 0x00;
        resp[pos++] = 0x00;
        resp[pos++] = 0x00;
        resp[pos++] = 0x3C;
        // Data length 4
        resp[pos++] = 0x00;
        resp[pos++] = 0x04;
        // Address
        memcpy(resp + pos, &s_ap_ip, 4);
        pos += 4;

        sendto(s_dns_sock, resp, pos, 0, (struct sockaddr*)&from, fromlen);
    }
}

static void start_dns() {
    s_ap_ip = ap_ip_u32();
    s_dns_sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_IP);
    if (s_dns_sock < 0) return;

    struct sockaddr_in addr = {};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(53);
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    if (bind(s_dns_sock, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        close(s_dns_sock);
        s_dns_sock = -1;
        return;
    }

    xTaskCreate(&dns_task, "dns_spoof", 2048, NULL, 3, &s_dns_task);
}

// HTTP server handler: always reply "Success"
static esp_err_t success_handler(httpd_req_t* req) {
    static const char resp_str[] = "Success";
    httpd_resp_set_type(req, "text/plain");
    return httpd_resp_send(req, resp_str, HTTPD_RESP_USE_STRLEN);
}

static void start_http() {
    httpd_config_t config = HTTPD_DEFAULT_CONFIG();
    config.server_port = 80;
    config.lru_purge_enable = true;

    httpd_handle_t server = nullptr;
    if (httpd_start(&server, &config) == ESP_OK) {
        httpd_uri_t any = {};
        any.uri = "/*";
        any.method = HTTP_GET;
        any.handler = success_handler;
        any.user_ctx = NULL;
        httpd_register_uri_handler(server, &any);
    }
}

void captive_portal_start() {
    start_dns();
    start_http();
}
