//
//  HUDView.swift
//  VehicleControl
//
//  RESTORED: Original UI animations from Gata_RC
//  Features:
//  - Full throttle RPM bar animation with masking
//  - 3-bar max sticky animation
//  - RPM value overlay
//  - Original 9-line steering with hole radius and taper
//  - Original reverse display with blue color
//

import SwiftUI
import Combine

// MARK: - HUD View

/// Main heads-up display view with original animations
public struct HUDView: View {
    @ObservedObject var model: AppModel
    
    // Layout constants (from original)
    let r2TopOffset: CGFloat = 8 + 14
    let revTopOffset: CGFloat = 36 + 72
    let throttleScale: CGFloat = 2.0
    let reverseScale: CGFloat = 2.0
    let RPM_FONT_SIZE: CGFloat = 18
    let RPM_DIGIT_COUNT_AT_MAX = 4
    let RPM_DIGIT_WIDTH: CGFloat = 12.0
    var THROTTLE_X_SHIFT_BASE: CGFloat { (RPM_DIGIT_WIDTH * 3) * throttleScale + 32 }
    var THROTTLE_LEFT_NUDGE_TOTAL: CGFloat { -(RPM_DIGIT_WIDTH * 1.2) * throttleScale }
    var THROTTLE_X_SHIFT_FINAL: CGFloat { THROTTLE_X_SHIFT_BASE + THROTTLE_LEFT_NUDGE_TOTAL }
    let THROTTLE_Y_SHIFT: CGFloat = 24
    let RPM_OVER_BAR_GAP: CGFloat = 8
    let JOY_MAX_LEN: CGFloat = 28
    let joystickBottomOffset: CGFloat = 72
    let JOY_LEFT_MARGIN: CGFloat = 6
    let CENTER_RIGHT_SAFETY: CGFloat = 12
    let HOLE_RADIUS: CGFloat = 36
    let JOY_THICK_CENTER: CGFloat = 4.0
    var thicknessByLine: [CGFloat] { [1.0, 1.5, 2.0, 2.8, JOY_THICK_CENTER, 2.8, 2.0, 1.5, 1.0] }
    let colBlue = Color(red: 0.05, green: 0.22, blue: 0.85)
    let colRed = Color.red
    let lengthRatios: [CGFloat] = [0.14, 0.22, 0.36, 0.57, 1.0, 0.57, 0.36, 0.22, 0.14]
    let lengthFactor: CGFloat = 0.96
    let taperStrength: CGFloat = 0.6
    
    // Bar configuration
    private let BAR_BASE_COUNT: Int = 18
    private let BAR_RIGHT_TRIM: Int = 2
    private var BAR_COUNT: Int { max(1, BAR_BASE_COUNT * 2 - BAR_RIGHT_TRIM) }
    let BAR_MIN_W: CGFloat = 2.0
    let BAR_MAX_W: CGFloat = 16.0
    let BAR_WIDTH_EXP: CGFloat = 1.2
    let BASE_COUNT: Int = 12
    let BASE_SPACING: CGFloat = 8.0
    let ROW_SHRINK: CGFloat = 0.705
    let GROWTH_START_SHIFT: Int = 2
    let RAMP_BARS: Int = 7
    let BAR_SPACING_BOOST: CGFloat = 1.08
    let R2_MAX_ON_FRAC: CGFloat = 1008.0/1023.0
    let R2_MAX_OFF_FRAC: CGFloat = 992.0/1023.0
    let MAX_BLINK_ON: TimeInterval = 0.042
    let MAX_BLINK_OFF: TimeInterval = 0.126
    
    // Animation state
    @State private var maxSticky = false
    @State private var maxBlinkOn = true
    @State private var maxBlinkLastSwitch = Date()
    @State private var offPhaseStart = Date()
    @State private var offAnimProgress: CGFloat = 0.0
    @State private var brakeBlink = false
    @State private var reverseBlink = false
    @State private var gpsBlink = false
    @State private var blinkCancellable: AnyCancellable?
    @State private var gpsBlinkCancellable: AnyCancellable?
    @State private var r2UI: CGFloat = 0.0
    @State private var lastSmoothTime: Date = Date()
    @State private var uiSmoothCancellable: AnyCancellable?
    let R2_DECAY_PER_SEC: CGFloat = 1.65
    
