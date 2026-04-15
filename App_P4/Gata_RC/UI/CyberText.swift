//
//  CyberText.swift
//  VehicleControl
//
//  Custom cyber-style font modifiers
//

import SwiftUI

// MARK: - Cyber Text Modifier

/// View modifier for cyber-style text appearance
public struct CyberTextModifier: ViewModifier {
    let size: CGFloat
    let anchor: UnitPoint
    
    public init(size: CGFloat, anchor: UnitPoint = .leading) {
        self.size = size
        self.anchor = anchor
    }
    
    public func body(content: Content) -> some View {
        content
            .font(.custom(CyberFont.name, size: size))
            .fontWidth(.expanded)
            .scaleEffect(x: CyberFont.scaleX, y: CyberFont.scaleY, anchor: anchor)
    }
}

// MARK: - Text Extension

extension Text {
    /// Apply cyber font styling
    /// - Parameters:
    ///   - size: Font size
    ///   - anchor: Scale anchor point
    /// - Returns: Styled view
    public func cyberFont(_ size: CGFloat, anchor: UnitPoint = .leading) -> some View {
        self.modifier(CyberTextModifier(size: size, anchor: anchor))
    }
}

// MARK: - View Extension

extension View {
    /// Apply cyber font styling to any view
    public func cyberStyle(size: CGFloat, anchor: UnitPoint = .leading) -> some View {
        self.modifier(CyberTextModifier(size: size, anchor: anchor))
    }
}
