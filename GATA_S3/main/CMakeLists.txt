idf_component_register(
    SRCS "main.cpp"
    INCLUDE_DIRS "."
    REQUIRES s3_core nvs_flash esp_wifi esp_netif lwip driver
)
