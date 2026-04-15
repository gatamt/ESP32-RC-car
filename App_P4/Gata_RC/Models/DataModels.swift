//
//  DataModels.swift
//  GATA_RC_P4
//
//  Core data models for ESP32-P4 vehicle control and telemetry
//

import Foundation
import CoreGraphics

// MARK: - Control Frame Payload

/// Payload structure for control frames sent to ESP32-P4
public struct Payload {
    public var r2: Int16      // Throttle (0-1023)
    public var l2: Int16      // Reverse (0-1023)
    public var lx: Int16      // Steering (-512 to 512)
    public var brake: UInt8   // Brake button state
    public var seq: UInt32    // Sequence number
    
    public init(r2: Int16 = 0, l2: Int16 = 0, lx: Int16 = 0, brake: UInt8 = 0, seq: UInt32 = 0) {
        self.r2 = r2
        self.l2 = l2
        self.lx = lx
        self.brake = brake
        self.seq = seq
    }
}

// MARK: - Control Frame

/// Complete control frame with magic bytes, version, payload, and CRC
/// Matches P4 protocol.hpp ControlFrame structure
public struct Frame {
    public var magic: UInt16 = 0xA55A  // 0x5A 0xA5 in little endian
    public var ver: UInt8 = 0x01
    public var p: Payload
    public var crc: UInt16 = 0
    
    public init(payload: Payload) {
        self.p = payload
    }
}

// MARK: - Telemetry (P4 Format)

/// Vehicle telemetry data received from ESP32-P4
/// Matches P4 protocol.hpp TelemetryPacket structure
public struct Telemetry: Equatable {
    // Header
    public var magic: UInt32          // "TEL1" = 0x314C4554
    
    // Core data
    public var timestamp: UInt32      // Milliseconds since P4 boot
    public var batteryPercent: UInt8  // Battery 0-100%
    public var cpuTemp: Int8          // CPU temperature in Celsius
    public var motorSpeedLeft: UInt16 // Left motor speed (0-1000)
    public var motorSpeedRight: UInt16 // Right motor speed (0-1000)
    
    // GPS data
    public var latitude: Int32        // Degrees * 1e7
    public var longitude: Int32       // Degrees * 1e7
    public var heading: UInt16        // Degrees * 10
    public var gpsFix: UInt8          // 0=none, 1=2D, 2=3D
    
    // WiFi
    public var wifiRssi: UInt8        // Signal strength (positive dBm offset)

    // Control link stats
    public var controlSeq: UInt32     // Last control sequence observed
    public var controlLost: UInt32    // Estimated lost control packets
    
    // Legacy compatibility
    public var speed_kmh: Float = 0
    
    public init(magic: UInt32 = 0, timestamp: UInt32 = 0, batteryPercent: UInt8 = 0,
                cpuTemp: Int8 = 0, motorSpeedLeft: UInt16 = 0, motorSpeedRight: UInt16 = 0,
                latitude: Int32 = 0, longitude: Int32 = 0, heading: UInt16 = 0,
                gpsFix: UInt8 = 0, wifiRssi: UInt8 = 0, speed_kmh: Float = 0,
                controlSeq: UInt32 = 0, controlLost: UInt32 = 0) {
        self.magic = magic
        self.timestamp = timestamp
        self.batteryPercent = batteryPercent
        self.cpuTemp = cpuTemp
        self.motorSpeedLeft = motorSpeedLeft
        self.motorSpeedRight = motorSpeedRight
        self.latitude = latitude
        self.longitude = longitude
        self.heading = heading
        self.gpsFix = gpsFix
        self.wifiRssi = wifiRssi
        self.speed_kmh = speed_kmh
        self.controlSeq = controlSeq
        self.controlLost = controlLost
    }
    
    // MARK: - Computed Properties
    
    /// Battery percentage
    public var battery: Int { Int(batteryPercent) }
    
    /// CPU temperature in Celsius
    public var cpuTemperature: Int { Int(cpuTemp) }
    
    /// Motor 1 (left) temperature in Celsius (legacy compatibility)
    public var motor1TempC: Float { Float(motorSpeedLeft) / 10.0 }
    
    /// Motor 2 (right) temperature in Celsius (legacy compatibility)
    public var motor2TempC: Float { Float(motorSpeedRight) / 10.0 }
    
    /// GPS coordinates as doubles
    public var latitudeDecimal: Double { Double(latitude) / 1e7 }
    public var longitudeDecimal: Double { Double(longitude) / 1e7 }
    
    /// Heading in degrees
    public var headingDegrees: Double { Double(heading) / 10.0 }
    
    /// Has valid GPS fix
    public var hasGpsFix: Bool { gpsFix >= 2 }
    
    /// WiFi RSSI in dBm (negative value)
    public var wifiRssiDbm: Int { -Int(wifiRssi) }
    
    // Legacy compatibility properties
    public var gpsAlive: UInt8 { gpsFix > 0 ? 1 : 0 }
    public var fixOK: UInt8 { gpsFix >= 2 ? 1 : 0 }
    public var sats: UInt8 { 0 }
    public var m1_c10: UInt16 { motorSpeedLeft }
    public var m2_c10: UInt16 { motorSpeedRight }
    public var ms: UInt32 { timestamp }
}

// MARK: - AI Detection

public struct AIDetection: Identifiable, Equatable {
    public let id: Int
    public let boundingBox: CGRect
    public let label: String
    public let confidence: Float
    public let imageSize: CGSize
    
    @inline(__always)
    public init(id: Int, boundingBox: CGRect, label: String, confidence: Float, imageSize: CGSize) {
        self.id = id
        self.boundingBox = boundingBox
        self.label = label
        self.confidence = confidence
        self.imageSize = imageSize
    }
    
    @inline(__always)
    public static func == (lhs: AIDetection, rhs: AIDetection) -> Bool {
        lhs.id == rhs.id
    }
    
    @inline(__always)
    public func rectInView(size viewSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        
        let iw = imageSize.width, ih = imageSize.height
        let vw = viewSize.width, vh = viewSize.height
        let imageAspect = iw / ih, viewAspect = vw / vh
        
        let scale: CGFloat
        var xOffset: CGFloat = 0, yOffset: CGFloat = 0
        
        if viewAspect > imageAspect {
            scale = vh / ih
            xOffset = (vw - iw * scale) / 2.0
        } else {
            scale = vw / iw
            yOffset = (vh - ih * scale) / 2.0
        }
        
        let xImg = boundingBox.origin.x * iw
        let yImgTop = (1.0 - boundingBox.origin.y - boundingBox.height) * ih
        let wImg = boundingBox.width * iw
        let hImg = boundingBox.height * ih
        
        return CGRect(
            x: xImg * scale + xOffset,
            y: yImgTop * scale + yOffset,
            width: wImg * scale,
            height: hImg * scale
        )
    }
}

// MARK: - AI Performance Stats

public struct AIPerformanceStats {
    public var fps: Double = 0
    public var inferenceTimeMs: Double = 0
    public var pipelineLatencyMs: Double = 0
    public var droppedFrames: Int = 0
    
    public init() {}
}

// MARK: - Video Frame

public struct VideoFrame {
    public let data: Data
    public let width: Int
    public let height: Int
    public let timestamp: UInt64
    public let isKeyframe: Bool
    
    public init(data: Data, width: Int, height: Int, timestamp: UInt64 = mach_absolute_time(), isKeyframe: Bool = false) {
        self.data = data
        self.width = width
        self.height = height
        self.timestamp = timestamp
        self.isKeyframe = isKeyframe
    }
}
