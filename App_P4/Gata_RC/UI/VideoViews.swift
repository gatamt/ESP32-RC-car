//
//  VideoViews.swift
//  VehicleControl
//
//  Video display views for preview and fullscreen modes
//

import SwiftUI

// MARK: - Video Preview

/// Small video preview in corner
public struct VideoPreview: View {
    @ObservedObject var model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        GeometryReader { geo in
            let side = max(140, geo.size.width * 0.30)

            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.black.opacity(0.22))

                if let ui = model.videoImage {
                    Image(uiImage: ui)
                        .resizable()
                        .scaledToFill()
                        .scaleEffect(x: -1, y: 1)
                        .frame(width: side, height: side)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else {
                    Text("VIDEO")
                        .cyberFont(12, anchor: .center)
                        .foregroundColor(.white.opacity(0.7))
                }
            }
            .frame(width: side, height: side)
            .clipped()
            .padding(.trailing, 0)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .allowsHitTesting(false)
        }
    }
}

// MARK: - Fullscreen Video

/// Fullscreen video display with optional AI overlay
public struct FullscreenVideo: View {
    @ObservedObject var model: AppModel
    
    public init(model: AppModel) {
        self.model = model
    }
    
    public var body: some View {
        Group {
            if model.isFullscreenVideo || model.isAutonomousMode {
                GeometryReader { proxy in
                    let fullSize = proxy.size

                    ZStack {
                        Color.black.ignoresSafeArea()

                        if let ui = model.videoImage {
                            ZStack {
                                Image(uiImage: ui)
                                    .resizable()
                                    .scaledToFill()
                                    .scaleEffect(x: -1, y: 1)
                                    .frame(width: fullSize.width, height: fullSize.height)
                                    .clipped()

                                if model.isAutonomousMode {
                                    EquatableView(content: AIDetectionsOverlay(
                                        model: model,
                                        viewSize: fullSize
                                    ))
                                }
                            }
                            .ignoresSafeArea()
                        }
                    }
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .transition(.opacity)
            } else {
                Color.clear
            }
        }
    }
}

// MARK: - Video Container

/// Container for video with mode-aware display
public struct VideoContainer: View {
    @ObservedObject var model: AppModel
    let showAIStats: Bool
    
    public init(model: AppModel, showAIStats: Bool = false) {
        self.model = model
        self.showAIStats = showAIStats
    }
    
    public var body: some View {
        ZStack {
            FullscreenVideo(model: model)
                .zIndex(0)
            
            if showAIStats && model.isAutonomousMode {
                AIStatsOverlay(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(8)
                    .zIndex(10)
            }
        }
    }
}
