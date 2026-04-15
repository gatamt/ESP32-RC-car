//
//  AppModel.swift
//  VehicleControl
//
//  Central application state model
//

import SwiftUI
import Combine

// MARK: - Main App Model

/// Central observable model for application state
public final class AppModel: ObservableObject {
    
    // MARK: - Camera Rotation (persisted)
    private static let cameraRotationKey = "cameraRotationDegrees"
    
    /// Camera rotation in degrees (0, 90, 180, 270)
    @Published public var cameraRotation: Double {
        didSet {
            UserDefaults.standard.set(cameraRotation, forKey: Self.cameraRotationKey)
        }
    }
    
    // MARK: - Controller State
    @Published public var r2: Float = 0
    @Published public var l2: Float = 0
    @Published public var lx: Float = 0
    @Published public var btnBrake: Bool = false
    @Published public var controllerConnected = false
    
    // MARK: - Vehicle Connection State
    @Published public var tele: Telemetry? = nil
    @Published public var teleAlive = false
    @Published public var bleConnected = false
    @Published public var peripheralName: String = "ZERO-Direct"
    
    // MARK: - Video State
    @Published public var videoImage: UIImage? = nil
    @Published public var isFullscreenVideo: Bool = false
    
    // MARK: - Autonomous Mode State
    @Published public var isAutonomousMode: Bool = false
    @Published public var followActive: Bool = false
    @Published public var autoHasTarget: Bool = false
    @Published public var autoForward: Float = 0.0
    @Published public var autoBackward: Float = 0.0
    @Published public var autoSteer: Float = 0.0
    
    // MARK: - AI Detection State
    @Published public var detections: [AIDetection] = []
    @Published public var aiStats: AIPerformanceStats = AIPerformanceStats()
    @Published public var trackingState: String = "IDLE"
    
    // MARK: - Input Enablement
    @Published public var controlsEnabled: Bool = false
    
    // MARK: - Menu Drafts
    @Published public var carNameDraft: String = ""
    
    // MARK: - Active Car
    @Published public var activeCarName: String? = nil
    
    // MARK: - Connection Flags
    @Published public var carConnectedMenu: Bool = false
    
    // MARK: - Driving Mode
    public enum DrivingMode {
        case manual
        case auto
    }
    
    /// Current driving mode
    public var activeDrivingMode: DrivingMode {
        isAutonomousMode ? .auto : .manual
    }
    
    // MARK: - Audio State
    @Published public var audioActive: Bool = false
    
    // MARK: - Camera Battery State (from XIAO)
    @Published public var camBatteryPercent: Int? = nil  // nil = not received yet
    
    public init() {
        // Load saved camera rotation from UserDefaults
        self.cameraRotation = UserDefaults.standard.double(forKey: Self.cameraRotationKey)
    }
    
    // MARK: - Camera Rotation Methods
    
    /// Rotate camera 90 degrees clockwise
    public func rotateCameraRight() {
        cameraRotation = cameraRotation + 90.0
        if cameraRotation >= 360.0 {
            cameraRotation = 0.0
        }
    }
    
    /// Rotate camera 90 degrees counter-clockwise
    public func rotateCameraLeft() {
        cameraRotation = cameraRotation - 90.0
        if cameraRotation < 0.0 {
            cameraRotation = 270.0
        }
    }
    
    // MARK: - Convenience Methods
    
    public func resetAutonomousState() {
        isAutonomousMode = false
        followActive = false
        autoHasTarget = false
        autoForward = 0
        autoBackward = 0
        autoSteer = 0
        detections = []
        trackingState = "IDLE"
    }
    
    public func enterAutonomousMode() {
        isAutonomousMode = true
        isFullscreenVideo = true
        detections = []
        followActive = false
        autoHasTarget = false
        autoForward = 0
        autoBackward = 0
        autoSteer = 0
    }
    
    public func exitAutonomousMode() {
        isAutonomousMode = false
        isFullscreenVideo = false
        resetAutonomousState()
    }
    
    public func toggleFollowMode() {
        if followActive {
            followActive = false
            autoHasTarget = false
            autoForward = 0
            autoBackward = 0
            autoSteer = 0
        } else {
            followActive = true
            autoHasTarget = false
            autoForward = 0
            autoBackward = 0
            autoSteer = 0
        }
    }
}