    public init(model: AppModel) {
        self.model = model
    }
    
    public var body: some View {
        GeometryReader { geo in
            ZStack {
                if model.btnBrake {
                    brakeFullScreen()
                } else {
                    throttleRPM(width: geo.size.width)
                        .scaleEffect(throttleScale, anchor: .bottomLeading)
                        .padding(.leading, 8 + THROTTLE_X_SHIFT_FINAL)
                        .padding(.top, r2TopOffset + THROTTLE_Y_SHIFT)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    
                    l2Reverse(width: geo.size.width)
                        .scaleEffect(reverseScale, anchor: .bottomLeading)
                        .padding(.leading, 8 + THROTTLE_X_SHIFT_FINAL)
                        .padding(.top, revTopOffset)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    
                    nineSteeringLines(width: geo.size.width)
                        .padding(.leading, JOY_LEFT_MARGIN)
                        .padding(.bottom, joystickBottomOffset)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    
                    rightPanel(width: geo.size.width, height: geo.size.height)
                        .padding(.trailing, RPM_DIGIT_WIDTH)
                        .padding(.top, 8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
            }
            .onAppear {
                blinkCancellable = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect().sink { _ in brakeBlink.toggle() }
                _ = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in reverseBlink.toggle() }
                gpsBlinkCancellable = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect().sink { _ in gpsBlink.toggle() }
                lastSmoothTime = Date()
                r2UI = CGFloat(model.r2)
                maxBlinkLastSwitch = Date()
                offPhaseStart = Date()
                offAnimProgress = 0
                
                uiSmoothCancellable = Timer.publish(every: 1.0/120.0, on: .main, in: .common).autoconnect().sink { _ in
                    let nowD = Date()
                    let dt = max(0.0, nowD.timeIntervalSince(lastSmoothTime))
                    lastSmoothTime = nowD
                    let input = CGFloat(model.r2)
                    if input > r2UI { r2UI = input }
                    else { r2UI = max(input, r2UI - R2_DECAY_PER_SEC * CGFloat(dt)) }
                    r2UI = min(1.0, max(0.0, r2UI))
                    
                    if !maxSticky {
                        if r2UI >= R2_MAX_ON_FRAC { maxSticky = true; maxBlinkOn = true; maxBlinkLastSwitch = nowD; offAnimProgress = 0 }
                    } else if r2UI <= R2_MAX_OFF_FRAC { maxSticky = false; maxBlinkOn = true; offAnimProgress = 0 }
                    
                    if maxSticky {
                        let elapsed = nowD.timeIntervalSince(maxBlinkLastSwitch)
                        if maxBlinkOn {
                            if elapsed >= MAX_BLINK_ON { maxBlinkOn = false; maxBlinkLastSwitch = nowD; offPhaseStart = nowD; offAnimProgress = 0 }
                        } else {
                            let p = min(1.0, max(0.0, nowD.timeIntervalSince(offPhaseStart) / MAX_BLINK_OFF))
                            offAnimProgress = CGFloat(p)
                            if elapsed >= MAX_BLINK_OFF { maxBlinkOn = true; maxBlinkLastSwitch = nowD; offAnimProgress = 0 }
                        }
                    } else { offAnimProgress = 0 }
                }
            }
            .onDisappear {
                blinkCancellable?.cancel()
                gpsBlinkCancellable?.cancel()
                uiSmoothCancellable?.cancel()
            }
        }
        .padding(.zero)
        .background(Color.clear)
        .compositingGroup()
        .drawingGroup()
    }
    
    // MARK: - Brake Full Screen
    
    @ViewBuilder
    private func brakeFullScreen() -> some View {
        GeometryReader { geo in
            let base = min(geo.size.width, geo.size.height)
            let boxW = max(260, base * 0.55)
            let boxH = max(100, boxW * 0.38)
            let textSize = min(boxH * 0.55, 64)
            
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(brakeBlink ? colBlue : Color.white)
                    .frame(width: boxW, height: boxH)
                    .overlay(
                        Text("BRAKE")
                            .cyberFont(textSize, anchor: UnitPoint.center)
                            .kerning(1.5)
                            .foregroundColor(brakeBlink ? .white : colBlue)
                    )
                    .shadow(radius: 10, y: 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .transition(.opacity)
    }
    
    // MARK: - Bar Geometry Helper
    
    func makeBarGeometry(count: Int) -> (widths: [CGFloat], spacing: CGFloat, rowWidth: CGFloat) {
        let rawWidthsN: [CGFloat] = (0..<count).map { i in
            let t = CGFloat(i) / CGFloat(max(1, count - 1))
            return BAR_MIN_W + (BAR_MAX_W - BAR_MIN_W) * pow(t, BAR_WIDTH_EXP)
        }
        let rawSpacingN: CGFloat = BASE_SPACING
        let rawWidthsBase: [CGFloat] = (0..<BASE_COUNT).map { i in
            let t = CGFloat(i) / CGFloat(max(1, BASE_COUNT - 1))
            return BAR_MIN_W + (BAR_MAX_W - BAR_MIN_W) * pow(t, BAR_WIDTH_EXP)
        }
        let widthSumN = rawWidthsN.reduce(0, +)
        let rowWidthN = widthSumN + rawSpacingN * CGFloat(max(0, count - 1))
        let widthSumBase = rawWidthsBase.reduce(0, +)
        let rowWidthBase = widthSumBase + BASE_SPACING * CGFloat(max(0, BASE_COUNT - 1))
        let k = max(0.001, rowWidthBase / max(0.001, rowWidthN))
        let widthsScaled = rawWidthsN.map { $0 * k }
        let spacingScaled = rawSpacingN * k
        let finalRowWidth = widthsScaled.reduce(0, +) + spacingScaled * CGFloat(max(0, count - 1))
        return (widthsScaled, spacingScaled, finalRowWidth)
    }
    
    // MARK: - Throttle RPM (Original Animation)
    
    func throttleRPM(width: CGFloat) -> some View {
        @inline(__always) func smootherstep(_ x: CGFloat) -> CGFloat { let t = min(max(x, 0), 1); return t*t*t*(t*(t*6 - 15) + 10) }
        @inline(__always) func easeInOutSine(_ x: CGFloat) -> CGFloat { let t = min(max(x, 0), 1); return CGFloat(0.5 - 0.5 * cos(Double.pi * Double(t))) }
        @inline(__always) func blendedS(_ x: CGFloat) -> CGFloat { return (smootherstep(x) + easeInOutSine(x)) * 0.5 }
        
        let geo = makeBarGeometry(count: BAR_COUNT)
        let BAR_WIDTHS = geo.widths.map { $0 * ROW_SHRINK }
        let BAR_SPACING = geo.spacing * ROW_SHRINK * BAR_SPACING_BOOST
        let rowWidth = BAR_WIDTHS.reduce(0, +) + BAR_SPACING * CGFloat(max(0, BAR_COUNT - 1))
        
        let minDigitsWidth = CGFloat(RPM_DIGIT_COUNT_AT_MAX) * RPM_DIGIT_WIDTH
        var lowWidth: CGFloat = 0
        var startIndex = -1
        for i in 0..<BAR_COUNT {
            let add = BAR_WIDTHS[i] + (i > 0 ? BAR_SPACING : 0)
            if lowWidth + add <= minDigitsWidth { lowWidth += add; startIndex = i }
            else { if startIndex < 0 { startIndex = 0; lowWidth = BAR_WIDTHS[0] }; break }
        }
        if startIndex < 0 { startIndex = 0; lowWidth = BAR_WIDTHS[0] }
        
        let startIndexGrow = min(BAR_COUNT - 2, startIndex + 1 + GROWTH_START_SHIFT)
        var leftBlockWidth: CGFloat = 0
        if startIndexGrow >= 0 { for i in 0...startIndexGrow { leftBlockWidth += BAR_WIDTHS[i] + (i > 0 ? BAR_SPACING : 0) } }
        
        let topH: CGFloat = RPM_FONT_SIZE * 1.35
        let tickH: CGFloat = topH * 0.20
        let afterCountTotal = max(1, BAR_COUNT - (startIndexGrow + 1))
        let rampBars = max(1, min(afterCountTotal, RAMP_BARS))
        
        let finalHeights: [CGFloat] = (0..<BAR_COUNT).map { i in
            if i <= startIndexGrow { return tickH }
            let k = i - (startIndexGrow + 1)
            let denom = max(1, rampBars - 1)
            let u = CGFloat(min(k, rampBars - 1)) / CGFloat(denom)
            let s = blendedS(u)
            return topH * min(0.22 + (1.0 - 0.22) * s, 1.0)
        }
        
        let revealWidth: CGFloat = maxSticky ? rowWidth : (rowWidth * r2UI)
        let showBar = (r2UI > 0.0009) || maxSticky
        
        let barRow = HStack(alignment: .bottom, spacing: BAR_SPACING) {
            ForEach(0..<BAR_COUNT, id: \.self) { i in
                let j = i - (BAR_COUNT - 3)
                let localFrac: CGFloat = {
                    if maxSticky && !maxBlinkOn && j >= 0 && j < 3 {
                        let perBar: CGFloat = 1.0/3.0
                        let startT = perBar * CGFloat(j)
                        return min(1.0, max(0.0, (offAnimProgress - startT) / perBar))
                    } else { return 1.0 }
                }()
                Rectangle()
                    .fill(colBlue)
                    .frame(width: BAR_WIDTHS[i], height: finalHeights[i])
                    .mask(HStack(spacing: 0) { Rectangle().frame(width: max(0.001, BAR_WIDTHS[i] * localFrac)); Spacer(minLength: 0) })
            }
        }
        .frame(width: rowWidth, alignment: .bottomLeading)
        .mask(HStack(spacing: 0) { Rectangle().frame(width: revealWidth); Spacer(minLength: 0) })
        .opacity(showBar ? (maxSticky ? (maxBlinkOn ? 0 : 1) : 1) : 0)
        
        let rpmValue: Int = {
            if maxSticky {
                let barsBefore = CGFloat(BAR_COUNT - 3)
                let frac: CGFloat = maxBlinkOn ? (barsBefore / CGFloat(BAR_COUNT)) : ((barsBefore + offAnimProgress * 3.0) / CGFloat(BAR_COUNT))
                return Int(round(frac * 9000.0))
            } else { return Int(round(r2UI * 9000.0)) }
        }()
        
        let rpmOverlay = VStack(alignment: .leading, spacing: -1) {
            Text("\(rpmValue)").cyberFont(RPM_FONT_SIZE).kerning(1.0).foregroundColor(.white).lineLimit(1).minimumScaleFactor(0.6)
            VStack(alignment: .leading, spacing: 1) {
                Rectangle().fill(Color.white.opacity(0.9)).frame(height: 1)
                Text("RPM").cyberFont(RPM_FONT_SIZE * 0.36, anchor: .trailing).foregroundColor(.white).frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .frame(width: leftBlockWidth, alignment: .leading)
        .offset(y: -RPM_OVER_BAR_GAP)
        .allowsHitTesting(false)
        
        return ZStack(alignment: .bottomLeading) { barRow; rpmOverlay }
    }
    
    // MARK: - L2 Reverse (Original Animation)
    
    func l2Reverse(width: CGFloat) -> some View {
        let r2Active = model.r2 >= 24.0/1023.0
        let l2Active = (!r2Active) && model.l2 >= 6.0/1023.0
        let N = 3
        let gap: CGFloat = 3
        let span: CGFloat = 2*JOY_MAX_LEN
        let l2 = CGFloat(model.l2)
        let full = min(N, Int(round(l2 * CGFloat(N))))
        let barW = max(1, Int((span - gap * CGFloat(N-1))/CGFloat(N)))
        let barHeight: CGFloat = 16
        
        let bars = ZStack(alignment: .bottomLeading) {
            HStack(alignment: .bottom, spacing: gap) {
                ForEach(0..<N, id: \.self) { i in
                    Rectangle().fill(colBlue)
                        .frame(width: CGFloat(barW), height: (i < full && l2Active) ? barHeight : 0)
                        .opacity((i < full && l2Active) ? 1 : 0)
                }
            }.frame(height: barHeight)
        }
        return HStack(spacing: 8) { bars; Text("REVERSE").cyberFont(10).opacity(l2Active ? (reverseBlink ? 1.0 : 0.0) : 0.0) }
    }
    
    // MARK: - Temperature Row
    
    @ViewBuilder
    private func tempRow(name: String, valueC10: UInt16, size: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(name).cyberFont(size, anchor: .trailing).foregroundColor(colBlue)
            Text("\(valueC10/10)").cyberFont(size, anchor: .trailing).foregroundColor(.white).padding(.leading, 14)
            Text("°C").cyberFont(size, anchor: .trailing).foregroundColor(.white).padding(.leading, 10)
        }
    }
    
    // MARK: - Nine Steering Lines (Original Animation)
    
    @ViewBuilder
    func nineSteeringLines(width: CGFloat) -> some View {
        let dx = CGFloat(model.lx)
        let dead: CGFloat = 60.0/512.0
        let a = abs(dx)
        let show = a > dead
        let norm = max(0, (a - dead) / (1.0 - dead))
        let screenCenter = width / 2
        let joyCenterX = (screenCenter - CENTER_RIGHT_SAFETY + JOY_LEFT_MARGIN) / 2
        let leftMaxHalf = max(0, joyCenterX - JOY_LEFT_MARGIN)
        let rightMaxHalf = max(0, (screenCenter - CENTER_RIGHT_SAFETY) - joyCenterX)
        let containerWidth = leftMaxHalf + rightMaxHalf
        let vGap: CGFloat = 6
        let N = 9
        let avgH = thicknessByLine.reduce(0, +) / CGFloat(N)
        let step = avgH + vGap
        
        VStack(spacing: vGap) {
            ForEach(0..<N, id: \.self) { i in
                let k = CGFloat(i) - CGFloat(N - 1) / 2.0
                let y = k * step
                let R = HOLE_RADIUS
                let innerOffset: CGFloat = (abs(y) < R) ? sqrt(max(0, R*R - y*y)) : 0
                let sideMax = (dx >= 0) ? rightMaxHalf : leftMaxHalf
                let effHalf = max(0, sideMax - innerOffset)
                let baseHalf = effHalf * lengthRatios[i] * lengthFactor
                let w = show ? baseHalf * norm : 0
                let hStart = thicknessByLine[i]
                let hEnd = max(0.5, hStart * (1 - taperStrength * norm))
                let hBox = max(hStart, hEnd)
                let xCenter = leftMaxHalf + (dx >= 0 ? (innerOffset + w/2) : -(innerOffset + w/2))
                
                ZStack {
                    Rectangle().opacity(0).frame(width: containerWidth, height: hBox)
                        .overlay(TaperBar(width: w, startHeight: hStart, endHeight: hEnd, toRight: dx >= 0)
                            .fill(colBlue).frame(width: w, height: hBox).position(x: xCenter, y: hBox/2))
                }.frame(width: containerWidth, height: hBox)
            }
        }.opacity(show ? 1 : 0.2)
    }
    
    // MARK: - Right Panel
    
    func rightPanel(width: CGFloat, height: CGFloat) -> some View {
        let t = model.tele
        let carAlive = model.teleAlive
        let gpsReady = (carAlive && t?.gpsAlive == 1 && t?.fixOK == 1)
        let TEMP_SIZE: CGFloat = RPM_FONT_SIZE
        let SPEED_NUM_SIZE: CGFloat = RPM_FONT_SIZE * 1.18
        let SPEED_UNIT_SIZE: CGFloat = RPM_FONT_SIZE * 0.85
        
        return VStack(alignment: .trailing, spacing: 6) {
            if !gpsReady {
                Text("GPS waiting…").cyberFont(12, anchor: .trailing).opacity(gpsBlink ? 1.0 : 0.0)
                if carAlive, let tt = t {
                    Spacer().frame(height: 6)
                    tempRow(name: "M1:", valueC10: tt.m1_c10, size: TEMP_SIZE)
                    tempRow(name: "M2:", valueC10: tt.m2_c10, size: TEMP_SIZE)
                }
            } else if let tt = t {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text("\(Int(max(0, round(Double(tt.speed_kmh)))))").cyberFont(SPEED_NUM_SIZE, anchor: .trailing).foregroundColor(.white)
                    Text("km/h").cyberFont(SPEED_UNIT_SIZE, anchor: .trailing).foregroundColor(colBlue)
                }
                Spacer().frame(height: 8)
                tempRow(name: "M1:", valueC10: tt.m1_c10, size: TEMP_SIZE)
                tempRow(name: "M2:", valueC10: tt.m2_c10, size: TEMP_SIZE)
            }
        }.frame(maxWidth: .infinity, alignment: .trailing)
    }
}
