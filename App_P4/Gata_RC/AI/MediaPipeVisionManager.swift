//
//  MediaPipeVisionManager.swift
//  VehicleControl
//
//  GATA TRACKING SYSTEM v3.0
//  =========================
//
//  MAJOR FIXES (v3.0):
//  - FIXED: Steering direction now correct (was inverted)
//  - FIXED: Target re-acquisition with single-person fallback
//  - FIXED: Much larger search zone (0.30→0.85 of screen)
//  - FIXED: Extended state timings (LOP: 2s, PREDICT: 4s, SEARCH: 6s)
//  - FIXED: Position-based matching is now primary (color was unreliable)
//  - FIXED: More permissive detection validation
//
//  Features:
//  - HSV Color Histogram for clothing re-identification (secondary)
//  - Unscented Kalman Filter for non-linear prediction
//  - ByteTrack-style matching with multiple fallback strategies
//  - Single Person Fallback - if only 1 person visible, use them
//  - 6-state machine with LOP (Last Observed Position)
//  - Aggressive re-acquisition in LOST state
//
//  Copyright © 2024. All rights reserved.
//

import MediaPipeTasksVision
import CoreVideo
import CoreGraphics
import Accelerate
import simd
import UIKit

// MARK: - === CONFIGURATION ===

public enum TrackingConfig {
    // === Speed Control ===
    public static let maxForwardSpeed: Float = 0.11
    public static let maxBackwardSpeed: Float = 0.11
    public static let maxSteer: Float = 1.0

    // === Target Distance ===
    public static let targetBoxHeight: Float = 0.65
    public static let closeRangeThreshold: Float = 0.75
    public static let farRangeThreshold: Float = 0.45

    // === Deadzone ===
    public static let steerDeadzone: Float = 0.020            // Reduced for more responsive steering
    public static let distanceDeadzone: Float = 0.020

    // === State Machine Timings (EXTENDED for robust tracking) ===
    public static let lockingFramesRequired: Int = 2           // Faster lock (was 3)
    public static let lopDurationFrames: Int = 60              // 2 sec in LOP (was 1 sec)
    public static let predictingDurationFrames: Int = 120      // 4 sec predicting (was 2 sec)
    public static let searchingDurationFrames: Int = 180       // 6 sec searching (was 3 sec)

    // === Detection Validation (RELAXED for better detection) ===
    public static let minDetectionConfidence: Float = 0.22     // Lower for better detection (was 0.30)
    public static let minPoseConsistency: Float = 0.32         // Lower for robustness (was 0.40)
    public static let minLandmarkVisibility: Float = 0.25      // Lower threshold (was 0.3)

    // === Re-Identification Thresholds (RELAXED for easier re-lock) ===
    public static let colorHistogramWeight: Float = 0.25       // Reduced - color can be unreliable (was 0.45)
    public static let bodyProportionWeight: Float = 0.30       // Body shape (was 0.35)
    public static let positionWeight: Float = 0.45             // Position is most reliable (was 0.20)
    public static let relockThreshold: Float = 0.35            // Much easier re-lock (was 0.60)
    public static let relockHighConfidence: Float = 0.50       // Easier instant re-lock (was 0.75)

    // === ByteTrack-style Matching (MORE PERMISSIVE) ===
    public static let highConfidenceThreshold: Float = 0.40    // Lower for more matches (was 0.5)
    public static let lowConfidenceThreshold: Float = 0.18     // Much lower (was 0.25)
    public static let iouMatchThreshold: Float = 0.15          // Lower IOU threshold (was 0.25)

    // === Spatial Search (MUCH LARGER search area) ===
    public static let initialSearchRadius: Float = 0.30        // Larger initial search (was 0.12)
    public static let maxSearchRadius: Float = 0.85            // Nearly full screen (was 0.40)
    public static let searchExpansionRate: Float = 0.015       // Faster expansion (was 0.005)

    // === Trajectory History ===
    public static let trajectoryHistorySize: Int = 45          // More history (was 30)
    public static let minHistoryForPrediction: Int = 3         // Predict earlier (was 5)

    // === Safety ===
    public static let maxPredictedDistance: Float = 0.4        // Allow further prediction (was 0.3)
    public static let stopWhenLost: Bool = true                // CRITICAL: Stop if truly lost

    // === NEW: Single Person Fallback ===
    public static let singlePersonFallbackEnabled: Bool = true // If only 1 person visible, use them
    public static let singlePersonMinConfidence: Float = 0.30  // Min confidence for single-person fallback
}

// MARK: - === TRACKING STATE MACHINE ===

public enum TrackingState: String {
    case idle = "IDLE"              // Not following, just detecting
    case locking = "LOCKING"        // Building confidence on target
    case tracking = "TRACKING"      // Actively following detected target
    case lop = "LOP"                // Going to Last Observed Position
    case predicting = "PREDICTING"  // Using Kalman prediction (no detection)
    case searching = "SEARCHING"    // Actively searching for lost target
    case lost = "LOST"              // Target completely lost, stopped
}

// MARK: - === HSV COLOR HISTOGRAM ===

/// Color histogram for clothing-based re-identification
/// Uses HSV space which is more robust to lighting changes
public struct ColorHistogram: Equatable {
    // Histogram bins: 12 hue × 5 saturation × 3 value = 180 bins
    private static let hueBins: Int = 12
    private static let satBins: Int = 5
    private static let valBins: Int = 3
    
    var histogram: [Float]  // Normalized histogram
    var dominantHue: Float = 0
    var dominantSaturation: Float = 0
    var avgBrightness: Float = 0
    var isValid: Bool = false
    var sampleCount: Int = 0
    
    init() {
        histogram = [Float](repeating: 0, count: Self.hueBins * Self.satBins * Self.valBins)
    }
    
    /// Compute histogram from a region of a pixel buffer
    mutating func compute(from pixelBuffer: CVPixelBuffer, region: CGRect) {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        
        // Convert normalized region to pixel coordinates
        // Shrink region to focus on torso (avoid background)
        let shrinkFactor: CGFloat = 0.7
        let centerX = region.midX
        let centerY = region.midY + region.height * 0.1  // Shift down slightly for torso
        let shrunkWidth = region.width * shrinkFactor
        let shrunkHeight = region.height * shrinkFactor * 0.5  // Only upper body
        
        let minX = max(0, Int((centerX - shrunkWidth/2) * CGFloat(width)))
        let maxX = min(width - 1, Int((centerX + shrunkWidth/2) * CGFloat(width)))
        let minY = max(0, Int((centerY - shrunkHeight/2) * CGFloat(height)))
        let maxY = min(height - 1, Int((centerY + shrunkHeight/2) * CGFloat(height)))
        
        guard maxX > minX && maxY > minY else { return }
        
        // Reset histogram
        var newHist = [Float](repeating: 0, count: histogram.count)
        var totalHue: Float = 0
        var totalSat: Float = 0
        var totalVal: Float = 0
        var validPixels: Int = 0
        
        let pixelData = baseAddress.assumingMemoryBound(to: UInt8.self)
        
        // Sample pixels with stride for performance
        let stride = max(1, (maxX - minX) * (maxY - minY) / 500)  // ~500 samples max
        var sampleIdx = 0
        
        for y in minY..<maxY {
            for x in minX..<maxX {
                sampleIdx += 1
                if sampleIdx % stride != 0 { continue }
                
                let offset = y * bytesPerRow + x * 4
                let b = Float(pixelData[offset]) / 255.0
                let g = Float(pixelData[offset + 1]) / 255.0
                let r = Float(pixelData[offset + 2]) / 255.0
                
                // Convert RGB to HSV
                let (h, s, v) = rgbToHSV(r: r, g: g, b: b)
                
                // Skip very dark or very bright pixels (likely background)
                guard v > 0.1 && v < 0.95 && s > 0.1 else { continue }
                
                // Compute bin indices
                let hBin = min(Self.hueBins - 1, Int(h * Float(Self.hueBins)))
                let sBin = min(Self.satBins - 1, Int(s * Float(Self.satBins)))
                let vBin = min(Self.valBins - 1, Int(v * Float(Self.valBins)))
                let binIdx = hBin * Self.satBins * Self.valBins + sBin * Self.valBins + vBin
                
                newHist[binIdx] += 1
                totalHue += h
                totalSat += s
                totalVal += v
                validPixels += 1
            }
        }
        
        guard validPixels > 50 else { return }  // Need enough samples
        
        // Normalize histogram
        let sum = newHist.reduce(0, +)
        if sum > 0 {
            for i in 0..<newHist.count {
                newHist[i] /= sum
            }
        }
        
        // Update with exponential moving average
        let alpha: Float = sampleCount == 0 ? 1.0 : 0.2
        for i in 0..<histogram.count {
            histogram[i] = histogram[i] * (1 - alpha) + newHist[i] * alpha
        }
        
        dominantHue = totalHue / Float(validPixels)
        dominantSaturation = totalSat / Float(validPixels)
        avgBrightness = totalVal / Float(validPixels)
        sampleCount += 1
        isValid = sampleCount >= 3
    }
    
    /// Compare two histograms using Bhattacharyya distance
    func similarity(to other: ColorHistogram) -> Float {
        guard isValid && other.isValid else { return 0 }
        
        // Bhattacharyya coefficient
        var bc: Float = 0
        for i in 0..<histogram.count {
            bc += sqrt(histogram[i] * other.histogram[i])
        }
        
        // Also check dominant color similarity
        let hueDiff = min(abs(dominantHue - other.dominantHue),
                         1.0 - abs(dominantHue - other.dominantHue))  // Hue is circular
        let satDiff = abs(dominantSaturation - other.dominantSaturation)
        
        let dominantSim = max(0, 1.0 - hueDiff * 3.0 - satDiff * 2.0)
        
        // Combine: 70% histogram, 30% dominant color
        return bc * 0.7 + dominantSim * 0.3
    }
    
