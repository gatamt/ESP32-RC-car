//
//  AIOverlayView.swift
//  VehicleControl
//
//  ULTIMATE AI OVERLAY
//  Features:
//  - Shows tracking box when autonomous mode is active
//  - Visual feedback for all tracking states
//  - TRACKING: Active lock on target
//  - LOCKING: Acquiring target
//  - PREDICT: Lost but predicting
//  - SEARCHING: Looking for target
//  - DETECTED: Person visible but not following
//  - Search zone visualization
//  - Smooth animations and glow effects
//

import SwiftUI

// MARK: - AI Theme Colors

/// Colors for AI tracking overlay matching app UI theme
public enum AIThemeColors {
    /// Primary tracking color - blue/purple matching UI
    public static let trackingPrimary = Color(red: 0.25, green: 0.35, blue: 0.95)
    /// Secondary glow color
    public static let trackingGlow = Color(red: 0.4, green: 0.5, blue: 1.0)
    /// Detected but not tracking (still blue, but slightly different)
    public static let detected = Color(red: 0.20, green: 0.40, blue: 0.90)
    /// Prediction mode (purple tint)
    public static let prediction = Color(red: 0.45, green: 0.35, blue: 0.85).opacity(0.85)
    /// Locking mode (cyan)
    public static let locking = Color(red: 0.0, green: 0.75, blue: 0.90)
    /// Searching mode (orange)
    public static let searching = Color(red: 0.95, green: 0.55, blue: 0.15).opacity(0.70)
    /// LOP mode - Last Observed Position (yellow/amber)
    public static let lop = Color(red: 0.95, green: 0.75, blue: 0.20)
    /// Lost mode (red/pink)
    public static let lost = Color(red: 0.85, green: 0.25, blue: 0.30).opacity(0.80)
    /// Label background
    public static let labelBackground = Color.black.opacity(0.6)
}

// MARK: - AI Detections Overlay

/// Overlay view for displaying AI detections
/// Shows detection box whenever we're in autonomous mode and a person is detected
public struct AIDetectionsOverlay: View, Equatable {
    @ObservedObject var model: AppModel
    let viewSize: CGSize
    
    public init(model: AppModel, viewSize: CGSize) {
        self.model = model
        self.viewSize = viewSize
    }
    
    // OPTIMIZED: Compare by detection IDs for minimal redraws
    public static func == (lhs: AIDetectionsOverlay, rhs: AIDetectionsOverlay) -> Bool {
        guard lhs.viewSize == rhs.viewSize else { return false }
        guard lhs.model.detections.count == rhs.model.detections.count else { return false }
        guard lhs.model.isAutonomousMode == rhs.model.isAutonomousMode else { return false }
        guard lhs.model.followActive == rhs.model.followActive else { return false }
        
        // Compare detection IDs
        for (l, r) in zip(lhs.model.detections, rhs.model.detections) {
            if l.id != r.id { return false }
        }
        return true
    }
    
