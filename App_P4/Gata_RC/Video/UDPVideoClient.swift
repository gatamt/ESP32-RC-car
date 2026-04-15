//
//  UDPVideoClient.swift
//  GATA_RC_P4
//
//  UDP video streaming client for H.264 video from ESP32-P4
//  With proper frame assembly, timeout handling, and IDR request support
//

import Network
import Foundation
import UIKit
import Darwin

// MARK: - UDP Video Client

public final class UDPVideoClient: NSObject {
    private let port: NWEndpoint.Port
    private let queue = DispatchQueue(label: "udp.video.queue", qos: .userInteractive)
    private var udpSocket: Int32 = -1  // Raw UDP socket

    // For sending IDR requests back to P4
    private var controlConnection: NWConnection?
    private let controlPort: NWEndpoint.Port
    private var p4Address: String?

    private weak var model: AppModel?
    private weak var ai: MediaPipeVisionManager?

    private var registrationTimer: DispatchSourceTimer?
    private var registrationConn: NWConnection?

    private var frameBuffer = Data(capacity: VideoConfig.maxH264FrameSize)
    private let hardwareDecoder = HardwareH264Decoder()
    private let decodeQueue = DispatchQueue(label: "video.decode.queue", qos: .userInteractive, attributes: .concurrent)

    // MARK: - Frame Assembly State

    private struct Pending {
        var frameId: UInt32
        var width: Int
        var height: Int
        var totalLen: Int
        var count: Int
        var isKeyframe: Bool
        var chunks: [Int: Data] = [:]
        var receivedBytes: Int = 0
    }

    private var pending: Pending?
    private var pendingStartTime: Date? = nil

    // Increased timeout from 0.5s to 2.0s for WiFi variability
    private let pendingTimeout: TimeInterval = 2.0

    // Track if we need a keyframe (decoder not initialized or lost sync)
    private var needsKeyframe: Bool = true
    private var lastKeyframeTime: Date? = nil
    private var consecutiveDecodeFailures: Int = 0
    private let maxDecodeFailuresBeforeIDRRequest: Int = 10

    // Stats
    private var framesReceived: UInt64 = 0
    private var framesDecoded: UInt64 = 0
    private var framesDropped: UInt64 = 0
    private var packetsReceived: UInt64 = 0
    private var chunksReceived: UInt64 = 0
    private var incompleteFrames: UInt64 = 0
    private var idrRequestsSent: UInt64 = 0

    public init(model: AppModel, ai: MediaPipeVisionManager?) {
        self.port = NWEndpoint.Port(rawValue: NetworkPorts.video)!
        self.controlPort = NWEndpoint.Port(rawValue: NetworkPorts.control)!
        self.model = model
        self.ai = ai
        super.init()

        startListener()
        startRegistrationPings()
    }

    deinit {
        registrationTimer?.cancel()
        registrationConn?.cancel()
        controlConnection?.cancel()
        if udpSocket >= 0 { close(udpSocket) }
    }

    // MARK: - Public Interface

    /// Trigger video registration restart (e.g., when WiFi changes)
    public func triggerReconnect() {
        queue.async { [weak self] in
            self?.restartRegistrationPings()
        }
    }

    private func restartRegistrationPings() {
        registrationTimer?.cancel()
        registrationConn?.cancel()
        registrationConn = nil
        startRegistrationPings()
    }

    // MARK: - Network Listener