    private func rgbToHSV(r: Float, g: Float, b: Float) -> (h: Float, s: Float, v: Float) {
        let maxC = max(r, max(g, b))
        let minC = min(r, min(g, b))
        let delta = maxC - minC
        
        var h: Float = 0
        let s: Float = maxC > 0 ? delta / maxC : 0
        let v: Float = maxC
        
        if delta > 0 {
            if maxC == r {
                h = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
            } else if maxC == g {
                h = (b - r) / delta + 2
            } else {
                h = (r - g) / delta + 4
            }
            h /= 6
            if h < 0 { h += 1 }
        }
        
        return (h, s, v)
    }
}

// MARK: - === TARGET SIGNATURE (Enhanced with Color) ===

public struct TargetSignature: Equatable {
    // Body proportions
    var shoulderWidth: Float = 0
    var torsoHeight: Float = 0
    var bodyAspectRatio: Float = 0
    var shoulderToHipRatio: Float = 0
    var headToShoulderRatio: Float = 0
    var armLength: Float = 0
    
    // Color signature
    var colorHistogram: ColorHistogram = ColorHistogram()
    
    // Bounding box characteristics
    var typicalBoxHeight: Float = 0.4
    var typicalBoxWidth: Float = 0.2
    var typicalBoxAspect: Float = 2.0
    var preferredScreenX: Float = 0.5
    
    // Movement characteristics
    var avgVelocity: SIMD2<Float> = .zero
    var movementVariance: Float = 0
    
    // Quality metrics
    var avgLandmarkConfidence: Float = 0
    var totalFramesSeen: Int = 0
    var createdAt: UInt64 = 0
    var lastSeenAt: UInt64 = 0
    
    /// Compute similarity score between two signatures
    /// IMPROVED: More balanced weighting with position/size as primary
    func similarity(to other: TargetSignature) -> Float {
        var score: Float = 0
        var weights: Float = 0

        // === BOUNDING BOX SIZE (Primary - most reliable for same-session tracking) ===
        let boxSizeDiff = abs(typicalBoxHeight - other.typicalBoxHeight) / max(typicalBoxHeight, 0.1)
        let boxScore = max(0.2, 1.0 - boxSizeDiff * 1.5)  // More lenient, minimum 0.2
        score += boxScore * TrackingConfig.positionWeight
        weights += TrackingConfig.positionWeight

        // === BOX WIDTH SIMILARITY ===
        let boxWidthDiff = abs(typicalBoxWidth - other.typicalBoxWidth) / max(typicalBoxWidth, 0.05)
        let widthScore = max(0.2, 1.0 - boxWidthDiff * 1.5)
        score += widthScore * 0.15
        weights += 0.15

        // === COLOR HISTOGRAM (Secondary - can be affected by lighting) ===
        let colorSim = colorHistogram.similarity(to: other.colorHistogram)
        // Only use color if both histograms are valid
        if colorHistogram.isValid && other.colorHistogram.isValid {
            score += colorSim * TrackingConfig.colorHistogramWeight
            weights += TrackingConfig.colorHistogramWeight
        } else {
            // No valid color - give partial score based on size match
            score += boxScore * 0.15
            weights += 0.15
        }

        // === BODY PROPORTIONS (Tertiary - requires multiple frames to stabilize) ===
        if totalFramesSeen >= 3 && other.totalFramesSeen >= 3 {  // Reduced from 5
            // Aspect ratio
            let aspectDiff = abs(bodyAspectRatio - other.bodyAspectRatio) / max(bodyAspectRatio, 0.5)
            let aspectScore = max(0.2, 1.0 - aspectDiff * 1.5)  // More lenient
            score += aspectScore * 0.10
            weights += 0.10

            // Shoulder width (normalized)
            if shoulderWidth > 0.01 && other.shoulderWidth > 0.01 {
                let shoulderDiff = abs(shoulderWidth - other.shoulderWidth) / max(shoulderWidth, 0.01)
                let shoulderScore = max(0.2, 1.0 - shoulderDiff * 2.0)  // More lenient
                score += shoulderScore * 0.05
                weights += 0.05
            }

            // Torso height (normalized)
            if torsoHeight > 0.01 && other.torsoHeight > 0.01 {
                let torsoDiff = abs(torsoHeight - other.torsoHeight) / max(torsoHeight, 0.01)
                let torsoScore = max(0.2, 1.0 - torsoDiff * 2.0)  // More lenient
                score += torsoScore * 0.05
                weights += 0.05
            }
        }

        // Ensure we always return a reasonable score if weights are valid
        let result = weights > 0 ? score / weights : 0.3  // Default to 0.3 if no valid comparisons
        return max(0.1, result)  // Minimum 10% similarity
    }
    
    /// Update signature from new detection
    mutating func update(from landmarks: [NormalizedLandmark], boundingBox: CGRect, pixelBuffer: CVPixelBuffer? = nil) {
        guard landmarks.count >= 25 else { return }
        
        let now = mach_absolute_time()
        if createdAt == 0 { createdAt = now }
        lastSeenAt = now
        totalFramesSeen += 1
        
        let alpha: Float = totalFramesSeen == 1 ? 1.0 : 0.12
        let beta = 1.0 - alpha
        
        // === Extract body proportions ===
        let nose = landmarks[0]
        let leftShoulder = landmarks[11]
        let rightShoulder = landmarks[12]
        let leftHip = landmarks[23]
        let rightHip = landmarks[24]
        let leftElbow = landmarks[13]
        let rightElbow = landmarks[14]
        
        // Shoulder width
        let newShoulderWidth = sqrt(
            pow(leftShoulder.x - rightShoulder.x, 2) +
            pow(leftShoulder.y - rightShoulder.y, 2)
        )
        
        // Torso height
        let shoulderCenterY = (leftShoulder.y + rightShoulder.y) / 2
        let hipCenterY = (leftHip.y + rightHip.y) / 2
        let newTorsoHeight = abs(hipCenterY - shoulderCenterY)
        
        // Hip width
        let hipWidth = sqrt(
            pow(leftHip.x - rightHip.x, 2) +
            pow(leftHip.y - rightHip.y, 2)
        )
        
        // Shoulder to hip ratio
        let newShoulderToHip = hipWidth > 0.01 ? newShoulderWidth / hipWidth : 1.0
        
        // Head to shoulder ratio
        let shoulderCenterX = (leftShoulder.x + rightShoulder.x) / 2
        let headToShoulder = sqrt(
            pow(nose.x - shoulderCenterX, 2) +
            pow(nose.y - shoulderCenterY, 2)
        )
        let newHeadToShoulderRatio = newShoulderWidth > 0.01 ? headToShoulder / newShoulderWidth : 0
        
        // Arm length (average of both)
        let leftArmLen = sqrt(
            pow(leftShoulder.x - leftElbow.x, 2) +
            pow(leftShoulder.y - leftElbow.y, 2)
        )
        let rightArmLen = sqrt(
            pow(rightShoulder.x - rightElbow.x, 2) +
            pow(rightShoulder.y - rightElbow.y, 2)
        )
        let newArmLength = (leftArmLen + rightArmLen) / 2
        
        // Body aspect ratio
        let newAspect = Float(boundingBox.height / max(boundingBox.width, 0.01))
        
        // Average landmark confidence
        var totalConf: Float = 0
        var confCount: Float = 0
        for idx in [0, 11, 12, 13, 14, 23, 24, 25, 26, 27, 28] {
            if idx < landmarks.count, let vis = landmarks[idx].visibility?.floatValue {
                totalConf += vis
                confCount += 1
            }
        }
        let newConfidence = confCount > 0 ? totalConf / confCount : 0.5
        
        // === Update with smoothing ===
        shoulderWidth = shoulderWidth * beta + newShoulderWidth * alpha
        torsoHeight = torsoHeight * beta + newTorsoHeight * alpha
        shoulderToHipRatio = shoulderToHipRatio * beta + newShoulderToHip * alpha
        headToShoulderRatio = headToShoulderRatio * beta + newHeadToShoulderRatio * alpha
        armLength = armLength * beta + newArmLength * alpha
        bodyAspectRatio = bodyAspectRatio * beta + newAspect * alpha
        avgLandmarkConfidence = avgLandmarkConfidence * beta + newConfidence * alpha
        
        typicalBoxHeight = typicalBoxHeight * beta + Float(boundingBox.height) * alpha
        typicalBoxWidth = typicalBoxWidth * beta + Float(boundingBox.width) * alpha
        typicalBoxAspect = typicalBoxAspect * beta + newAspect * alpha
        preferredScreenX = preferredScreenX * beta + Float(boundingBox.midX) * alpha
        
        // === Update color histogram ===
        if let pixelBuffer = pixelBuffer {
            colorHistogram.compute(from: pixelBuffer, region: boundingBox)
        }
    }
    
    var isReliable: Bool {
        totalFramesSeen >= 5 && avgLandmarkConfidence > 0.35 && colorHistogram.isValid
    }
}

// MARK: - === TRAJECTORY HISTORY ===

public struct TrajectoryHistory {
    var positions: [SIMD2<Float>] = []
    var velocities: [SIMD2<Float>] = []
    var timestamps: [UInt64] = []
    var sizes: [Float] = []
    
