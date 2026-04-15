//
//  ControllerBridge.swift
//  VehicleControl
//
//  Game controller bridge with autonomous mode integration
//

import GameController
import Foundation

// MARK: - Controller Bridge

/// Bridges game controller input to vehicle control
public final class ControllerBridge {
    
    // MARK: - Properties
    
    private let net: ControlUDPManager
    private weak var model: AppModel?
    
    private var timer: Timer?
    private var seq: UInt32 = 0
    
    // Button state tracking
    private var lastSquarePressed: Bool = false
    private var lastR1Pressed: Bool = false
    private var lastL1Pressed: Bool = false
    private var lastDpadLeftPressed: Bool = false
    private var lastDpadRightPressed: Bool = false
    private var lastCirclePressed: Bool = false
    
    // Pre-allocated frame buffer
    private var frameBytes: [UInt8] = Array(repeating: 0, count: 18)
    
    // MARK: - Initialization
    
    public init(net: ControlUDPManager, model: AppModel) {
        self.net = net
        self.model = model
        setupNotifications()
        discoverControllers()
        startSendingLoop()
    }
    
    deinit {
        timer?.invalidate()
    }
    
    // MARK: - Controller Discovery
    
    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            forName: .GCControllerDidConnect,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.model?.controllerConnected = GCController.controllers().first != nil
            }
        }
        
        NotificationCenter.default.addObserver(
            forName: .GCControllerDidDisconnect,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.model?.controllerConnected = false
            }
        }
    }
    
    private func discoverControllers() {
        GCController.startWirelessControllerDiscovery { }
        
        DispatchQueue.main.async {
            self.model?.controllerConnected = GCController.controllers().first != nil
        }
    }
    
    // MARK: - Control Loop
    
    private func startSendingLoop() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(
            withTimeInterval: 1.0 / PerformanceConfig.controlUpdateHz,
            repeats: true
        ) { [weak self] _ in
            self?.tick()
        }
    }
    
    private func tick() {
        guard let model = model else { return }
        
        let pad = GCController.controllers().first?.extendedGamepad
        
        // Ignore input while controls are disabled (menus)
        guard model.controlsEnabled else {
            let circlePressed = pad?.buttonB.isPressed ?? false
            DispatchQueue.main.async {
                self.model?.controllerConnected = pad != nil
            }
            // Allow O to exit driving UI (edge detection - only on rising edge)
            if circlePressed && !lastCirclePressed {
                NotificationCenter.default.post(name: .exitDrivingUIRequested, object: nil)
            }
            lastCirclePressed = circlePressed
            return
        }
        
        // Read button states
        let r1Pressed = pad?.rightShoulder.isPressed ?? false
        let l1Pressed = pad?.leftShoulder.isPressed ?? false
        let squarePressed = pad?.buttonX.isPressed ?? false
        let circlePressed = pad?.buttonB.isPressed ?? false
        let dpadLeftPressed = pad?.dpad.left.isPressed ?? false
        let dpadRightPressed = pad?.dpad.right.isPressed ?? false
        
        let isAuto = model.isAutonomousMode
        let hasAutoTarget = model.autoHasTarget
        let followAuto = isAuto && model.followActive && hasAutoTarget
        
        // Mode switching
        handleModeSwitch(
            r1Pressed: r1Pressed,
            l1Pressed: l1Pressed,
            squarePressed: squarePressed,
            isAuto: isAuto
        )
        
        // Exit driving UI on O when controls enabled (edge detection - only on rising edge)
        if circlePressed && !lastCirclePressed {
            NotificationCenter.default.post(name: .exitDrivingUIRequested, object: nil)
        }
        
        // Camera rotation (D-pad left/right)
        handleCameraRotation(
            dpadLeftPressed: dpadLeftPressed,
            dpadRightPressed: dpadRightPressed
        )
        
        // Read control values
        var r2f = pad?.rightTrigger.value ?? 0.0
        var l2f = pad?.leftTrigger.value ?? 0.0
        var lxf = pad?.leftThumbstick.xAxis.value ?? 0.0
        var brakeBtn = pad?.buttonA.isPressed ?? false
        
        // Override with autonomous control
        if followAuto {
            r2f = model.autoForward
            l2f = model.autoBackward
            lxf = model.autoSteer
            brakeBtn = false
        } else if isAuto {
            r2f = 0.0
            l2f = 0.0
            lxf = 0.0
            brakeBtn = false
        }
        
        // Update model
        DispatchQueue.main.async {
            self.model?.r2 = r2f
            self.model?.l2 = l2f
            self.model?.lx = lxf
            self.model?.btnBrake = brakeBtn
            self.model?.controllerConnected = pad != nil
        }
        
        // Build and send frame
        sendControlFrame(r2: r2f, l2: l2f, lx: lxf, brake: brakeBtn)
        
        // Update button state
        lastR1Pressed = r1Pressed
        lastL1Pressed = l1Pressed
        lastSquarePressed = squarePressed
        lastCirclePressed = circlePressed
        lastDpadLeftPressed = dpadLeftPressed
        lastDpadRightPressed = dpadRightPressed
    }
    
    // MARK: - Mode Switching
    
    private func handleModeSwitch(r1Pressed: Bool, l1Pressed: Bool, squarePressed: Bool, isAuto: Bool) {
        guard let model = model else { return }
        
        // R1: Enter autonomous mode
        if r1Pressed && !lastR1Pressed {
            DispatchQueue.main.async {
                model.enterAutonomousMode()
            }
        }
        
        // L1: Exit autonomous mode
        if l1Pressed && !lastL1Pressed {
            DispatchQueue.main.async {
                model.exitAutonomousMode()
            }
        }
        
        // Square: Toggle follow mode (in auto) or fullscreen (in manual)
        if squarePressed && !lastSquarePressed {
            if isAuto {
                DispatchQueue.main.async {
                    model.toggleFollowMode()
                }
            } else {
                DispatchQueue.main.async {
                    model.isFullscreenVideo.toggle()
                }
            }
        }
    }
    
    // MARK: - Camera Rotation
    
    private func handleCameraRotation(dpadLeftPressed: Bool, dpadRightPressed: Bool) {
        guard let model = model else { return }
        
        // D-pad Left: Rotate camera counter-clockwise
        if dpadLeftPressed && !lastDpadLeftPressed {
            DispatchQueue.main.async {
                model.rotateCameraLeft()
            }
        }
        
        // D-pad Right: Rotate camera clockwise
        if dpadRightPressed && !lastDpadRightPressed {
            DispatchQueue.main.async {
                model.rotateCameraRight()
            }
        }
    }
    
    // MARK: - Frame Building
    
    private func sendControlFrame(r2: Float, l2: Float, lx: Float, brake: Bool) {
        // Convert to protocol values
        let r2i = Int16(max(0, min(1023, Int(round(r2 * 1023.0)))))
        let l2i = Int16(max(0, min(1023, Int(round(l2 * 1023.0)))))
        let lxi = Int16(max(-512, min(512, Int(round(lx * 512.0)))))
        
        // Sequence number with high bit set
        let msb: UInt32 = 0x80000000
        let low: UInt32 = seq & 0x7FFFFFFF
        let seqFull = msb | low
        seq &+= 1
        
        // Build frame
        frameBytes[0] = 0x5A  // Magic
        frameBytes[1] = 0xA5
        frameBytes[2] = 0x01  // Version
        
        let r2u = UInt16(bitPattern: r2i)
        frameBytes[3] = UInt8(r2u & 0xFF)
        frameBytes[4] = UInt8((r2u >> 8) & 0xFF)
        
        let l2u = UInt16(bitPattern: l2i)
        frameBytes[5] = UInt8(l2u & 0xFF)
        frameBytes[6] = UInt8((l2u >> 8) & 0xFF)
        
        let lxu = UInt16(bitPattern: lxi)
        frameBytes[7] = UInt8(lxu & 0xFF)
        frameBytes[8] = UInt8((lxu >> 8) & 0xFF)
        
        frameBytes[9] = brake ? 1 : 0
        
        frameBytes[10] = UInt8(seqFull & 0xFF)
        frameBytes[11] = UInt8((seqFull >> 8) & 0xFF)
        frameBytes[12] = UInt8((seqFull >> 16) & 0xFF)
        frameBytes[13] = UInt8((seqFull >> 24) & 0xFF)
        
        // Calculate CRC on header+payload (bytes 0-13)
        let crc = crc16_ccitt(Array(frameBytes[0..<14]))
        frameBytes[14] = UInt8(crc & 0xFF)
        frameBytes[15] = UInt8((crc >> 8) & 0xFF)
        
        // Send
        net.sendControlFrame(Array(frameBytes[0..<16]))
    }
}
