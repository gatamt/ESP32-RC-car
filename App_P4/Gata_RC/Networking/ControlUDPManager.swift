//
//  ControlUDPManager.swift
//  GATA_RC_P4
//
//  UDP control and telemetry manager for ESP32-P4
//

import Network
import Foundation

public final class ControlUDPManager: NSObject {
    private var p4Host: NWEndpoint.Host? = nil
    private let controlPort: NWEndpoint.Port
    private let queue = DispatchQueue(label: "control.udp.queue", qos: .userInteractive)
    private var controlConn: NWConnection?
    private var teleConn: NWConnection?
    private var listener: NWListener?

    public private(set) var isReady = false
    private weak var model: AppModel?
    private var lastTeleRx: Date?
    private var hbTimer: Timer?
    private var watchdogTimer: Timer?

    private var helloTimer: DispatchSourceTimer?
    private var helloAcked = false
    private var helloSends = 0

    // Faster initial handshake - 0.3s for first 15 attempts, then 1s
    private let helloFastInterval: TimeInterval = 0.3
    private let helloSlowInterval: TimeInterval = 1.0
    private let helloFastBurst = 15
    private let helloMaxBeforeSlowdown = 30

    // Connection watchdog settings
    private let telemetryTimeout: TimeInterval = 3.0  // Consider disconnected after 3s without telemetry
    private let watchdogInterval: TimeInterval = 1.0  // Check every second

    // TEL1 body: timestamp(4) + battery(1) + cpu_temp(1) + motor_l(2) + motor_r(2) + lat(4) + lon(4) + heading(2) + gps_fix(1) + wifi(1) + reserved(2) = 24
    private let tel1BodyLen = 24
    private let tel1ExtLen = 8

    public init(model: AppModel) {
        self.controlPort = NWEndpoint.Port(rawValue: NetworkPorts.control)!
        self.model = model
        super.init()
        startControlConnection()
        startListener()
        startHelloHandshake()
        startHeartbeat()
        startConnectionWatchdog()
    }

    deinit {
        hbTimer?.invalidate()
        watchdogTimer?.invalidate()
        helloTimer?.cancel()
        listener?.cancel()
        teleConn?.cancel()
        controlConn?.cancel()
    }

    // MARK: - Public Interface

    /// Trigger a reconnection attempt (e.g., when WiFi changes or app becomes active)
    public func triggerReconnect() {
        queue.async { [weak self] in
            guard let self = self else { return }
            // Reset hello state and restart handshake
            self.helloAcked = false
            self.helloSends = 0
            self.restartHelloHandshake()
        }
    }

    // MARK: - Listener Setup

    private func startListener() {
        do {
            listener = try NWListener(using: .udp, on: controlPort)
            listener?.newConnectionHandler = { [weak self] newConn in self?.handleIncomingConnection(newConn) }
            listener?.start(queue: queue)
        } catch { }
    }

    private func handleIncomingConnection(_ newConn: NWConnection) {
        newConn.start(queue: queue)
        if self.teleConn == nil { self.teleConn = newConn }
        self.isReady = true
        DispatchQueue.main.async { self.model?.peripheralName = "P4-Direct" }
        receiveFromConnection(newConn)
    }