    let maxSize: Int = TrackingConfig.trajectoryHistorySize
    
    mutating func add(position: SIMD2<Float>, velocity: SIMD2<Float>, size: Float) {
        positions.append(position)
        velocities.append(velocity)
        timestamps.append(mach_absolute_time())
        sizes.append(size)
        
        // Trim old entries
        while positions.count > maxSize {
            positions.removeFirst()
            velocities.removeFirst()
            timestamps.removeFirst()
            sizes.removeFirst()
        }
    }
    
    /// Predict future position based on trajectory history
    func predictPosition(framesAhead: Int) -> SIMD2<Float>? {
        guard positions.count >= TrackingConfig.minHistoryForPrediction else { return nil }
        
        // Use weighted average of recent velocities
        var weightedVelocity: SIMD2<Float> = .zero
        var totalWeight: Float = 0
        
        let recentCount = min(10, velocities.count)
        for i in 0..<recentCount {
            let idx = velocities.count - 1 - i
            let weight = Float(recentCount - i) / Float(recentCount)  // More recent = higher weight
            weightedVelocity += velocities[idx] * weight
            totalWeight += weight
        }
        
        if totalWeight > 0 {
            weightedVelocity /= totalWeight
        }
        
        // Also consider acceleration (change in velocity)
        var acceleration: SIMD2<Float> = .zero
        if velocities.count >= 3 {
            let recentVel = velocities[velocities.count - 1]
            let olderVel = velocities[velocities.count - 3]
            acceleration = (recentVel - olderVel) / 2.0
        }
        
        // Current position
        guard let lastPos = positions.last else { return nil }
        
        // Predict with velocity and slight acceleration
        let dt = Float(framesAhead) / 30.0  // Assume 30 fps
        let predicted = lastPos + weightedVelocity * dt + acceleration * dt * dt * 0.5
        
        // Clamp to reasonable range
        return SIMD2(
            max(0, min(1, predicted.x)),
            max(0, min(1, predicted.y))
        )
    }
    
    /// Predict future size based on size history
    func predictSize(framesAhead: Int) -> Float? {
        guard sizes.count >= 3 else { return sizes.last }
        
        // Simple linear extrapolation of size trend
        let recentSizes = Array(sizes.suffix(5))
        let avgSize = recentSizes.reduce(0, +) / Float(recentSizes.count)
        
        // Size change rate
        let sizeChange = (sizes.last! - sizes[sizes.count - min(5, sizes.count)]) / Float(min(5, sizes.count))
        
        return avgSize + sizeChange * Float(framesAhead) * 0.5  // Damped prediction
    }
    
    /// Get movement direction (angle in radians)
    func movementDirection() -> Float? {
        guard velocities.count >= 3 else { return nil }
        
        var avgVel: SIMD2<Float> = .zero
        for v in velocities.suffix(5) {
            avgVel += v
        }
        avgVel /= Float(min(5, velocities.count))
        
        return atan2(avgVel.y, avgVel.x)
    }
    
    mutating func clear() {
        positions.removeAll()
        velocities.removeAll()
        timestamps.removeAll()
        sizes.removeAll()
    }
}

// MARK: - === UNSCENTED KALMAN FILTER ===

/// Unscented Kalman Filter for non-linear motion prediction
/// Better than standard Kalman for sudden direction changes
public final class UnscentedKalmanFilter2D {
    // State: [x, y, vx, vy]
    private var state: SIMD4<Float>
    private var covariance: simd_float4x4
    
    // UKF parameters
    private let alpha: Float = 0.001
    private let beta: Float = 2.0
    private let kappa: Float = 0.0
    private let n: Int = 4  // State dimension
    
    // Computed parameters
    private var lambda: Float
    private var gamma: Float
    private var wm: [Float]  // Weights for mean
    private var wc: [Float]  // Weights for covariance
    
    // Noise parameters (adaptive)
    private var processNoise: Float = 0.003
    private var measurementNoise: Float = 0.04
    
    // Innovation tracking for adaptive noise
    private var innovationHistory: [Float] = []
    private let maxInnovationHistory: Int = 15
    
    // Velocity damping
    private let velocityDamping: Float = 0.97
    
    init() {
        state = SIMD4<Float>(0.5, 0.5, 0, 0)
        covariance = simd_float4x4(
            SIMD4<Float>(0.1, 0, 0, 0),
            SIMD4<Float>(0, 0.1, 0, 0),
            SIMD4<Float>(0, 0, 0.05, 0),
            SIMD4<Float>(0, 0, 0, 0.05)
        )
        
        // Compute UKF weights
        lambda = Float(alpha * alpha * (Float(n) + kappa) - Float(n))
        gamma = sqrt(Float(n) + lambda)
        
        let numSigmaPoints = 2 * n + 1
        wm = [Float](repeating: 0, count: numSigmaPoints)
        wc = [Float](repeating: 0, count: numSigmaPoints)
        
        wm[0] = lambda / (Float(n) + lambda)
        wc[0] = wm[0] + (1 - alpha * alpha + beta)
        
        for i in 1..<numSigmaPoints {
            wm[i] = 1.0 / (2.0 * (Float(n) + lambda))
            wc[i] = wm[i]
        }
    }
    
    func reset(to position: SIMD2<Float>) {
        state = SIMD4<Float>(position.x, position.y, 0, 0)
        covariance = simd_float4x4(
            SIMD4<Float>(0.05, 0, 0, 0),
            SIMD4<Float>(0, 0.05, 0, 0),
            SIMD4<Float>(0, 0, 0.02, 0),
            SIMD4<Float>(0, 0, 0, 0.02)
        )
        innovationHistory.removeAll()
    }
    
    /// Generate sigma points for UKF
    private func generateSigmaPoints() -> [SIMD4<Float>] {
        var sigmaPoints = [SIMD4<Float>]()
        sigmaPoints.reserveCapacity(2 * n + 1)
        
        // First sigma point is the mean
        sigmaPoints.append(state)
        
        // Compute square root of covariance using diagonal approximation
        let sqrtP = SIMD4<Float>(
            sqrt(max(0.0001, covariance[0][0])),
            sqrt(max(0.0001, covariance[1][1])),
            sqrt(max(0.0001, covariance[2][2])),
            sqrt(max(0.0001, covariance[3][3]))
        )
        
        // Generate remaining sigma points
        for i in 0..<n {
            var delta = SIMD4<Float>(0, 0, 0, 0)
            delta[i] = gamma * sqrtP[i]
            
            sigmaPoints.append(state + delta)
            sigmaPoints.append(state - delta)
        }
        
        return sigmaPoints
    }
    
    /// Predict step with non-linear motion model
    func predict(dt: Float) {
        let sigmaPoints = generateSigmaPoints()
        
        // Transform sigma points through motion model
        var transformedPoints = [SIMD4<Float>]()
        for sp in sigmaPoints {
            // Non-linear motion model with velocity damping
            let newX = sp.x + sp.z * dt
            let newY = sp.y + sp.w * dt
            let newVx = sp.z * velocityDamping
            let newVy = sp.w * velocityDamping
            
            // Clamp to valid range
            transformedPoints.append(SIMD4<Float>(
                max(0, min(1, newX)),
                max(0, min(1, newY)),
                max(-0.5, min(0.5, newVx)),
                max(-0.5, min(0.5, newVy))
            ))
        }
        
        // Compute predicted mean
        var predictedMean = SIMD4<Float>(0, 0, 0, 0)
        for i in 0..<transformedPoints.count {
            predictedMean += wm[i] * transformedPoints[i]
        }
        
        // Compute predicted covariance
        var predictedCov = simd_float4x4(
            SIMD4<Float>(0, 0, 0, 0),
            SIMD4<Float>(0, 0, 0, 0),
            SIMD4<Float>(0, 0, 0, 0),
            SIMD4<Float>(0, 0, 0, 0)
        )
        for i in 0..<transformedPoints.count {
            let diff = transformedPoints[i] - predictedMean
            for row in 0..<4 {
                for col in 0..<4 {
                    predictedCov[row][col] += wc[i] * diff[row] * diff[col]
                }
            }
        }
        
        // Add process noise (adaptive)
        let pn = processNoise
        let pn2 = processNoise * 2
        let Q = simd_float4x4(
            SIMD4<Float>(pn, 0, 0, 0),
            SIMD4<Float>(0, pn, 0, 0),
            SIMD4<Float>(0, 0, pn2, 0),
            SIMD4<Float>(0, 0, 0, pn2)
        )
        predictedCov += Q
        
        state = predictedMean
        covariance = predictedCov
    }
    
