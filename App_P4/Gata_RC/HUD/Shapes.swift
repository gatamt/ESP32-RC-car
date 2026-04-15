//
//  Shapes.swift
//  VehicleControl
//
//  Custom shapes for HUD rendering
//

import SwiftUI

// MARK: - Taper Bar Shape

/// Tapered bar shape for throttle/reverse indicators
public struct TaperBar: Shape {
    var width: CGFloat
    var startHeight: CGFloat
    var endHeight: CGFloat
    var toRight: Bool
    
    public init(width: CGFloat, startHeight: CGFloat, endHeight: CGFloat, toRight: Bool) {
        self.width = width
        self.startHeight = startHeight
        self.endHeight = endHeight
        self.toRight = toRight
    }
    
    public func path(in rect: CGRect) -> Path {
        let w = max(0, width)
        let hs = max(0.5, startHeight)
        let he = max(0.5, endHeight)
        let hmax = max(hs, he)
        let cy = hmax / 2
        
        var p = Path()
        
        if toRight {
            p.move(to: CGPoint(x: 0, y: cy - hs/2))
            p.addLine(to: CGPoint(x: w, y: cy - he/2))
            p.addLine(to: CGPoint(x: w, y: cy + he/2))
            p.addLine(to: CGPoint(x: 0, y: cy + hs/2))
        } else {
            p.move(to: CGPoint(x: w, y: cy - hs/2))
            p.addLine(to: CGPoint(x: 0, y: cy - he/2))
            p.addLine(to: CGPoint(x: 0, y: cy + he/2))
            p.addLine(to: CGPoint(x: w, y: cy + hs/2))
        }
        
        p.closeSubpath()
        return p
    }
}

// MARK: - Steering Line Shape

/// Single steering indicator line
public struct SteeringLine: Shape {
    let length: CGFloat
    let thickness: CGFloat
    let deflection: CGFloat // -1 to 1
    let maxAngle: CGFloat
    
    public init(length: CGFloat, thickness: CGFloat, deflection: CGFloat, maxAngle: CGFloat = 45) {
        self.length = length
        self.thickness = thickness
        self.deflection = deflection
        self.maxAngle = maxAngle
    }
    
    public func path(in rect: CGRect) -> Path {
        var p = Path()
        
        let angle = Angle(degrees: Double(deflection) * Double(maxAngle))
        let endX = length * CGFloat(cos(angle.radians))
        let endY = length * CGFloat(sin(angle.radians))
        
        p.move(to: .zero)
        p.addLine(to: CGPoint(x: endX, y: endY))
        
        return p.strokedPath(StrokeStyle(lineWidth: thickness, lineCap: .round))
    }
}

// MARK: - Arc Shape

/// Arc shape for gauges
public struct ArcShape: Shape {
    var startAngle: Angle
    var endAngle: Angle
    var clockwise: Bool
    
    public init(startAngle: Angle, endAngle: Angle, clockwise: Bool = false) {
        self.startAngle = startAngle
        self.endAngle = endAngle
        self.clockwise = clockwise
    }
    
    public func path(in rect: CGRect) -> Path {
        var p = Path()
        p.addArc(
            center: CGPoint(x: rect.midX, y: rect.midY),
            radius: min(rect.width, rect.height) / 2,
            startAngle: startAngle,
            endAngle: endAngle,
            clockwise: clockwise
        )
        return p
    }
}

// MARK: - Tick Mark Shape

/// Radial tick marks for gauge
public struct TickMarks: Shape {
    let count: Int
    let innerRadius: CGFloat
    let outerRadius: CGFloat
    let startAngle: Angle
    let endAngle: Angle
    
    public init(count: Int, innerRadius: CGFloat, outerRadius: CGFloat,
                startAngle: Angle, endAngle: Angle) {
        self.count = count
        self.innerRadius = innerRadius
        self.outerRadius = outerRadius
        self.startAngle = startAngle
        self.endAngle = endAngle
    }
    
    public func path(in rect: CGRect) -> Path {
        var p = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let angleRange = endAngle.radians - startAngle.radians
        
        for i in 0..<count {
            let fraction = Double(i) / Double(count - 1)
            let angle = startAngle.radians + angleRange * fraction
            
            let innerPoint = CGPoint(
                x: center.x + innerRadius * CGFloat(cos(angle)),
                y: center.y + innerRadius * CGFloat(sin(angle))
            )
            let outerPoint = CGPoint(
                x: center.x + outerRadius * CGFloat(cos(angle)),
                y: center.y + outerRadius * CGFloat(sin(angle))
            )
            
            p.move(to: innerPoint)
            p.addLine(to: outerPoint)
        }
        
        return p
    }
}
