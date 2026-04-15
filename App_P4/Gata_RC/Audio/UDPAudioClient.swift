//
//  UDPAudioClient.swift
//  VehicleControl
//
//  Low-latency UDP audio streaming client
//

import Network
import AVFoundation
import Foundation
import Darwin

// MARK: - UDP Audio Client

/// Low-latency UDP audio streaming client
public final class UDPAudioClient: NSObject {
    
    // MARK: - Properties
    
    private let port: NWEndpoint.Port
    private let queue = DispatchQueue(label: "udp.audio.queue", qos: .userInteractive)
    private var udpSocket: Int32 = -1
    private var keepAliveTimer: Timer?
    private var registrationConn: NWConnection?
    private var registrationTimer: DispatchSourceTimer?
    private var xiaoHost: NWEndpoint.Host? = nil
    
    private weak var model: AppModel?
    
    // Audio engine
    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var audioFormat: AVAudioFormat?
    
    // Buffer management
    private var scheduledBufferCount: Int = 0
    private var bufferPool: [AVAudioPCMBuffer] = []
    private let bufferLock = NSLock()
    
    // MARK: - Initialization
    
    public init(model: AppModel) {
        self.port = NWEndpoint.Port(rawValue: NetworkPorts.audio)!
        self.model = model
        super.init()
        setupLowLatencyAudioSession()
        setupAudio()
        startRawSocket()
        startKeepAlive()
        startRegistrationToP4()
    }
    
    deinit {
        keepAliveTimer?.invalidate()
        registrationTimer?.cancel()
        registrationConn?.cancel()
        audioEngine?.stop()
        if udpSocket >= 0 { close(udpSocket) }
    }
    
    // MARK: - Audio Setup
    
    private func setupLowLatencyAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setPreferredIOBufferDuration(AudioConfig.bufferDuration)
            try session.setActive(true)
        } catch {
        }
    }
    
    private func setupAudio() {
        audioEngine = AVAudioEngine()
        playerNode = AVAudioPlayerNode()
        audioFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: AudioConfig.sampleRate,
            channels: AudioConfig.channels,
            interleaved: true
        )
        
        guard let engine = audioEngine,
              let player = playerNode,
              let format = audioFormat else { return }
        
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        
        do {
            try engine.start()
            player.play()
            DispatchQueue.main.async {
                self.model?.audioActive = true
            }
        } catch {
        }
        
        preallocateBuffers()
    }
    
    private func preallocateBuffers() {
        guard let format = audioFormat else { return }
        
        bufferLock.lock()
        defer { bufferLock.unlock() }
        
        for _ in 0..<AudioConfig.bufferPoolSize {
            if let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024) {
                bufferPool.append(buffer)
            }
        }
    }
    
    // MARK: - Buffer Pool
    
    private func getBuffer(capacity: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        
        if let idx = bufferPool.firstIndex(where: { $0.frameCapacity >= capacity }) {
            return bufferPool.remove(at: idx)
        }
        
        guard let format = audioFormat else { return nil }
        return AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity)
    }
    
    private func returnBuffer(_ buffer: AVAudioPCMBuffer) {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        
        if bufferPool.count < AudioConfig.bufferPoolSize {
            bufferPool.append(buffer)
        }
    }
    
    // MARK: - Network
    
    private func startRawSocket() {
        udpSocket = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        if udpSocket < 0 {
            return
        }

        var flags = fcntl(udpSocket, F_GETFL, 0)
        _ = fcntl(udpSocket, F_SETFL, flags | O_NONBLOCK)

        var reuse: Int32 = 1
        setsockopt(udpSocket, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse)))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port.rawValue).bigEndian
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
                var ipBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                inet_ntop(AF_INET, &addr.sin_addr, &ipBuf, socklen_t(INET_ADDRSTRLEN))
                self.xiaoHost = NWEndpoint.Host(String(cString: ipBuf))

                let data = Data(buffer.prefix(Int(n)))
                self.handleAudioDatagram(data)
            } else {
                usleep(1_000)
            }
            self.readLoop()
        }
    }
    
    private func startKeepAlive() {
        keepAliveTimer?.invalidate()
        keepAliveTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.sendAUD0()
        }
        sendAUD0()
    }
    
    private func sendAUD0() {
        if udpSocket >= 0 {
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(port.rawValue).bigEndian
            addr.sin_addr.s_addr = inet_addr(P4Host.ip)
            let payload: [UInt8] = [0x41, 0x55, 0x44, 0x30] // "AUD0"
            payload.withUnsafeBytes { ptr in
                withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        _ = sendto(udpSocket, ptr.baseAddress, ptr.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }
        if let reg = registrationConn {
            reg.send(content: Data([0x41, 0x55, 0x44, 0x30]), completion: .contentProcessed { _ in })
        }
    }
    
    private func startRegistrationToP4() {
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
            conn.send(content: Data([0x41, 0x55, 0x44, 0x30]), completion: .contentProcessed { _ in })
            if sends >= 10 {
                self.registrationTimer?.cancel()
            }
        }
        registrationTimer = timer
        timer.resume()
    }
    
    // MARK: - Audio Processing
    
    private func handleAudioDatagram(_ data: Data) {
        guard data.count >= 12 else { return }
        
        let bytes = [UInt8](data)
        guard bytes[0] == 0x41, bytes[1] == 0x55,
              bytes[2] == 0x44, bytes[3] == 0x31 else { return }
        
        let samplesData = data.dropFirst(12)
        guard samplesData.count > 0 else { return }
        
        playAudioSamples(Array(samplesData))
    }
    
    private func playAudioSamples(_ samples: [UInt8]) {
        guard let player = playerNode, let _ = audioFormat else { return }
        
        bufferLock.lock()
        let currentCount = scheduledBufferCount
        bufferLock.unlock()
        
        if currentCount >= AudioConfig.maxScheduledBuffers {
            return
        }
        
        let sampleCount = samples.count / 2
        guard let buffer = getBuffer(capacity: AVAudioFrameCount(sampleCount)) else { return }
        
        buffer.frameLength = AVAudioFrameCount(sampleCount)
        
        samples.withUnsafeBytes { ptr in
            if let basePtr = ptr.baseAddress {
                memcpy(buffer.int16ChannelData![0], basePtr, samples.count)
            }
        }
        
        bufferLock.lock()
        scheduledBufferCount += 1
        bufferLock.unlock()
        
        player.scheduleBuffer(buffer) { [weak self] in
            guard let self = self else { return }
            self.bufferLock.lock()
            self.scheduledBufferCount -= 1
            self.bufferLock.unlock()
            self.returnBuffer(buffer)
        }
    }
}