    /// Update step with measurement
    func update(measurement: SIMD2<Float>) {
        // Compute innovation
        let innovation = measurement - positionSIMD
        let innovationMagnitude = simd_length(innovation)
        
        // Track innovation for adaptive noise tuning
        innovationHistory.append(innovationMagnitude)
        while innovationHistory.count > maxInnovationHistory {
            innovationHistory.removeFirst()
        }
        
        // Adapt process noise based on innovation variance
        if innovationHistory.count >= 5 {
            let mean = innovationHistory.reduce(0, +) / Float(innovationHistory.count)
            var variance: Float = 0
            for inn in innovationHistory {
                variance += (inn - mean) * (inn - mean)
            }
            variance /= Float(innovationHistory.count)
            
            // Higher variance = more process noise (target is maneuvering)
            processNoise = max(0.001, min(0.02, variance * 0.3))
        }
        
        // Measurement matrix H (we observe x, y)
        // Kalman gain (simplified for position-only measurement)
        let S = simd_float2x2(columns: (
            SIMD2<Float>(covariance[0][0] + measurementNoise, covariance[0][1]),
            SIMD2<Float>(covariance[1][0], covariance[1][1] + measurementNoise)
        ))
        
        // Invert S
        let det = S[0][0] * S[1][1] - S[0][1] * S[1][0]
        guard abs(det) > 0.0001 else { return }
        
        let Sinv = simd_float2x2(columns: (
            SIMD2<Float>(S[1][1] / det, -S[0][1] / det),
            SIMD2<Float>(-S[1][0] / det, S[0][0] / det)
        ))
        
        // Compute Kalman gains for each state variable
        let K0 = SIMD2<Float>(covariance[0][0], covariance[0][1]) * Sinv
        let K1 = SIMD2<Float>(covariance[1][0], covariance[1][1]) * Sinv
        let K2 = SIMD2<Float>(covariance[2][0], covariance[2][1]) * Sinv
        let K3 = SIMD2<Float>(covariance[3][0], covariance[3][1]) * Sinv
        
        // Update state
        state.x += K0.x * innovation.x + K0.y * innovation.y
        state.y += K1.x * innovation.x + K1.y * innovation.y
        state.z += K2.x * innovation.x + K2.y * innovation.y
        state.w += K3.x * innovation.x + K3.y * innovation.y
        
        // Update covariance (Joseph form for numerical stability)
        // simd_float2x4 = 2 columns x 4 rows (each column is simd_float4)
        let col0 = simd_float4(K0.x, K1.x, K2.x, K3.x)
        let col1 = simd_float4(K0.y, K1.y, K2.y, K3.y)
        let Kfull = simd_float2x4(col0, col1)
        
        // P = (I - KH)P
        for col in 0..<4 {
            let pCol = SIMD4<Float>(covariance[0][col], covariance[1][col], covariance[2][col], covariance[3][col])
            let hpCol = SIMD2<Float>(pCol.x, pCol.y)  // H * P column
            let khpCol = SIMD4<Float>(
                Kfull[0][0] * hpCol.x + Kfull[1][0] * hpCol.y,
                Kfull[0][1] * hpCol.x + Kfull[1][1] * hpCol.y,
                Kfull[0][2] * hpCol.x + Kfull[1][2] * hpCol.y,
                Kfull[0][3] * hpCol.x + Kfull[1][3] * hpCol.y
            )
            covariance[0][col] -= khpCol.x
            covariance[1][col] -= khpCol.y
            covariance[2][col] -= khpCol.z
            covariance[3][col] -= khpCol.w
        }
    }
    
    var positionSIMD: SIMD2<Float> {
        SIMD2<Float>(state.x, state.y)
    }
    
    var velocitySIMD: SIMD2<Float> {
        SIMD2<Float>(state.z, state.w)
    }
    
    var position: (x: Float, y: Float) {
        (state.x, state.y)
    }
    
    var velocity: (vx: Float, vy: Float) {
        (state.z, state.w)
    }
    
    var positionUncertainty: Float {
        sqrt(covariance[0][0] + covariance[1][1])
    }
}

// MARK: - === SIZE KALMAN FILTER ===

public final class SizeKalmanFilter {
    private var size: Float = 0.4
    private var sizeVelocity: Float = 0
    private var variance: Float = 0.01
    
    private let processNoise: Float = 0.001
    private let measurementNoise: Float = 0.02
    
    func reset(to initialSize: Float) {
        size = initialSize
        sizeVelocity = 0
        variance = 0.01
    }
    
    func predict(dt: Float) {
        size += sizeVelocity * dt
        sizeVelocity *= 0.95  // Damping
        variance += processNoise
    }
    
    func update(measurement: Float) {
        let innovation = measurement - size
        let S = variance + measurementNoise
        let K = variance / S
        
        // Update size velocity estimate
        sizeVelocity = sizeVelocity * 0.8 + innovation * 0.2
        
        size += K * innovation
        variance = (1 - K) * variance
    }
    
    var currentSize: Float { size }
    var sizeChangeRate: Float { sizeVelocity }
}

// MARK: - === TRACKED TARGET ===

public final class TrackedTarget {
    let id: Int
    var signature: TargetSignature
    var boundingBox: CGRect
    var confidence: Float = 0.5
    
    // State tracking
    var framesTracked: Int = 0
    var framesLost: Int = 0
    var consecutiveMatches: Int = 0
    var lastMatchScore: Float = 0
    
    // Filters
    var positionFilter: UnscentedKalmanFilter2D
    var sizeFilter: SizeKalmanFilter
    
    // History
    var trajectory: TrajectoryHistory
    
    // Last known state
    var lastDetectedPosition: SIMD2<Float>
    var lastDetectedSize: Float
    var lastDetectedTimestamp: UInt64
    
    // Search zone
    var searchCenter: SIMD2<Float>
    var searchRadius: Float = TrackingConfig.initialSearchRadius
    
    init(id: Int, boundingBox: CGRect, landmarks: [NormalizedLandmark], pixelBuffer: CVPixelBuffer?) {
        self.id = id
        self.boundingBox = boundingBox
        self.lastDetectedPosition = SIMD2(Float(boundingBox.midX), Float(boundingBox.midY))
        self.lastDetectedSize = Float(boundingBox.height)
        self.lastDetectedTimestamp = mach_absolute_time()
        self.searchCenter = lastDetectedPosition
        
        self.signature = TargetSignature()
        self.signature.update(from: landmarks, boundingBox: boundingBox, pixelBuffer: pixelBuffer)
        
        self.positionFilter = UnscentedKalmanFilter2D()
        self.positionFilter.reset(to: lastDetectedPosition)
        
        self.sizeFilter = SizeKalmanFilter()
        self.sizeFilter.reset(to: lastDetectedSize)
        
        self.trajectory = TrajectoryHistory()
        self.trajectory.add(position: lastDetectedPosition, velocity: .zero, size: lastDetectedSize)
    }
    
    /// Update with new detection (target found)
    func updateWithDetection(boundingBox: CGRect, landmarks: [NormalizedLandmark], pixelBuffer: CVPixelBuffer?, dt: Float) {
        self.boundingBox = boundingBox
        framesTracked += 1
        framesLost = 0
        consecutiveMatches += 1
        
        let newPos = SIMD2(Float(boundingBox.midX), Float(boundingBox.midY))
        let newSize = Float(boundingBox.height)
        
        // Update filters
        positionFilter.predict(dt: dt)
        positionFilter.update(measurement: newPos)
        
        sizeFilter.predict(dt: dt)
        sizeFilter.update(measurement: newSize)
        
        // Compute velocity from filter
        let velocity = positionFilter.velocitySIMD
        
        // Update trajectory
        trajectory.add(position: newPos, velocity: velocity, size: newSize)
        
        // Update signature
        signature.update(from: landmarks, boundingBox: boundingBox, pixelBuffer: pixelBuffer)
        
        // Store last detected state
        lastDetectedPosition = newPos
        lastDetectedSize = newSize
        lastDetectedTimestamp = mach_absolute_time()
        
        // Reset search zone
        searchCenter = newPos
        searchRadius = TrackingConfig.initialSearchRadius
        
        // Increase confidence
        confidence = min(1.0, confidence + 0.08)
    }
    
    /// Predict without detection (target not found this frame)
    func predictWithoutDetection(dt: Float) {
        framesLost += 1
        consecutiveMatches = 0
        
        // Predict position
        positionFilter.predict(dt: dt)
        sizeFilter.predict(dt: dt)
        
        // Expand search zone
        searchCenter = positionFilter.positionSIMD
        searchRadius = min(
            TrackingConfig.maxSearchRadius,
            searchRadius + TrackingConfig.searchExpansionRate
        )
        
        // Decay confidence
        let decayRate: Float = framesLost < 30 ? 0.025 : 0.04
        confidence = max(0.1, confidence - decayRate)
    }
    
    /// Check if a position is within the search zone
    func isInSearchZone(_ position: SIMD2<Float>) -> Bool {
        let distance = simd_length(position - searchCenter)
        return distance <= searchRadius
    }
    
    /// Get predicted position for display
    var predictedPosition: SIMD2<Float> {
        positionFilter.positionSIMD
    }
    
    /// Get predicted size for display
    var predictedSize: Float {
        sizeFilter.currentSize
    }
    
    /// Check if this target is still valid (not too old)
    var isValid: Bool {
        framesLost < TrackingConfig.searchingDurationFrames && confidence > 0.15
    }
}

// MARK: - === DETECTION VALIDATOR ===

/// Validates detections to prevent phantom/false positives
/// IMPROVED: More permissive validation for better detection rates
struct DetectionValidator {

