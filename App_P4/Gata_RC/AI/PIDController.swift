//
//  PIDController.swift
//  VehicleControl
//
//  OPTIMIZED: Adaptive PID controller with Float-based calculations
//

import Foundation

// MARK: - Adaptive PID Controller

/// High-performance adaptive PID controller
/// Uses Float for faster calculations on ARM processors
public final class AdaptivePIDController {
    
    // Base gains
    private let kpBase: Float
    private let kiBase: Float
    private let kdBase: Float
    
    // Current gains (adapted based on target size)
    private var kp: Float
    private var ki: Float
    private var kd: Float
    
    // Internal state
    private var integral: Float = 0
    private var previousError: Float = 0
    private var previousOutput: Float = 0
    
    // Limits
    private let integralMax: Float
    private let integralMin: Float
    private let outputSmoothing: Float
    
    // MARK: - Initialization
    
    /// Initialize PID controller with gains
    /// - Parameters:
    ///   - kp: Proportional gain
    ///   - ki: Integral gain
    ///   - kd: Derivative gain
    ///   - integralMax: Maximum integral value (default 0.3)
    ///   - outputSmoothing: Output smoothing factor (default 0.25)
    public init(kp: Float, ki: Float, kd: Float,
                integralMax: Float = 0.3,
                outputSmoothing: Float = 0.25) {
        self.kpBase = kp
        self.kiBase = ki
        self.kdBase = kd
        self.kp = kp
        self.ki = ki
        self.kd = kd
        self.integralMax = integralMax
        self.integralMin = -integralMax
        self.outputSmoothing = outputSmoothing
    }
    
    // MARK: - Gain Adaptation
    
    /// Adapt gains based on target size (distance indicator)
    /// Larger targets = closer = more aggressive response needed
    /// - Parameter targetSize: Normalized target size (0-1)
    @inline(__always)
    public func adaptGains(targetSize: Float) {
        let distanceFactor = 1.0 - min(1.0, max(0.0, targetSize * 2.0))
        let scale = 0.5 + distanceFactor * 1.0
        
        kp = kpBase * scale
        ki = kiBase * scale * 0.5
        kd = kdBase * (2.0 - scale)
    }
    
    /// Set fixed gain multiplier
    @inline(__always)
    public func setGainMultiplier(_ multiplier: Float) {
        kp = kpBase * multiplier
        ki = kiBase * multiplier
        kd = kdBase * multiplier
    }
    
    // MARK: - Update
    
    /// Update controller with new error value
    /// - Parameters:
    ///   - error: Current error (setpoint - actual)
    ///   - dt: Time step in seconds
    /// - Returns: Control output
    @inline(__always)
    public func update(error: Float, dt: Float) -> Float {
        // Proportional term
        let p = kp * error
        
        // Integral term with anti-windup
        integral += error * dt
        integral = max(integralMin, min(integralMax, integral))
        let i = ki * integral
        
        // Derivative term
        let rawDerivative = (error - previousError) / max(dt, 0.001)
        let d = kd * rawDerivative
        previousError = error
        
        // Combined output with smoothing
        let rawOutput = p + i + d
        let smoothedOutput = previousOutput * outputSmoothing + rawOutput * (1 - outputSmoothing)
        previousOutput = smoothedOutput
        
        return smoothedOutput
    }
    
    /// Update with deadzone
    /// - Parameters:
    ///   - error: Current error
    ///   - dt: Time step
    ///   - deadzone: Error values below this are treated as zero
    /// - Returns: Control output
    @inline(__always)
    public func update(error: Float, dt: Float, deadzone: Float) -> Float {
        let effectiveError = abs(error) < deadzone ? 0 : error
        return update(error: effectiveError, dt: dt)
    }
    
    // MARK: - Reset
    
    /// Reset controller state
    @inline(__always)
    public func reset() {
        integral = 0
        previousError = 0
        previousOutput = 0
        kp = kpBase
        ki = kiBase
        kd = kdBase
    }
    
    /// Soft reset (keep current gains)
    @inline(__always)
    public func softReset() {
        integral = 0
        previousError = 0
        previousOutput = 0
    }
}

// MARK: - Dual PID Controller (for 2D control)

/// Paired PID controllers for X/Y or distance/steer control
public final class DualPIDController {
    public let primary: AdaptivePIDController
    public let secondary: AdaptivePIDController
    
    public init(primaryKp: Float, primaryKi: Float, primaryKd: Float,
                secondaryKp: Float, secondaryKi: Float, secondaryKd: Float) {
        self.primary = AdaptivePIDController(kp: primaryKp, ki: primaryKi, kd: primaryKd)
        self.secondary = AdaptivePIDController(kp: secondaryKp, ki: secondaryKi, kd: secondaryKd)
    }
    
    @inline(__always)
    public func adaptGains(targetSize: Float) {
        primary.adaptGains(targetSize: targetSize)
        secondary.adaptGains(targetSize: targetSize)
    }
    
    @inline(__always)
    public func reset() {
        primary.reset()
        secondary.reset()
    }
}

// MARK: - Rate Limited PID

/// PID controller with output rate limiting
public final class RateLimitedPIDController {
    private let pid: AdaptivePIDController
    private var lastOutput: Float = 0
    private let maxRate: Float // Maximum change per second
    
    public init(kp: Float, ki: Float, kd: Float, maxRate: Float) {
        self.pid = AdaptivePIDController(kp: kp, ki: ki, kd: kd)
        self.maxRate = maxRate
    }
    
    @inline(__always)
    public func update(error: Float, dt: Float) -> Float {
        let rawOutput = pid.update(error: error, dt: dt)
        let maxChange = maxRate * dt
        let limitedOutput = max(lastOutput - maxChange, min(lastOutput + maxChange, rawOutput))
        lastOutput = limitedOutput
        return limitedOutput
    }
    
    @inline(__always)
    public func reset() {
        pid.reset()
        lastOutput = 0
    }
}