    public var body: some View {
        ZStack {
            ForEach(model.detections) { det in
                let rect = det.rectInView(size: viewSize)
                if !rect.isNull && !rect.isEmpty {
                    DetectionBox(
                        detection: det,
                        rect: rect,
                        isTracking: model.followActive && model.autoHasTarget,
                        isAutonomousMode: model.isAutonomousMode
                    )
                }
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Detection Box

/// Individual detection box rendering with AI-style visuals
/// Draws directly on the detected person's bounding box
private struct DetectionBox: View {
    let detection: AIDetection
    let rect: CGRect
    let isTracking: Bool
    let isAutonomousMode: Bool
    
    private var boxColor: Color {
        switch detection.label {
        case "TRACKING":
            return AIThemeColors.trackingPrimary
        case "PREDICT":
            return AIThemeColors.prediction
        case "LOCKING":
            return AIThemeColors.locking
        case "SEARCHING":
            return AIThemeColors.searching
        case "LOP":
            return AIThemeColors.lop
        case "LOST":
            return AIThemeColors.lost
        case "DETECTED":
            return AIThemeColors.detected
        default:
            return AIThemeColors.detected
        }
    }
    
    private var lineWidth: CGFloat {
        switch detection.label {
        case "TRACKING":
            return 3.0
        case "LOCKING":
            return 2.5
        case "SEARCHING", "LOP", "LOST":
            return 2.0
        default:
            return 2.5
        }
    }
    
    private var showGlow: Bool {
        isAutonomousMode
    }
    
    private var isSearchMode: Bool {
        detection.label == "SEARCHING"
    }
    
    private var isPredictionMode: Bool {
        detection.label == "PREDICT" || detection.label == "LOP"
    }
    
    private var isLostMode: Bool {
        detection.label == "LOST"
    }
    
    var body: some View {
        ZStack {
            // Outer glow effect
            if showGlow && !isSearchMode && !isLostMode {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(AIThemeColors.trackingGlow.opacity(isTracking ? 0.5 : 0.3), lineWidth: isTracking ? 5 : 4)
                    .blur(radius: isTracking ? 4 : 3)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            }
            
            // Search zone visualization (dashed circle)
            if isSearchMode {
                Circle()
                    .stroke(boxColor, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                
                // Center crosshair
                Path { path in
                    let size: CGFloat = 15
                    path.move(to: CGPoint(x: rect.midX - size, y: rect.midY))
                    path.addLine(to: CGPoint(x: rect.midX + size, y: rect.midY))
                    path.move(to: CGPoint(x: rect.midX, y: rect.midY - size))
                    path.addLine(to: CGPoint(x: rect.midX, y: rect.midY + size))
                }
                .stroke(boxColor, lineWidth: 2)
            } else if isPredictionMode {
                // Prediction/LOP mode - dashed rectangle
                RoundedRectangle(cornerRadius: 3)
                    .stroke(boxColor, style: StrokeStyle(lineWidth: lineWidth, dash: [10, 5]))
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                
                // Small arrow showing predicted direction
                if detection.label == "LOP" {
                    Path { path in
                        let size: CGFloat = 8
                        path.move(to: CGPoint(x: rect.midX, y: rect.midY - size))
                        path.addLine(to: CGPoint(x: rect.midX, y: rect.midY + size))
                        path.addLine(to: CGPoint(x: rect.midX - size/2, y: rect.midY + size/2))
                        path.move(to: CGPoint(x: rect.midX, y: rect.midY + size))
                        path.addLine(to: CGPoint(x: rect.midX + size/2, y: rect.midY + size/2))
                    }
                    .stroke(boxColor, lineWidth: 2)
                }
            } else if isLostMode {
                // Lost mode - X mark
                RoundedRectangle(cornerRadius: 3)
                    .stroke(boxColor, style: StrokeStyle(lineWidth: lineWidth, dash: [5, 5]))
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                
                // X mark in center
                Path { path in
                    let size: CGFloat = 12
                    path.move(to: CGPoint(x: rect.midX - size, y: rect.midY - size))
                    path.addLine(to: CGPoint(x: rect.midX + size, y: rect.midY + size))
                    path.move(to: CGPoint(x: rect.midX + size, y: rect.midY - size))
                    path.addLine(to: CGPoint(x: rect.midX - size, y: rect.midY + size))
                }
                .stroke(boxColor, lineWidth: 2)
            } else {
                // Main bounding box - SOLID continuous lines
                RoundedRectangle(cornerRadius: 3)
                    .stroke(boxColor, lineWidth: lineWidth)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                
                // Corner accents
                if isAutonomousMode {
                    CornerAccents(rect: rect, color: boxColor, isTracking: isTracking)
                }
            }
            
            // Label with confidence
            VStack(alignment: .leading, spacing: 1) {
                Text(detection.label)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                
                if detection.confidence > 0 && !isSearchMode && !isLostMode {
                    Text(String(format: "%.0f%%", detection.confidence * 100))
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.8))
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(boxColor.opacity(0.8))
            .cornerRadius(4)
            .position(x: isSearchMode ? rect.midX : rect.minX + 35, 
                     y: isSearchMode ? rect.minY - 25 : max(rect.minY - 18, 24))
        }
    }
}

// MARK: - Corner Accents

/// Corner accent lines for enhanced tracking visual
private struct CornerAccents: View {
    let rect: CGRect
    let color: Color
    let isTracking: Bool
    
    private var cornerLength: CGFloat {
        isTracking ? 14 : 12
    }
    
    private var cornerWidth: CGFloat {
        isTracking ? 3.0 : 2.5
    }
    
    var body: some View {
        ZStack {
            // Top-left corner
            Path { path in
                path.move(to: CGPoint(x: rect.minX, y: rect.minY + cornerLength))
                path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.minX + cornerLength, y: rect.minY))
            }
            .stroke(color, style: StrokeStyle(lineWidth: cornerWidth, lineCap: .round, lineJoin: .round))
            
            // Top-right corner
            Path { path in
                path.move(to: CGPoint(x: rect.maxX - cornerLength, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + cornerLength))
            }
            .stroke(color, style: StrokeStyle(lineWidth: cornerWidth, lineCap: .round, lineJoin: .round))
            
            // Bottom-left corner
            Path { path in
                path.move(to: CGPoint(x: rect.minX, y: rect.maxY - cornerLength))
                path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
                path.addLine(to: CGPoint(x: rect.minX + cornerLength, y: rect.maxY))
            }
            .stroke(color, style: StrokeStyle(lineWidth: cornerWidth, lineCap: .round, lineJoin: .round))
            
            // Bottom-right corner
            Path { path in
                path.move(to: CGPoint(x: rect.maxX - cornerLength, y: rect.maxY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - cornerLength))
            }
            .stroke(color, style: StrokeStyle(lineWidth: cornerWidth, lineCap: .round, lineJoin: .round))
        }
    }
}

// MARK: - AI Stats Overlay

/// Optional debug overlay showing AI performance stats
public struct AIStatsOverlay: View {
    @ObservedObject var model: AppModel
    
    public init(model: AppModel) {
        self.model = model
    }
    
    private var trackingState: (text: String, color: Color) {
        if model.autoHasTarget {
            return ("LOCKED", AIThemeColors.trackingPrimary)
        } else if !model.detections.isEmpty {
            let label = model.detections.first?.label ?? "DETECTED"
            switch label {
            case "TRACKING":
                return ("TRACKING", AIThemeColors.trackingPrimary)
            case "LOCKING":
                return ("LOCKING", AIThemeColors.locking)
            case "PREDICT":
                return ("PREDICTING", AIThemeColors.prediction)
            case "LOP":
                return ("LAST POSITION", AIThemeColors.lop)
            case "SEARCHING":
                return ("SEARCHING", AIThemeColors.searching)
            case "LOST":
                return ("LOST", AIThemeColors.lost)
            default:
                return ("DETECTED", AIThemeColors.detected)
            }
        }
        return ("NO TARGET", .gray)
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("AI: \(String(format: "%.1f", model.aiStats.fps)) FPS")
                .cyberFont(10, anchor: .leading)
            Text("Inference: \(String(format: "%.1f", model.aiStats.inferenceTimeMs))ms")
                .cyberFont(10, anchor: .leading)
            Text("Dropped: \(model.aiStats.droppedFrames)")
                .cyberFont(10, anchor: .leading)
            
            let state = trackingState
            Text("Target: \(state.text)")
                .cyberFont(10, anchor: .leading)
                .foregroundColor(state.color)
            
            if model.followActive {
                Text("Mode: FOLLOWING")
                    .cyberFont(10, anchor: .leading)
                    .foregroundColor(AIThemeColors.trackingPrimary)
            } else if model.isAutonomousMode {
                Text("Mode: STANDBY")
                    .cyberFont(10, anchor: .leading)
                    .foregroundColor(AIThemeColors.detected)
            }
        }
        .foregroundColor(.green)
        .padding(6)
        .background(Color.black.opacity(0.6))
        .cornerRadius(6)
    }
}
