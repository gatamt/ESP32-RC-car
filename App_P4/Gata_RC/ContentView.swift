//
//  ContentView.swift
//  VehicleControl
//
//  Main content view assembling all components
//

import SwiftUI
import Combine

// MARK: - Content View

/// Main application content view
public struct ContentView: View {
    @EnvironmentObject private var sharedState: SharedAppState

    private let CAPTION2_SIZE: CGFloat = 11

    @State private var carBlinkOn = false
    @State private var carBlinkCancellable: AnyCancellable?
    @State private var hudBaseSize: CGSize = .zero
    @State private var showAIStats = false  // Enable for debugging

    public init() {}

    /// Convenience accessor for the shared model
    private var model: AppModel { sharedState.model }

    public var body: some View {
        ZStack {
            // Video layer
            FullscreenVideo(model: model)
                .zIndex(0)

            // HUD layer (only in manual mode)
            if !model.isAutonomousMode {
                HUDView(model: model)
                    .frame(width: hudBaseSize.width, height: hudBaseSize.height, alignment: .topLeading)
                    .ignoresSafeArea()
                    .zIndex(1)
            }

            // Optional AI stats overlay
            if showAIStats && model.isAutonomousMode {
                AIStatsOverlay(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(8)
                    .zIndex(10)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            // Video preview (only when not fullscreen)
            if !model.isFullscreenVideo && !model.isAutonomousMode {
                VideoPreview(model: model)
            }
        }
        .overlay(alignment: .bottom) {
            // Status bar
            if !model.btnBrake && !model.isAutonomousMode {
                StatusBar(
                    model: model,
                    carBlinkOn: carBlinkOn,
                    captionSize: CAPTION2_SIZE
                )
            }
        }
        .animation(nil, value: model.isFullscreenVideo)
        .animation(nil, value: model.isAutonomousMode)
        .background(
            GeometryReader { proxy in
                Color.clear.onAppear {
                    hudBaseSize = proxy.size
                }
            }
        )
        .onAppear {
            // Network is already initialized via shared state - no need to reinitialize
            // Enable controls ONLY in this view
            sharedState.controlsActive = true
            model.controlsEnabled = true
            carBlinkCancellable = Timer.publish(every: 0.5, on: .main, in: .common)
                .autoconnect()
                .sink { _ in carBlinkOn.toggle() }
        }
        .onDisappear {
            // Disable controls when leaving
            sharedState.controlsActive = false
            model.controlsEnabled = false
            carBlinkCancellable?.cancel()
        }
        .onReceive(NotificationCenter.default.publisher(for: .exitDrivingUIRequested)) { _ in
            sharedState.controlsActive = false
            model.controlsEnabled = false
        }
        .statusBar(hidden: true)
    }
}

// MARK: - Status Bar

/// Bottom status bar showing connection status
private struct StatusBar: View {
    @ObservedObject var model: AppModel
    let carBlinkOn: Bool
    let captionSize: CGFloat
    
    var body: some View {
        HStack(spacing: 10) {
            // CAM battery status (shown above car connection)
            if let camBattery = model.camBatteryPercent {
                HStack(spacing: 16) {
                    Text("CAM")
                        .cyberFont(captionSize)
                        .foregroundColor(Color(red: 0.05, green: 0.22, blue: 0.85))
                    
                    // Battery icon
                    BatteryIcon(percent: camBattery, size: captionSize)
                    
                    Text("\(camBattery)%")
                        .cyberFont(captionSize)
                        .foregroundColor(batteryColor(percent: camBattery))
                }
            }
            
            Spacer(minLength: 4)
            
            // Car connection status
            HStack(spacing: 6) {
                Circle()
                    .fill(model.bleConnected ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                    .opacity(model.bleConnected ? 1.0 : (carBlinkOn ? 1.0 : 0.0))
                
                if model.bleConnected {
                    let name = model.activeCarName?.isEmpty == false ? model.activeCarName! : "Car"
                    Text("Connected: \(name)")
                        .cyberFont(captionSize)
                } else {
                    Text("Car waiting…")
                        .cyberFont(captionSize)
                        .opacity(carBlinkOn ? 1.0 : 0.0)
                }
            }
            
            Spacer(minLength: 8)
            
            // Controller status
            HStack(spacing: 6) {
                Circle()
                    .fill(model.controllerConnected ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                
                Text(model.controllerConnected ? "Controller" : "No controller")
                    .cyberFont(captionSize)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(Color.clear)
    }
    
    private func batteryColor(percent: Int) -> Color {
        if percent <= 15 {
            return .red
        } else if percent <= 30 {
            return .orange
        } else {
            return .white
        }
    }
}

// MARK: - Battery Icon

/// Small battery icon that fills based on percentage
private struct BatteryIcon: View {
    let percent: Int
    let size: CGFloat
    
    var body: some View {
        let width = size * 1.6
        let height = size * 0.85
        let tipWidth = size * 0.12
        let cornerRadius = size * 0.1
        let padding = size * 0.08
        let fillWidth = max(0, (width - padding * 2) * CGFloat(percent) / 100.0)
        
        HStack(spacing: 0) {
            ZStack(alignment: .leading) {
                // Battery outline
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(Color.white.opacity(0.8), lineWidth: 1)
                    .frame(width: width, height: height)
                
                // Battery fill
                RoundedRectangle(cornerRadius: cornerRadius * 0.5)
                    .fill(fillColor)
                    .frame(width: fillWidth, height: height - padding * 2)
                    .padding(.leading, padding)
            }
            
            // Battery tip (positive terminal)
            RoundedRectangle(cornerRadius: cornerRadius * 0.3)
                .fill(Color.white.opacity(0.8))
                .frame(width: tipWidth, height: height * 0.4)
        }
    }
    
    private var fillColor: Color {
        if percent <= 15 {
            return .red
        } else if percent <= 30 {
            return .orange
        } else {
            return Color(red: 0.05, green: 0.22, blue: 0.85)  // Blue
        }
    }
}

// MARK: - Preview

#if DEBUG
struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
#endif