    /// Validate a detection for anatomical consistency
    /// Returns (isValid, score) where score is 0-1
    static func validate(landmarks: [NormalizedLandmark], boundingBox: CGRect) -> (valid: Bool, score: Float) {
        guard landmarks.count >= 25 else { return (false, 0) }

        var score: Float = 0
        var checks: Float = 0

        // === Check 1: Key landmarks visibility (RELAXED) ===
        let keyIndices = [0, 11, 12, 23, 24]  // Nose, shoulders, hips
        var visibleCount = 0
        var totalVisibility: Float = 0

        for idx in keyIndices {
            if let vis = landmarks[idx].visibility?.floatValue, vis > TrackingConfig.minLandmarkVisibility {
                visibleCount += 1
                totalVisibility += vis
            }
        }

        let visibilityScore = Float(visibleCount) / Float(keyIndices.count)
        // RELAXED: Accept with just 40% key landmarks visible (was 60%)
        if visibilityScore < 0.40 { return (false, visibilityScore * 0.5) }
        score += visibilityScore
        checks += 1

        // === Check 2: Shoulders roughly horizontal (OPTIONAL) ===
        let leftShoulder = landmarks[11]
        let rightShoulder = landmarks[12]
        let shoulderAngle = abs(leftShoulder.y - rightShoulder.y)
        let shoulderWidth = abs(leftShoulder.x - rightShoulder.x)

        if shoulderWidth > 0.02 {
            let angleRatio = shoulderAngle / shoulderWidth
            // RELAXED: More tolerant of tilted poses
            let horizontalScore = max(0.3, 1.0 - angleRatio * 2.0)  // Minimum 0.3 (was 0)
            score += horizontalScore
            checks += 1
        } else {
            // Can't see shoulders clearly - give benefit of doubt
            score += 0.6
            checks += 1
        }

        // === Check 3: Hips below shoulders (RELAXED) ===
        let shoulderY = (leftShoulder.y + rightShoulder.y) / 2
        let hipY = (landmarks[23].y + landmarks[24].y) / 2
        if hipY > shoulderY {
            score += 1.0
        } else {
            score += 0.5  // More lenient for unusual poses (was 0.3)
        }
        checks += 1

        // === Check 4: Nose position (RELAXED) ===
        let nose = landmarks[0]
        if nose.y < shoulderY {
            score += 1.0
        } else {
            score += 0.6  // More lenient (was 0.4)
        }
        checks += 1

        // === Check 5: Bounding box aspect ratio (VERY RELAXED) ===
        let aspectRatio = Float(boundingBox.height / max(boundingBox.width, 0.01))
        if aspectRatio > 0.8 && aspectRatio < 4.5 {  // Wider range (was 1.0-4.0)
            score += 1.0
        } else if aspectRatio > 0.4 && aspectRatio < 6.0 {  // Extended range (was 0.5-5.0)
            score += 0.7  // Higher partial score (was 0.5)
        } else {
            score += 0.3  // Higher minimum (was 0.1)
        }
        checks += 1

        // === Check 6: Box size (RELAXED) ===
        let boxArea = Float(boundingBox.width * boundingBox.height)
        if boxArea > 0.005 && boxArea < 0.9 {  // Smaller minimum, larger max (was 0.01-0.8)
            score += 1.0
        } else {
            score += 0.5  // Higher minimum (was 0.3)
        }
        checks += 1

        let finalScore = score / checks
        let isValid = finalScore >= TrackingConfig.minPoseConsistency

        return (isValid, finalScore)
    }
    
    /// Compute IOU between two bounding boxes
    static func computeIOU(_ box1: CGRect, _ box2: CGRect) -> Float {
        let intersection = box1.intersection(box2)
        if intersection.isNull || intersection.isEmpty {
            return 0
        }
        
        let intersectionArea = intersection.width * intersection.height
        let unionArea = box1.width * box1.height + box2.width * box2.height - intersectionArea
        
        return Float(intersectionArea / max(unionArea, 0.0001))
    }
}

// MARK: - === PID CONTROLLER ===

public final class SmoothPIDController {
    private let kp: Float
    private let ki: Float
    private let kd: Float
    
    private var integral: Float = 0
    private var lastError: Float = 0
    private var lastOutput: Float = 0
    
    private let integralMax: Float
    private let outputSmoothing: Float
    private let derivativeSmoothing: Float
    private var smoothedDerivative: Float = 0
    
    private let integralDecay: Float = 0.96
    
    init(kp: Float, ki: Float, kd: Float,
         outputSmoothing: Float = 0.3,
         derivativeSmoothing: Float = 0.5,
         integralMax: Float = 0.15) {
        self.kp = kp
        self.ki = ki
        self.kd = kd
        self.outputSmoothing = outputSmoothing
        self.derivativeSmoothing = derivativeSmoothing
        self.integralMax = integralMax
    }
    
    func update(error: Float, dt: Float) -> Float {
        // Proportional
        let p = kp * error
        
        // Integral with decay
        integral = integral * integralDecay + error * dt
        integral = max(-integralMax, min(integralMax, integral))
        let i = ki * integral
        
        // Derivative with smoothing
        let rawDerivative = dt > 0 ? (error - lastError) / dt : 0
        smoothedDerivative = smoothedDerivative * derivativeSmoothing + rawDerivative * (1 - derivativeSmoothing)
        let d = kd * smoothedDerivative
        
        lastError = error
        
        // Compute output
        let rawOutput = p + i + d
        
        // Smooth output
        let output = lastOutput * outputSmoothing + rawOutput * (1 - outputSmoothing)
        lastOutput = output
        
        return output
    }
    
    func reset() {
        integral = 0
        lastError = 0
        lastOutput = 0
        smoothedDerivative = 0
    }
}

// MARK: - === OUTPUT SMOOTHER ===

public struct OutputSmoother {
    private var value: Float = 0
    private var velocity: Float = 0
    private let responsiveness: Float
    private let damping: Float
    
    init(responsiveness: Float = 0.2, damping: Float = 0.8) {
        self.responsiveness = responsiveness
        self.damping = damping
    }
    
    mutating func smooth(_ target: Float) -> Float {
        let diff = target - value
        velocity = velocity * damping + diff * responsiveness
        value += velocity
        return value
    }
    
    mutating func reset(to newValue: Float = 0) {
        value = newValue
        velocity = 0
    }
}

// MARK: - === RATE LIMITER ===

public struct RateLimiter {
    private let maxRate: Float
    private var lastValue: Float = 0
    
    init(maxRate: Float) {
        self.maxRate = maxRate
    }
    
    mutating func limit(_ newValue: Float, dt: Float) -> Float {
        let maxChange = maxRate * dt
        let change = newValue - lastValue
        let limitedChange = max(-maxChange, min(maxChange, change))
        lastValue += limitedChange
        return lastValue
    }
    
    mutating func reset(to value: Float = 0) {
        lastValue = value
    }
}

// MARK: - === MEDIAPIPE VISION MANAGER ===

public final class MediaPipeVisionManager {
    
    private weak var model: AppModel?
    
    // Queues
    private let mlQueue = DispatchQueue(label: "ai.tracking.ml", qos: .userInteractive)
    private let controlQueue = DispatchQueue(label: "ai.tracking.control", qos: .userInteractive)
    
    // MediaPipe
    private var poseLandmarker: PoseLandmarker?
    
    // === STATE MACHINE ===
    private var trackingState: TrackingState = .idle
    private var stateFrameCount: Int = 0
    
    // === TARGET TRACKING ===
    private var currentTarget: TrackedTarget?
    private var savedSignature: TargetSignature?
    private var lastObservedPosition: SIMD2<Float>?
    
    // === FRAME BUFFER ===
    private let frameBuffer = TripleBuffer<(CVPixelBuffer, CGSize)>()
    private var processingFrame: Bool = false
    private let processingLock = NSLock()
    private var lastPixelBuffer: CVPixelBuffer?
    
    // === PID CONTROLLERS ===
    private var distancePID: SmoothPIDController
    private var steerPID: SmoothPIDController
    
    // === OUTPUT SMOOTHING ===
    private var steerSmoother = OutputSmoother(responsiveness: 0.18)
    private var forwardSmoother = OutputSmoother(responsiveness: 0.22)
    private var backwardSmoother = OutputSmoother(responsiveness: 0.25)
    
    // === RATE LIMITERS ===
    private var steerLimiter = RateLimiter(maxRate: 3.0)
    private var speedLimiter = RateLimiter(maxRate: 1.2)
    
    // === FRAME TRACKING ===
    private var frameCounter: Int = 0
    private var lastProcessTime: UInt64 = 0
    private var consecutiveSlowFrames: Int = 0
    private var detectionIdCounter: Int = 0
    
    // === RAMP CONTROL ===
    private var targetRampFrames: Int = 0
    private var lastFollowActive: Bool = false
    private var hadTargetLastFrame: Bool = false
    
    // MARK: - Initialization
    
    public init(model: AppModel) {
        self.model = model
        
        self.distancePID = SmoothPIDController(
            kp: 0.50,
            ki: 0.010,
            kd: 0.30,
            outputSmoothing: 0.30,
            derivativeSmoothing: 0.45,
            integralMax: 0.12
        )
        
        self.steerPID = SmoothPIDController(
            kp: 1.2,
            ki: 0.005,
            kd: 0.40,
            outputSmoothing: 0.35,
            derivativeSmoothing: 0.50,
            integralMax: 0.10
        )
        
        setupMediaPipe()
    }
    
    private func setupMediaPipe() {
        mlQueue.async { [weak self] in
            guard let self = self else { return }
            
            // Try full model first, fallback to lite
            let modelPath: String
            if let fullPath = Bundle.main.path(forResource: "pose_landmarker_full", ofType: "task") {
                modelPath = fullPath
            } else if let litePath = Bundle.main.path(forResource: "pose_landmarker_lite", ofType: "task") {
                modelPath = litePath
            } else {
                return
            }
            
            do {
                let options = PoseLandmarkerOptions()
                options.baseOptions.modelAssetPath = modelPath
                options.runningMode = .video
                options.numPoses = 4                           // More poses for better detection (was 3)
                options.minPoseDetectionConfidence = 0.25      // Lower for better detection (was 0.35)
                options.minPosePresenceConfidence = 0.25       // Lower threshold (was 0.35)
                options.minTrackingConfidence = 0.20           // Much lower for persistent tracking (was 0.35)

                self.poseLandmarker = try PoseLandmarker(options: options)


            } catch {
            }
        }
    }
    
