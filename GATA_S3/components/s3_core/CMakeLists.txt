idf_component_register(
    SRCS
        "src/config.cpp"
        "src/wifi_ap.cpp"
        "src/video_bridge.cpp"
        "src/control_receiver.cpp"
        "src/motor_control.cpp"
        "src/telemetry.cpp"
        "src/protocol.cpp"
        "src/time_utils.cpp"
        "src/network_mutex.cpp"
        "src/captive_portal.cpp"
    INCLUDE_DIRS "include"
    REQUIRES driver esp_wifi esp_netif lwip freertos esp_timer esp_event nvs_flash esp_http_server
)