    private func startListener() {
        udpSocket = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        if udpSocket < 0 {
            return
        }
        // Non-blocking socket so registration timer on same queue is not starved
        var flags = fcntl(udpSocket, F_GETFL, 0)
        _ = fcntl(udpSocket, F_SETFL, flags | O_NONBLOCK)

        var rcvBuf: Int32 = 1_048_576
        setsockopt(udpSocket, SOL_SOCKET, SO_RCVBUF, &rcvBuf, socklen_t(MemoryLayout.size(ofValue: rcvBuf)))

        var reuse: Int32 = 1
        setsockopt(udpSocket, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse)))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = NetworkPorts.video.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY.bigEndian

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(udpSocket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bindResult < 0 {
            close(udpSocket); udpSocket = -1; return
        }

        readLoop()
    }

    private func readLoop() {
        guard udpSocket >= 0 else { return }
        queue.async { [weak self] in
            guard let self = self else { return }
            var buffer = [UInt8](repeating: 0, count: 2048)
            var addr = sockaddr_in()
            var addrLen: socklen_t = socklen_t(MemoryLayout<sockaddr_in>.size)

            let n = withUnsafeMutablePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(self.udpSocket, &buffer, buffer.count, 0, $0, &addrLen)
                }
            }

            if n > 0 {
                // Capture sender IP for IDR requests
                var ipBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                inet_ntop(AF_INET, &addr.sin_addr, &ipBuf, socklen_t(INET_ADDRSTRLEN))
                self.p4Address = String(cString: ipBuf)

                let data = Data(buffer.prefix(Int(n)))
                self.packetsReceived += 1
                self.handleVideoDatagram(data)
            } else {
                usleep(1_000)
            }
            self.readLoop()
        }
    }

    private func startRegistrationPings() {
        registrationTimer?.cancel()
        registrationConn?.cancel()

        let host = NWEndpoint.Host(P4Host.ip)
        let conn = NWConnection(host: host, port: port, using: .udp)
        registrationConn = conn
        conn.start(queue: queue)

        let timer = DispatchSource.makeTimerSource(queue: queue)
        var sends = 0
        timer.schedule(deadline: .now(), repeating: 1.0)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            sends += 1
            let payload = Data([0x56, 0x49, 0x44, 0x30]) // "VID0"
            conn.send(content: payload, completion: .contentProcessed { _ in })
            if sends == 10 {
                // Keep a slower heartbeat to refresh app IP on reconnect
                self.registrationTimer?.schedule(deadline: .now() + 5.0, repeating: 5.0)
            }
        }
        registrationTimer = timer
        timer.resume()
    }

    // NWConnection handlers removed (raw UDP socket is used instead)

    // MARK: - Packet Handling

    private func handleVideoDatagram(_ data: Data) {
        guard data.count >= 4 else {
            return
        }
        let bytes = [UInt8](data)

        // CAM0: Battery telemetry
        if bytes[0] == 0x43, bytes[1] == 0x41, bytes[2] == 0x4D, bytes[3] == 0x30, data.count >= 5 {
            DispatchQueue.main.async { [weak self] in self?.model?.camBatteryPercent = Int(bytes[4]) }
            return
        }

        // H264: H.264 frame (magic = "H264" = 0x48 0x32 0x36 0x34)
        if bytes[0] == 0x48, bytes[1] == 0x32, bytes[2] == 0x36, bytes[3] == 0x34 {
            handleH264Frame(data, bytes: bytes)
            return
        }

    }

    // MARK: - H.264 Frame Assembly

    private static var keyframeCount: UInt64 = 0
    private static var pframeCount: UInt64 = 0

    private func handleH264Frame(_ data: Data, bytes: [UInt8]) {
        guard data.count >= 28 else { return }

        // Parse header
        var i = 4
        func u16le() -> UInt16 { defer { i += 2 }; return UInt16(bytes[i]) | (UInt16(bytes[i+1]) << 8) }
        func u32le() -> UInt32 { defer { i += 4 }; return UInt32(bytes[i]) | (UInt32(bytes[i+1]) << 8) | (UInt32(bytes[i+2]) << 16) | (UInt32(bytes[i+3]) << 24) }

        let frameId = u32le()
        let width = Int(u16le())
        let height = Int(u16le())
        _ = u32le() // timestamp
        let totalLen = Int(u32le())
        let chunkIdx = Int(u16le())
        let chunkCount = Int(u16le())
        let isKeyframe = bytes[24] == 1
        let payload = data.dropFirst(28)

        chunksReceived += 1

        // Track keyframe vs P-frame stats
        if chunkIdx == 0 {
            if isKeyframe {
                Self.keyframeCount += 1
            } else {
                Self.pframeCount += 1
            }
        }

        // Check for pending frame timeout
        if let start = pendingStartTime, Date().timeIntervalSince(start) > pendingTimeout {
            if pending != nil {
                incompleteFrames += 1
            }
            pending = nil
            pendingStartTime = nil
            framesDropped += 1
        }

        // Validate parameters
        guard totalLen > 0, totalLen <= VideoConfig.maxH264FrameSize,
              chunkCount > 0, chunkCount <= 4096,
              chunkIdx >= 0, chunkIdx < chunkCount else {
            return
        }

        // Single chunk frame - decode immediately
        if chunkCount == 1 {
            if payload.count > 0 {
                // If we need a keyframe and this isn't one, skip it
                if needsKeyframe && !isKeyframe {
                    return
                }

                decodeAndDisplay(Data(payload), isKeyframe: isKeyframe)
            }
            pending = nil
            pendingStartTime = nil
            framesReceived += 1
            return
        }

        // Multi-chunk frame - assemble
        if pending == nil || pending!.frameId != frameId || pending!.count != chunkCount || pending!.totalLen != totalLen {
            // Starting a new frame
            if pending != nil && pending!.chunks.count < pending!.count {
                incompleteFrames += 1
                framesDropped += 1
            }

            pending = Pending(frameId: frameId, width: width, height: height, totalLen: totalLen, count: chunkCount, isKeyframe: isKeyframe, chunks: [:], receivedBytes: 0)
            pendingStartTime = Date()
        }

        // Store chunk
        if pending!.chunks[chunkIdx] == nil {
            pending!.chunks[chunkIdx] = Data(payload)
            pending!.receivedBytes += payload.count
        }

        // Check if frame is complete
        if pending!.chunks.count == chunkCount {
            // If we need a keyframe and this isn't one, skip it
            if needsKeyframe && !pending!.isKeyframe {
                pending = nil
                pendingStartTime = nil
                return
            }

            assembleAndDecodeFrame()
            framesReceived += 1
        }
    }

    private func assembleAndDecodeFrame() {
        guard let p = pending else { return }

        frameBuffer.removeAll(keepingCapacity: true)
        frameBuffer.reserveCapacity(p.totalLen)

        // Assemble chunks in order
        for j in 0..<p.count {
            guard let chunk = p.chunks[j] else {
                framesDropped += 1
                pending = nil
                pendingStartTime = nil
                return
            }
            frameBuffer.append(chunk)
        }

        // Trim to expected size
        if frameBuffer.count > p.totalLen {
            frameBuffer = frameBuffer.prefix(p.totalLen)
        }

        if frameBuffer.count > 0 {
            decodeAndDisplay(Data(frameBuffer), isKeyframe: p.isKeyframe)
        }

        pending = nil
        pendingStartTime = nil
    }

    // MARK: - Decoding

    private func decodeAndDisplay(_ h264Data: Data, isKeyframe: Bool) {
        guard let model = model else { return }
        let isAutoMode = model.isAutonomousMode
        let rotation = model.cameraRotation

        decodeQueue.async { [weak self] in
            guard let self = self else { return }

            let decodeCompletion: (CVPixelBuffer?, UIImage?) -> Void = { [weak self] pixelBuffer, uiImage in
                guard let self = self else { return }

                if let img = uiImage {
                    DispatchQueue.main.async { self.model?.videoImage = img }
                    self.framesDecoded += 1
                    self.consecutiveDecodeFailures = 0

                    // Successfully decoded - we don't need a keyframe anymore
                    if isKeyframe {
                        self.needsKeyframe = false
                        self.lastKeyframeTime = Date()
                    }

                    // Process for AI if needed
                    if let buffer = pixelBuffer {
                        self.ai?.process(pixelBuffer: buffer, imageSize: img.size)
                    }
                } else {
                    self.consecutiveDecodeFailures += 1

                    // Request IDR after too many failures
                    if self.consecutiveDecodeFailures >= self.maxDecodeFailuresBeforeIDRRequest {
                        self.requestIDRFrame()
                    }
                }
            }

            if isAutoMode {
                self.hardwareDecoder.decode(h264Data, isKeyframe: isKeyframe, rotationDegrees: rotation, completion: decodeCompletion)
            } else {
                self.hardwareDecoder.decodeForDisplay(h264Data, isKeyframe: isKeyframe, rotationDegrees: rotation) { uiImage in
                    decodeCompletion(nil, uiImage)
                }
            }
        }
    }

    // MARK: - IDR Request (Solution 5)

    private var lastIDRRequestTime: Date? = nil
    private let minIDRRequestInterval: TimeInterval = 2.0  // Don't spam IDR requests

    private func requestIDRFrame() {
        // Rate limit IDR requests
        if let lastRequest = lastIDRRequestTime,
           Date().timeIntervalSince(lastRequest) < minIDRRequestInterval {
            return
        }

        lastIDRRequestTime = Date()
        needsKeyframe = true
        consecutiveDecodeFailures = 0
        idrRequestsSent += 1

        // Reset the decoder to clear any corrupted state
        hardwareDecoder.reset()

        // Send IDR request to P4 via control channel
        sendIDRRequest()
    }

    private func sendIDRRequest() {
        guard let addr = p4Address else {
            return
        }

        // Create or reuse control connection
        if controlConnection == nil || controlConnection?.state != .ready {
            let host = NWEndpoint.Host(addr)
            let endpoint = NWEndpoint.hostPort(host: host, port: controlPort)

            controlConnection = NWConnection(to: endpoint, using: .udp)
            controlConnection?.start(queue: queue)
        }

        // Build IDR request packet
        // Format: "IDR\0" (4 bytes magic) - simple protocol
        var packet = Data([0x49, 0x44, 0x52, 0x00])  // "IDR\0"

        controlConnection?.send(content: packet, completion: .contentProcessed { error in
            _ = error
        })
    }

    /// Call this to manually request a keyframe (e.g., on app resume)
    public func forceKeyframeRequest() {
        needsKeyframe = true
        requestIDRFrame()
    }

    // MARK: - Stats

    public func getStats() -> (received: UInt64, decoded: UInt64, dropped: UInt64) {
        (framesReceived, framesDecoded, framesDropped)
    }
}