    // MARK: - Public Interface
    
    public func process(pixelBuffer: CVPixelBuffer, imageSize: CGSize) {
        frameCounter += 1
        
        frameBuffer.write((pixelBuffer, imageSize))
        lastPixelBuffer = pixelBuffer
        
        processingLock.lock()
        if processingFrame {
            processingLock.unlock()
            return
        }
        processingFrame = true
        processingLock.unlock()
        
        mlQueue.async { [weak self] in
            self?.processNextFrame()
        }
    }
    
    public func process(image: UIImage?) {
        guard let image = image, let cgImage = image.cgImage else { return }
        
        var pixelBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        CVPixelBufferCreate(nil, cgImage.width, cgImage.height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pixelBuffer)
        
        guard let buffer = pixelBuffer else { return }
        
        CVPixelBufferLockBaseAddress(buffer, [])
        if let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: cgImage.width,
            height: cgImage.height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) {
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        
        process(pixelBuffer: buffer, imageSize: CGSize(width: cgImage.width, height: cgImage.height))
    }
    
    public func stopFollowing() {
        mlQueue.async { [weak self] in
            self?.resetTracking()
        }
    }
    
    /// Public reset method for cleanup
    public func reset() {
        mlQueue.async { [weak self] in
            self?.resetTracking()
        }
    }
    
    private func resetTracking() {
        trackingState = .idle
        stateFrameCount = 0
        currentTarget = nil
        savedSignature = nil
        lastObservedPosition = nil
        
        distancePID.reset()
        steerPID.reset()
        steerSmoother.reset()
        forwardSmoother.reset()
        backwardSmoother.reset()
        steerLimiter.reset()
        speedLimiter.reset()
        targetRampFrames = 0
    }
    
    // MARK: - Frame Processing
    
