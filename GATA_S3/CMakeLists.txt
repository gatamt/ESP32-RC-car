# GATA_S3 - RC Car Controller for Waveshare ESP32-S3-Zero
# Combined video bridge + motor control + telemetry
# Dual-core Xtensa LX7 @ 240MHz

cmake_minimum_required(VERSION 3.16)

# Set target chip BEFORE including ESP-IDF
set(IDF_TARGET "esp32s3")

include($ENV{IDF_PATH}/tools/cmake/project.cmake)
project(GATA_S3)
