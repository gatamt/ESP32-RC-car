//
//  NetHolder.swift
//  VehicleControl
//
//  Central holder for all network and AI managers
//

import Foundation
import Combine

// MARK: - Net Holder

/// Central manager holder for network and AI components
public final class NetHolder: ObservableObject {

    public var net: ControlUDPManager?
    public var vid: UDPVideoClient?
    public var aud: UDPAudioClient?
    public var ctrl: ControllerBridge?
    public var ai: MediaPipeVisionManager?

    private var isInitialized = false

    public init() {}

    /// Initialize all managers if not already done
    public func initIfNeeded(model: AppModel) {
        guard !isInitialized else { return }
        isInitialized = true

        // Initialize control UDP manager first
        if net == nil {
            let mgr = ControlUDPManager(model: model)
            net = mgr
            ctrl = ControllerBridge(net: mgr, model: model)
        }

        // Initialize AI manager (MediaPipe)
        if ai == nil {
            ai = MediaPipeVisionManager(model: model)
        }

        // Initialize video client with AI reference
        if vid == nil {
            vid = UDPVideoClient(model: model, ai: ai)
        }

        // Initialize audio client
        if aud == nil {
            aud = UDPAudioClient(model: model)
        }
    }

    /// Trigger reconnection on all network managers
    public func triggerReconnect() {
        net?.triggerReconnect()
        vid?.triggerReconnect()
    }

    /// Shutdown all managers
    public func shutdown() {
        ai?.reset()
        net = nil
        vid = nil
        aud = nil
        ctrl = nil
        ai = nil
        isInitialized = false
    }
}