    private func processNextFrame() {
        defer {
            processingLock.lock()
            processingFrame = false
            processingLock.unlock()
        }
        
        guard let (pixelBuffer, imageSize) = frameBuffer.read(),
              let landmarker = poseLandmarker,
              let model = model else { return }
        
        let startTime = mach_absolute_time()
        
        // Compute dt
        var dt: Float = 1.0 / 30.0
        if lastProcessTime > 0 {
            var timebaseInfo = mach_timebase_info_data_t()
            mach_timebase_info(&timebaseInfo)
            let elapsed = Double(startTime - lastProcessTime) * Double(timebaseInfo.numer) / Double(timebaseInfo.denom)
            dt = Float(elapsed / 1_000_000_000.0)
            dt = max(0.016, min(0.1, dt))
        }
        lastProcessTime = startTime
        
        // === RUN MEDIAPIPE ===
        let mpImage: MPImage
        do {
            mpImage = try MPImage(pixelBuffer: pixelBuffer)
        } catch {
            return
        }
        
        let timestampMs = Int(Date().timeIntervalSince1970 * 1000)
        let result: PoseLandmarkerResult
        do {
            result = try landmarker.detect(videoFrame: mpImage, timestampInMilliseconds: timestampMs)
        } catch {
            return
        }
        
        // === EXTRACT VALID DETECTIONS ===
        // CRITICAL: Only accept REAL detections from MediaPipe
        var validDetections: [(boundingBox: CGRect, landmarks: [NormalizedLandmark], confidence: Float, validationScore: Float)] = []
        
        for poseLandmarks in result.landmarks {
            guard poseLandmarks.count >= 25 else { continue }
            
            // Compute bounding box from landmarks
            var minX: Float = 1, maxX: Float = 0, minY: Float = 1, maxY: Float = 0
            var totalConfidence: Float = 0
            var confCount: Float = 0
            
            for (idx, lm) in poseLandmarks.enumerated() {
                if idx < 25 {  // Main body landmarks
                    let vis = lm.visibility?.floatValue ?? 0.5
                    if vis > 0.2 {
                        minX = min(minX, lm.x)
                        maxX = max(maxX, lm.x)
                        minY = min(minY, lm.y)
                        maxY = max(maxY, lm.y)
                        totalConfidence += vis
                        confCount += 1
                    }
                }
            }
            
            guard maxX > minX && maxY > minY && confCount > 5 else { continue }
            
            // Add padding to box
            let width = maxX - minX
            let height = maxY - minY
            let padX = width * 0.1
            let padY = height * 0.05
            
            let boundingBox = CGRect(
                x: CGFloat(max(0, minX - padX)),
                y: CGFloat(max(0, minY - padY)),
                width: CGFloat(min(1 - minX + padX, width + padX * 2)),
                height: CGFloat(min(1 - minY + padY, height + padY * 2))
            )
            
            let avgConfidence = totalConfidence / confCount
            
            // Validate detection
            let (isValid, validationScore) = DetectionValidator.validate(landmarks: poseLandmarks, boundingBox: boundingBox)
            
            if isValid && avgConfidence >= TrackingConfig.minDetectionConfidence {
                validDetections.append((
                    boundingBox: boundingBox,
                    landmarks: poseLandmarks,
                    confidence: avgConfidence,
                    validationScore: validationScore
                ))
            }
        }
        
        // Sort by confidence * validation score
        validDetections.sort { ($0.confidence * $0.validationScore) > ($1.confidence * $1.validationScore) }
        
        let isFollowing = model.followActive
        let isAutoMode = model.activeDrivingMode == .auto
        
        // === STATE MACHINE UPDATE ===
        let (hasRealDetection, activeTarget) = updateStateMachine(
            detections: validDetections,
            isFollowing: isFollowing,
            pixelBuffer: pixelBuffer,
            dt: dt
        )
        
        // === COMPUTE CONTROL ===
        var steerCmd: Float = 0
        var forwardCmd: Float = 0
        var backwardCmd: Float = 0
        
        // CRITICAL: Only compute control if we have a REAL detection
        // Never drive toward predictions alone
        if isFollowing && hasRealDetection, let target = activeTarget {
            let centerX = Float(target.boundingBox.midX)
            let boxHeight = Float(target.boundingBox.height)

            // Steer toward center - INVERTED: positive error = turn right (target is right of center)
            // centerX > 0.5 means target is to the RIGHT, so we need POSITIVE steer to turn RIGHT
            let steerError = centerX - 0.5  // FIXED: Was inverted (0.5 - centerX)
            if abs(steerError) > TrackingConfig.steerDeadzone {
                let rawSteer = steerPID.update(error: steerError, dt: dt)
                steerCmd = steerSmoother.smooth(rawSteer)
                steerCmd = steerLimiter.limit(steerCmd, dt: dt)
                steerCmd = max(-TrackingConfig.maxSteer, min(TrackingConfig.maxSteer, steerCmd))
            }
            
            // Distance control
            let distanceError = boxHeight - TrackingConfig.targetBoxHeight
            if abs(distanceError) > TrackingConfig.distanceDeadzone {
                let rawSpeed = distancePID.update(error: distanceError, dt: dt)
                
                if rawSpeed > 0 {
                    // Too close, back up
                    backwardCmd = backwardSmoother.smooth(min(rawSpeed, TrackingConfig.maxBackwardSpeed))
                    forwardCmd = forwardSmoother.smooth(0)
                } else {
                    // Too far, move forward
                    forwardCmd = forwardSmoother.smooth(min(-rawSpeed, TrackingConfig.maxForwardSpeed))
                    backwardCmd = backwardSmoother.smooth(0)
                }
            } else {
                forwardCmd = forwardSmoother.smooth(0)
                backwardCmd = backwardSmoother.smooth(0)
            }
            
            forwardCmd = speedLimiter.limit(forwardCmd, dt: dt)
        } else {
            // No real detection - STOP
            forwardCmd = forwardSmoother.smooth(0)
            backwardCmd = backwardSmoother.smooth(0)
            steerCmd = steerSmoother.smooth(0)
        }
        
        // === RAMP CONTROL ===
        if isFollowing && hasRealDetection {
            if !hadTargetLastFrame {
                targetRampFrames = 0
            }
            if targetRampFrames < 15 {
                let rampFactor = Float(targetRampFrames) / 15.0
                let smoothRamp = rampFactor * rampFactor * (3.0 - 2.0 * rampFactor)  // smoothstep
                forwardCmd *= smoothRamp
                backwardCmd *= smoothRamp
                steerCmd *= smoothRamp
                targetRampFrames += 1
            }
        } else {
            targetRampFrames = 0
        }
        hadTargetLastFrame = isFollowing && hasRealDetection
        
        // === BUILD UI DETECTIONS ===
        var uiDetections: [AIDetection] = []
        
        if isAutoMode {
            detectionIdCounter += 1
            
            // Show current tracking status
            if let target = activeTarget {
                let displayBox: CGRect
                let label: String
                
                switch trackingState {
                case .tracking:
                    displayBox = target.boundingBox
                    label = "TRACKING"
                    
                case .locking:
                    displayBox = target.boundingBox
                    label = "LOCKING"
                    
                case .lop, .predicting:
                    // Show prediction box (dashed in overlay)
                    let predPos = target.predictedPosition
                    let predSize = target.predictedSize
                    let aspect = target.signature.typicalBoxAspect
                    let w = predSize / max(aspect, 1)
                    displayBox = CGRect(
                        x: CGFloat(predPos.x - w/2),
                        y: CGFloat(predPos.y - predSize/2),
                        width: CGFloat(w),
                        height: CGFloat(predSize)
                    )
                    label = trackingState == .lop ? "LOP" : "PREDICT"
                    
                case .searching:
                    // Show search zone
                    let searchPos = target.searchCenter
                    let searchRad = target.searchRadius
                    displayBox = CGRect(
                        x: CGFloat(searchPos.x - searchRad),
                        y: CGFloat(searchPos.y - searchRad),
                        width: CGFloat(searchRad * 2),
                        height: CGFloat(searchRad * 2)
                    )
                    label = "SEARCHING"
                    
                case .idle:
                    displayBox = target.boundingBox
                    label = "DETECTED"
                    
                case .lost:
                    displayBox = .zero
                    label = "LOST"
                }
                
                if displayBox != .zero {
                    uiDetections.append(AIDetection(
                        id: detectionIdCounter,
                        boundingBox: displayBox,
                        label: label,
                        confidence: target.confidence,
                        imageSize: imageSize
                    ))
                }
            } else if trackingState == .lost && savedSignature != nil {
                // Show "LOST" indicator at last known position
                if let lastPos = lastObservedPosition {
                    let lostBox = CGRect(
                        x: CGFloat(lastPos.x - 0.05),
                        y: CGFloat(lastPos.y - 0.1),
                        width: 0.1,
                        height: 0.2
                    )
                    uiDetections.append(AIDetection(
                        id: detectionIdCounter,
                        boundingBox: lostBox,
                        label: "LOST",
                        confidence: 0.1,
                        imageSize: imageSize
                    ))
                }
            }
            
            // Also show other detected people (not being tracked)
            if trackingState == .idle {
                for (idx, det) in validDetections.prefix(3).enumerated() {
                    detectionIdCounter += 1
                    uiDetections.append(AIDetection(
                        id: detectionIdCounter,
                        boundingBox: det.boundingBox,
                        label: "PERSON \(idx + 1)",
                        confidence: det.confidence,
                        imageSize: imageSize
                    ))
                }
            }
        }
        
        // === OUTPUT ===
        let finalDets = uiDetections
        let finalHasTarget = hasRealDetection
        let finalForward = max(0, min(1, forwardCmd))
        let finalBackward = max(0, min(1, backwardCmd))
        let finalSteer = max(-1, min(1, steerCmd))
        let finalFollowing = isFollowing
        let finalState = trackingState
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let model = self.model else { return }
            
            model.detections = finalDets
            model.trackingState = finalState.rawValue
            
            if finalFollowing {
                model.autoHasTarget = finalHasTarget
                model.autoForward = finalHasTarget ? finalForward : 0
                model.autoBackward = finalHasTarget ? finalBackward : 0
                model.autoSteer = finalHasTarget ? finalSteer : 0
            } else {
                model.autoHasTarget = false
                model.autoForward = 0
                model.autoBackward = 0
                model.autoSteer = 0
            }
        }
    }
    
    // MARK: - State Machine
    
    private func updateStateMachine(
        detections: [(boundingBox: CGRect, landmarks: [NormalizedLandmark], confidence: Float, validationScore: Float)],
        isFollowing: Bool,
        pixelBuffer: CVPixelBuffer,
        dt: Float
    ) -> (hasRealDetection: Bool, activeTarget: TrackedTarget?) {
        
        stateFrameCount += 1
        
        // Not following - just detect, don't track
        if !isFollowing {
            if trackingState != .idle {
                resetTracking()
            }
            
            // Show first detection if any
            if let first = detections.first {
                let tempTarget = TrackedTarget(
                    id: 0,
                    boundingBox: first.boundingBox,
                    landmarks: first.landmarks,
                    pixelBuffer: pixelBuffer
                )
                return (true, tempTarget)
            }
            return (false, nil)
        }
        
        // === FOLLOWING IS ACTIVE ===
        
        switch trackingState {
            
        case .idle:
            // Start tracking the best detection
            if let best = detections.first {
                currentTarget = TrackedTarget(
                    id: frameCounter,
                    boundingBox: best.boundingBox,
                    landmarks: best.landmarks,
                    pixelBuffer: pixelBuffer
                )
                trackingState = .locking
                stateFrameCount = 0
                return (true, currentTarget)
            }
            return (false, nil)
            
        case .locking:
            // Try to match detection with current target
            if let target = currentTarget {
                let matchedDetection = findBestMatch(for: target, in: detections, pixelBuffer: pixelBuffer)
                
                if let match = matchedDetection {
                    target.updateWithDetection(
                        boundingBox: match.boundingBox,
                        landmarks: match.landmarks,
                        pixelBuffer: pixelBuffer,
                        dt: dt
                    )
                    
                    // Check if we have enough consecutive frames
                    if target.consecutiveMatches >= TrackingConfig.lockingFramesRequired {
                        trackingState = .tracking
                        stateFrameCount = 0
                    }
                    
                    return (true, target)
                } else {
                    // Lost during locking - go back to idle
                    trackingState = .idle
                    stateFrameCount = 0
                    currentTarget = nil
                    return (false, nil)
                }
            }
            return (false, nil)
            
        case .tracking:
            guard let target = currentTarget else {
                trackingState = .idle
                return (false, nil)
            }
            
            // ByteTrack-style matching: try high and low confidence detections
            let matchedDetection = findBestMatch(for: target, in: detections, pixelBuffer: pixelBuffer)
            
            if let match = matchedDetection {
                target.updateWithDetection(
                    boundingBox: match.boundingBox,
                    landmarks: match.landmarks,
                    pixelBuffer: pixelBuffer,
                    dt: dt
                )
                return (true, target)
            } else {
                // No detection this frame - save signature and go to LOP
                savedSignature = target.signature
                lastObservedPosition = target.lastDetectedPosition
                target.predictWithoutDetection(dt: dt)
                
                trackingState = .lop
                stateFrameCount = 0
                
                // Return false - no REAL detection, don't drive
                return (false, target)
            }
            
        case .lop:
            // Last Observed Position - continue toward last known position
            guard let target = currentTarget else {
                trackingState = .idle
                return (false, nil)
            }
            
            // Try to reacquire
            let matchedDetection = findMatchBySignature(in: detections, pixelBuffer: pixelBuffer)
            
            if let match = matchedDetection {
                target.updateWithDetection(
                    boundingBox: match.boundingBox,
                    landmarks: match.landmarks,
                    pixelBuffer: pixelBuffer,
                    dt: dt
                )
                trackingState = .tracking
                stateFrameCount = 0
                return (true, target)
            }
            
            target.predictWithoutDetection(dt: dt)
            
            // Check timeout
            if stateFrameCount >= TrackingConfig.lopDurationFrames {
                trackingState = .predicting
                stateFrameCount = 0
            }
            
            // No real detection - don't drive aggressively
            return (false, target)
            
        case .predicting:
            // Using Kalman prediction - search for reacquisition
            guard let target = currentTarget else {
                trackingState = .idle
                return (false, nil)
            }
            
            let matchedDetection = findMatchBySignature(in: detections, pixelBuffer: pixelBuffer)
            
            if let match = matchedDetection {
                target.updateWithDetection(
                    boundingBox: match.boundingBox,
                    landmarks: match.landmarks,
                    pixelBuffer: pixelBuffer,
                    dt: dt
                )
                trackingState = .tracking
                stateFrameCount = 0
                return (true, target)
            }
            
            target.predictWithoutDetection(dt: dt)
            
            if stateFrameCount >= TrackingConfig.predictingDurationFrames {
                trackingState = .searching
                stateFrameCount = 0
            }
            
            return (false, target)
            
        case .searching:
            // Actively searching with expanded zone
            guard let target = currentTarget else {
                trackingState = .lost
                return (false, nil)
            }
            
            let matchedDetection = findMatchBySignature(in: detections, pixelBuffer: pixelBuffer)
            
            if let match = matchedDetection {
                target.updateWithDetection(
                    boundingBox: match.boundingBox,
                    landmarks: match.landmarks,
                    pixelBuffer: pixelBuffer,
                    dt: dt
                )
                trackingState = .tracking
                stateFrameCount = 0
                return (true, target)
            }
            
            target.predictWithoutDetection(dt: dt)
            
            if stateFrameCount >= TrackingConfig.searchingDurationFrames {
                trackingState = .lost
                stateFrameCount = 0
            }
            
            return (false, target)
            
        case .lost:
            // Target completely lost - but keep trying to reacquire!
            // IMPROVED: Much more aggressive re-acquisition

            // Try to match with saved signature (auto-relock)
            let matchedDetection = findMatchBySignature(in: detections, pixelBuffer: pixelBuffer)

            if let match = matchedDetection {
                // Create new target
                currentTarget = TrackedTarget(
                    id: frameCounter,
                    boundingBox: match.boundingBox,
                    landmarks: match.landmarks,
                    pixelBuffer: pixelBuffer
                )
                trackingState = .locking
                stateFrameCount = 0
                return (true, currentTarget)
            }

            // === AGGRESSIVE FALLBACK ===
            // If we have ANY detection and single person mode is enabled, use it
            if TrackingConfig.singlePersonFallbackEnabled && !detections.isEmpty {
                // Use best detection if it's good enough
                if let best = detections.first, best.confidence >= 0.30 {
                    currentTarget = TrackedTarget(
                        id: frameCounter,
                        boundingBox: best.boundingBox,
                        landmarks: best.landmarks,
                        pixelBuffer: pixelBuffer
                    )
                    trackingState = .locking
                    stateFrameCount = 0
                    return (true, currentTarget)
                }
            }

            return (false, nil)
        }
    }
    
    // MARK: - Detection Matching
    
    /// Find best detection match for current target using ByteTrack-style matching
    /// IMPROVED: More permissive matching with multiple fallback strategies
    private func findBestMatch(
        for target: TrackedTarget,
        in detections: [(boundingBox: CGRect, landmarks: [NormalizedLandmark], confidence: Float, validationScore: Float)],
        pixelBuffer: CVPixelBuffer
    ) -> (boundingBox: CGRect, landmarks: [NormalizedLandmark])? {

        guard !detections.isEmpty else { return nil }

        var bestMatch: (det: (boundingBox: CGRect, landmarks: [NormalizedLandmark]), score: Float)? = nil

        // === SINGLE DETECTION FAST PATH ===
        // If only one person is visible, very likely it's our target
        if detections.count == 1 && TrackingConfig.singlePersonFallbackEnabled {
            let det = detections[0]
            if det.confidence >= 0.25 {
                // Quick sanity check - is it reasonably close to expected position?
                let detPos = SIMD2(Float(det.boundingBox.midX), Float(det.boundingBox.midY))
                let distance = simd_length(detPos - target.predictedPosition)
                if distance < 0.5 {  // Within half screen
                    target.lastMatchScore = 0.8
                    return (det.boundingBox, det.landmarks)
                }
            }
        }

        // === FIRST PASS: High confidence with full scoring ===
        for det in detections where det.confidence >= TrackingConfig.highConfidenceThreshold {
            let score = computeMatchScore(target: target, detection: det, pixelBuffer: pixelBuffer)

            if score > (bestMatch?.score ?? 0.25) {  // Lower threshold (was 0.3)
                bestMatch = ((det.boundingBox, det.landmarks), score)
            }
        }

        // === SECOND PASS: Lower confidence with IOU + position ===
        if bestMatch == nil {
            for det in detections where det.confidence >= TrackingConfig.lowConfidenceThreshold {

                // Use predicted position for IOU
                let predictedBox = CGRect(
                    x: CGFloat(target.predictedPosition.x - target.signature.typicalBoxWidth / 2),
                    y: CGFloat(target.predictedPosition.y - target.predictedSize / 2),
                    width: CGFloat(target.signature.typicalBoxWidth),
                    height: CGFloat(target.predictedSize)
                )

                let iou = DetectionValidator.computeIOU(det.boundingBox, predictedBox)

                // Also check distance to predicted position
                let detPos = SIMD2(Float(det.boundingBox.midX), Float(det.boundingBox.midY))
                let distance = simd_length(detPos - target.predictedPosition)
                let distanceScore = max(0, 1.0 - distance * 2.0)  // Closer = higher score

                // Combined score with distance weighting
                let combinedScore = iou * 0.4 + distanceScore * 0.35 + det.validationScore * 0.25

                if combinedScore >= TrackingConfig.iouMatchThreshold || iou >= TrackingConfig.iouMatchThreshold {
                    if combinedScore > (bestMatch?.score ?? 0.15) {  // Lower threshold (was 0.25)
                        bestMatch = ((det.boundingBox, det.landmarks), combinedScore)
                    }
                }
            }
        }

        // === THIRD PASS: Nearest detection fallback ===
        // If still no match but we have detections, use the nearest one to predicted position
        if bestMatch == nil && !detections.isEmpty {
            var nearestDet: (det: (boundingBox: CGRect, landmarks: [NormalizedLandmark]), distance: Float)? = nil

            for det in detections where det.confidence >= 0.20 {
                let detPos = SIMD2(Float(det.boundingBox.midX), Float(det.boundingBox.midY))
                let distance = simd_length(detPos - target.predictedPosition)

                // Only accept if reasonably close
                if distance < 0.35 {  // Within 35% of screen
                    if nearestDet == nil || distance < nearestDet!.distance {
                        nearestDet = ((det.boundingBox, det.landmarks), distance)
                    }
                }
            }

            if let nearest = nearestDet {
                bestMatch = (nearest.det, 0.3)  // Minimum viable score
            }
        }

        if let match = bestMatch {
            target.lastMatchScore = match.score
            return match.det
        }

        return nil
    }
    
    /// Find match using saved signature (for reacquisition)
    /// IMPROVED: Much more permissive matching + single person fallback
    private func findMatchBySignature(
        in detections: [(boundingBox: CGRect, landmarks: [NormalizedLandmark], confidence: Float, validationScore: Float)],
        pixelBuffer: CVPixelBuffer
    ) -> (boundingBox: CGRect, landmarks: [NormalizedLandmark])? {

        guard !detections.isEmpty else { return nil }

        // === SINGLE PERSON FALLBACK ===
        // If only ONE person is visible and we're searching, just use them!
        // This is the most reliable re-acquisition method
        if TrackingConfig.singlePersonFallbackEnabled && detections.count == 1 {
            let det = detections[0]
            if det.confidence >= TrackingConfig.singlePersonMinConfidence {
                return (det.boundingBox, det.landmarks)
            }
        }

        // === POSITION-BASED MATCHING (Primary) ===
        // If detection is in search zone, use it with lower threshold
        if let target = currentTarget {
            for det in detections {
                let detPos = SIMD2(Float(det.boundingBox.midX), Float(det.boundingBox.midY))
                if target.isInSearchZone(detPos) {
                    // Detection is in expected area - much lower threshold needed
                    let sizeSimilarity = 1.0 - abs(Float(det.boundingBox.height) - target.predictedSize) / max(target.predictedSize, 0.1)
                    if sizeSimilarity > 0.5 && det.confidence > 0.25 {
                        return (det.boundingBox, det.landmarks)
                    }
                }
            }
        }

        // === SIGNATURE-BASED MATCHING (Secondary) ===
        guard let savedSig = savedSignature else {
            // No saved signature but we have detections - use best one
            if let best = detections.first, best.confidence >= TrackingConfig.singlePersonMinConfidence {
                return (best.boundingBox, best.landmarks)
            }
            return nil
        }

        var bestMatch: (det: (boundingBox: CGRect, landmarks: [NormalizedLandmark]), score: Float)? = nil

        for det in detections {
            // Create temporary signature for comparison
            var tempSig = TargetSignature()
            tempSig.update(from: det.landmarks, boundingBox: det.boundingBox, pixelBuffer: pixelBuffer)

            let similarity = savedSig.similarity(to: tempSig)

            // Position bonus - very important for re-acquisition
            var positionBonus: Float = 0
            if let target = currentTarget {
                let detPos = SIMD2(Float(det.boundingBox.midX), Float(det.boundingBox.midY))
                let distance = simd_length(detPos - target.searchCenter)
                // Graduated bonus based on distance from search center
                if distance <= target.searchRadius * 0.5 {
                    positionBonus = 0.25  // Very close to expected position
                } else if distance <= target.searchRadius {
                    positionBonus = 0.15  // In search zone
                } else if distance <= target.searchRadius * 1.5 {
                    positionBonus = 0.08  // Near search zone
                }
            }

            // Size similarity bonus
            var sizeBonus: Float = 0
            if let target = currentTarget {
                let sizeDiff = abs(Float(det.boundingBox.height) - target.predictedSize)
                if sizeDiff < 0.1 {
                    sizeBonus = 0.10
                } else if sizeDiff < 0.2 {
                    sizeBonus = 0.05
                }
            }

            let totalScore = similarity + positionBonus + sizeBonus

            if totalScore >= TrackingConfig.relockThreshold {
                if totalScore > (bestMatch?.score ?? 0) {
                    bestMatch = ((det.boundingBox, det.landmarks), totalScore)
                }
            }
        }

        if let match = bestMatch {
            return match.det
        }

        // === LAST RESORT: If we have any high-confidence detection, use it ===
        // Better to track *someone* than lose all tracking
        if let best = detections.first, best.confidence >= 0.45 && best.validationScore >= 0.5 {
            return (best.boundingBox, best.landmarks)
        }

        return nil
    }
    
    /// Compute match score combining position, size, and appearance
    private func computeMatchScore(
        target: TrackedTarget,
        detection: (boundingBox: CGRect, landmarks: [NormalizedLandmark], confidence: Float, validationScore: Float),
        pixelBuffer: CVPixelBuffer
    ) -> Float {
        
        // Position score (IOU with predicted box)
        let predictedBox = CGRect(
            x: CGFloat(target.predictedPosition.x - target.signature.typicalBoxWidth / 2),
            y: CGFloat(target.predictedPosition.y - target.predictedSize / 2),
            width: CGFloat(target.signature.typicalBoxWidth),
            height: CGFloat(target.predictedSize)
        )
        let iouScore = DetectionValidator.computeIOU(detection.boundingBox, predictedBox)
        
        // Size score
        let detSize = Float(detection.boundingBox.height)
        let expectedSize = target.predictedSize
        let sizeDiff = abs(detSize - expectedSize) / max(expectedSize, 0.1)
        let sizeScore = max(0, 1.0 - sizeDiff * 2.0)
        
        // Appearance score (signature similarity)
        var appearanceScore: Float = 0.5
        if target.signature.isReliable {
            var tempSig = TargetSignature()
            tempSig.update(from: detection.landmarks, boundingBox: detection.boundingBox, pixelBuffer: pixelBuffer)
            appearanceScore = target.signature.similarity(to: tempSig)
        }
        
        // Combine scores
        let totalScore = iouScore * 0.25 + sizeScore * 0.20 + appearanceScore * 0.45 + detection.validationScore * 0.10
        
        return totalScore
    }
}