    private func receiveFromConnection(_ conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, _, _ in
            if let data = data {
                if let endpoint = conn.currentPath?.remoteEndpoint, case let .hostPort(host, _) = endpoint {
                    if self?.p4Host == nil { self?.p4Host = host }
                }
                self?.handleTelemetryDatagram(data)
            }
            self?.receiveFromConnection(conn)
        }
    }

    // MARK: - Control Connection

    private func startControlConnection() {
        let host = NWEndpoint.Host(P4Host.ip)
        p4Host = host
        let conn = NWConnection(host: host, port: controlPort, using: .udp)
        controlConn = conn
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.isReady = true
            case .failed(_):
                self?.isReady = false
                // Try to reconnect after failure
                self?.queue.asyncAfter(deadline: .now() + 1.0) {
                    self?.restartControlConnection()
                }
            default:
                break
            }
        }
        conn.start(queue: queue)
        receiveControlResponses()
    }

    private func restartControlConnection() {
        controlConn?.cancel()
        controlConn = nil
        startControlConnection()
    }

    private func receiveControlResponses() {
        controlConn?.receiveMessage { [weak self] data, _, _, _ in
            if let data = data {
                self?.handleControlResponse(data)
            }
            self?.receiveControlResponses()
        }
    }

    // MARK: - Hello Handshake

    private func startHelloHandshake() {
        helloTimer?.cancel()
        helloSends = 0
        helloAcked = false

        let timer = DispatchSource.makeTimerSource(queue: queue)
        // Start with fast interval
        timer.schedule(deadline: .now(), repeating: helloFastInterval)
        timer.setEventHandler { [weak self] in
            self?.sendHello()
        }
        helloTimer = timer
        timer.resume()
    }

    private func restartHelloHandshake() {
        helloTimer?.cancel()
        helloTimer = nil
        startHelloHandshake()
    }

    private func sendHello() {
        guard let conn = controlConn else { return }

        // Always send HEL0, even if previously acked (acts as keepalive)
        var payload = Data([0x48, 0x45, 0x4C, 0x30]) // "HEL0"
        payload.append(ControlConfig.protocolVersion)
        payload.append(0x00) // flags
        payload.append(0x00) // reserved
        payload.append(0x00)

        conn.send(content: payload, completion: .contentProcessed { _ in })
        helloSends += 1

        // Adjust timing based on sends count
        if helloSends == helloFastBurst && !helloAcked {
            // Switch to slower interval after fast burst
            helloTimer?.schedule(deadline: .now() + helloSlowInterval, repeating: helloSlowInterval)
        } else if helloSends >= helloMaxBeforeSlowdown && !helloAcked {
            // Even slower if still no ack after many attempts
            helloTimer?.schedule(deadline: .now() + 3.0, repeating: 3.0)
        }

        // If we were acked before, keep sending periodic keepalive (every 2s)
        if helloAcked && helloSends > 1 {
            helloTimer?.schedule(deadline: .now() + 2.0, repeating: 2.0)
        }
    }

    private func handleControlResponse(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 8 else { return }
        if bytes[0] == 0x4F, bytes[1] == 0x4B, bytes[2] == 0x41, bytes[3] == 0x59 {
            // "OKAY" response received
            let wasAcked = helloAcked
            helloAcked = true

            if !wasAcked {
                // First ack - switch to slow keepalive
                helloTimer?.schedule(deadline: .now() + 2.0, repeating: 2.0)
            }
        }
    }

    // MARK: - Heartbeat & Watchdog

    private func startHeartbeat() {
        hbTimer?.invalidate()
        hbTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let alive = self.lastTeleRx.map { Date().timeIntervalSince($0) < 1.5 } ?? false
            DispatchQueue.main.async {
                self.model?.teleAlive = alive
                self.model?.bleConnected = alive
            }
        }
    }

    /// Watchdog timer that triggers reconnect when telemetry times out
    private func startConnectionWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: watchdogInterval, repeats: true) { [weak self] _ in
            guard let self = self else { return }

            let timeSinceLastTele: TimeInterval
            if let lastRx = self.lastTeleRx {
                timeSinceLastTele = Date().timeIntervalSince(lastRx)
            } else {
                timeSinceLastTele = .infinity
            }

            // If telemetry timed out and we thought we were connected, trigger reconnect
            if timeSinceLastTele > self.telemetryTimeout {
                // Only trigger if we previously had an acked connection
                if self.helloAcked {
                    self.triggerReconnect()
                }
            }
        }
    }
    
    private func handleTelemetryDatagram(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return }
        
        // TEL1 format from P4
        if bytes[0] == 0x54, bytes[1] == 0x45, bytes[2] == 0x4C, bytes[3] == 0x31 {
            parseTEL1Packet(bytes)
            return
        }
        
        // Legacy TLM1 format
        if bytes[0] == 0x54, bytes[1] == 0x4C, bytes[2] == 0x4D, bytes[3] == 0x31 {
            parseLegacyTLM1Packet(bytes)
        }
    }
    
    private func parseTEL1Packet(_ bytes: [UInt8]) {
        guard bytes.count >= 4 + tel1BodyLen else { return }
        
        var i = 4
        func u8() -> UInt8 { defer { i += 1 }; return bytes[i] }
        func i8() -> Int8 { defer { i += 1 }; return Int8(bitPattern: bytes[i]) }
        func u16le() -> UInt16 { defer { i += 2 }; return UInt16(bytes[i]) | (UInt16(bytes[i+1]) << 8) }
        func i32le() -> Int32 { defer { i += 4 }; return Int32(bitPattern: UInt32(bytes[i]) | (UInt32(bytes[i+1]) << 8) | (UInt32(bytes[i+2]) << 16) | (UInt32(bytes[i+3]) << 24)) }
        func u32le() -> UInt32 { defer { i += 4 }; return UInt32(bytes[i]) | (UInt32(bytes[i+1]) << 8) | (UInt32(bytes[i+2]) << 16) | (UInt32(bytes[i+3]) << 24) }
        
        let timestamp = u32le()
        let batteryPct = u8()
        let cpuTemp = i8()
        let motorL = u16le()
        let motorR = u16le()
        let lat = i32le()
        let lon = i32le()
        let heading = u16le()
        let gpsFix = u8()
        let wifiRssi = u8()
        _ = u16le() // reserved

        var ctrlLastSeq: UInt32 = 0
        var ctrlLost: UInt32 = 0
        if bytes.count >= 4 + tel1BodyLen + tel1ExtLen {
            ctrlLastSeq = u32le()
            ctrlLost = u32le()
        }

        let tele = Telemetry(magic: 0x314C4554, timestamp: timestamp, batteryPercent: batteryPct, cpuTemp: cpuTemp,
                             motorSpeedLeft: motorL, motorSpeedRight: motorR, latitude: lat, longitude: lon,
                             heading: heading, gpsFix: gpsFix, wifiRssi: wifiRssi,
                             controlSeq: ctrlLastSeq, controlLost: ctrlLost)
        
        DispatchQueue.main.async {
            self.model?.tele = tele
            self.model?.teleAlive = true
            self.model?.bleConnected = true
            self.model?.camBatteryPercent = Int(batteryPct)
        }
        self.lastTeleRx = Date()
    }
    
    private func parseLegacyTLM1Packet(_ bytes: [UInt8]) {
        let legacyBodyLen = 17
        guard bytes.count >= 4 + legacyBodyLen + 2 else { return }
        
        let bodyStart = 4
        let body = Array(bytes[bodyStart..<(bodyStart + legacyBodyLen)])
        
        let gotCrc = UInt16(bytes[bodyStart + legacyBodyLen]) | (UInt16(bytes[bodyStart + legacyBodyLen + 1]) << 8)
        let calcCrc = crc16_ccitt(body)
        guard gotCrc == calcCrc else { return }
        
        var idx = 0
        func u16() -> UInt16 { defer { idx += 2 }; return UInt16(body[idx]) | (UInt16(body[idx + 1]) << 8) }
        func u8() -> UInt8 { defer { idx += 1 }; return body[idx] }
        func f32() -> Float { defer { idx += 4 }; return Float(bitPattern: UInt32(body[idx]) | (UInt32(body[idx + 1]) << 8) | (UInt32(body[idx + 2]) << 16) | (UInt32(body[idx + 3]) << 24)) }
        func u32() -> UInt32 { defer { idx += 4 }; return UInt32(body[idx]) | (UInt32(body[idx + 1]) << 8) | (UInt32(body[idx + 2]) << 16) | (UInt32(body[idx + 3]) << 24) }
        
        let magic = u16()
        guard magic == 0x6D11 else { return }
        
        let speed = f32()
        let gpsAlive = u8()
        let fixOK = u8()
        _ = u8()
        let m1 = u16()
        let m2 = u16()
        _ = u32()
        
        let tele = Telemetry(magic: UInt32(magic), motorSpeedLeft: m1, motorSpeedRight: m2, gpsFix: (gpsAlive == 1 && fixOK == 1) ? 2 : 0, speed_kmh: speed)
        
        DispatchQueue.main.async {
            self.model?.tele = tele
            self.model?.teleAlive = true
            self.model?.bleConnected = true
        }
        self.lastTeleRx = Date()
    }
    
    public func sendControlFrame(_ frameBytes: [UInt8]) {
        guard let conn = controlConn else { return }
        conn.send(content: Data(frameBytes), completion: .contentProcessed { _ in })
    }
}
