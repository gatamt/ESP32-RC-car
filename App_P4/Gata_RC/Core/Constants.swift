//
//  Constants.swift
//  GATA_RC_P4
//
//  Global constants and configuration for ESP32-P4 FireBeetle
//

import SwiftUI

// MARK: - P4 Host (SoftAP)
public enum P4Host {
    public static let ip = "192.168.4.1"
}

// MARK: - Font Configuration
public enum CyberFont {
    public static let name = "DINCondensed-Bold"
    public static let scaleX: CGFloat = 1.65
    public static let scaleY: CGFloat = 0.74
}

// MARK: - Network Ports (matches P4 firmware config.hpp)
public enum NetworkPorts {
    public static let control: UInt16 = 3333  // Control commands FROM iPhone
    public static let video: UInt16 = 3334    // Video stream TO iPhone
    public static let audio: UInt16 = 3335    // Audio stream TO iPhone
}

// MARK: - Video Configuration (H.264 from P4)
public enum VideoConfig {
    // P4 receives H.264 from RPi over USB-NCM and forwards to iPhone via WiFi
    // Resolution: 1280x720 @ 30fps (matches RPi libcamera-vid + P4 passthrough)
    public static let width: Int = 1280
    public static let height: Int = 720
    public static let targetFPS: Int = 30

    // H.264 header size
    public static let h264HeaderSize: Int = 28

    // Max frame size for H.264 (allow larger keyframes)
    public static let maxH264FrameSize: Int = 1_000_000  // ~1MB for 720p+
    public static let maxUDPPayload: Int = 1400
}

// MARK: - Performance Tuning
public enum PerformanceConfig {
    public static let controlUpdateHz: Double = 200.0
    public static let uiUpdateHz: Double = 120.0
    public static let videoDecodeQoS: DispatchQoS = .userInteractive
    public static let aiProcessingQoS: DispatchQoS = .userInteractive

    // Frame buffer sizes (for 1280x720 H.264)
    public static let maxFrameBytes = 1_000_000
    public static let tripleBufferCount = 3
    public static let pixelBufferPoolSize = 4
    
    // AI detection thresholds
    public static let minBodyPointConfidence: Float = 0.45
    public static let minBodyPointCount = 4
    public static let maxTargetLostFrames = 25
    public static let slowFrameThresholdMs: Double = 45.0
}

// MARK: - Control Parameters
public enum ControlConfig {
    // Protocol constants (matches P4 firmware protocol.hpp)
    public static let magic0: UInt8 = 0x5A
    public static let magic1: UInt8 = 0xA5
    public static let protocolVersion: UInt8 = 0x01
    public static let frameSize: Int = 16
    
    // Speed limits
    public static let maxForwardSpeed: Float = 0.22
    public static let maxBackwardSpeed: Float = 0.18
    public static let maxSteer: Float = 1.0
    public static let steerDeadzone: Float = 0.035
    public static let distanceDeadzone: Float = 0.025
    public static let targetBoxHeight: Float = 0.32
    public static let targetRampTotalFrames = 12
    
    // Approach control
    public static let minApproachSpeed: Float = 0.05
    public static let approachBrakeDistance: Float = 0.4
}

// MARK: - Audio Configuration (PDM from P4)
public enum AudioConfig {
    public static let sampleRate: Double = 16000
    public static let channels: UInt32 = 1
    public static let bufferDuration: TimeInterval = 0.005
    public static let maxScheduledBuffers = 3
    public static let bufferPoolSize = 8
}

// MARK: - HUD Layout
public enum HUDLayout {
    public static let throttleScale: CGFloat = 2.0
    public static let reverseScale: CGFloat = 2.0
    public static let rpmFontSize: CGFloat = 18
    public static let r2TopOffset: CGFloat = 8 + 14
    public static let revTopOffset: CGFloat = 36 + 72
    public static let joystickBottomOffset: CGFloat = 72
}

// MARK: - Colors
public enum HUDColors {
    public static let blue = Color(red: 0.05, green: 0.22, blue: 0.85)
    public static let red = Color.red
    public static let warning = Color.yellow
    public static let success = Color.green
}
