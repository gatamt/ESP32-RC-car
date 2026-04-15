//
//  HardwareH264Decoder.swift
//  GATA_RC_P4
//
//  Hardware-accelerated H.264 decoding using VideoToolbox
//  Supports dynamic resolution from ESP32-P4 stream
//

import UIKit
import CoreVideo
import VideoToolbox
import AVFoundation

// MARK: - Hardware H.264 Decoder

public final class HardwareH264Decoder {
    private var decompressionSession: VTDecompressionSession?
    private var formatDescription: CMFormatDescription?
    private var spsData: Data?
    private var ppsData: Data?
    private var sessionConfigured = false
    private let decodeQueue = DispatchQueue(label: "h264.decode.queue", qos: .userInteractive)
    private var framesDecoded: UInt64 = 0
    private var framesDropped: UInt64 = 0

    // Track current resolution for dynamic changes
    private var currentWidth: Int = 0
    private var currentHeight: Int = 0

    public init() {}

    deinit { destroySession() }

    public func decode(_ nalData: Data, isKeyframe: Bool, rotationDegrees: Double = 0,
                       completion: @escaping (CVPixelBuffer?, UIImage?) -> Void) {
        decodeQueue.async { [weak self] in
            guard let self = self else { completion(nil, nil); return }

            let nalUnits = self.parseNALUnits(nalData)

            // Extract SPS/PPS from keyframes
            for nal in nalUnits {
                guard !nal.isEmpty else { continue }
                let type = nal.first! & 0x1F
                if type == 7 {
                    // SPS - contains resolution info
                    self.spsData = nal
                }
                else if type == 8 {
                    // PPS
                    self.ppsData = nal
                }
            }

            // Create/recreate decoder session on keyframe with SPS/PPS
            if isKeyframe, let sps = self.spsData, let pps = self.ppsData {
                self.createFormatDescription(sps: sps, pps: pps)
            }

            // Find and decode video NAL unit (IDR or non-IDR slice)
            for nal in nalUnits {
                guard !nal.isEmpty else { continue }
                let type = nal.first! & 0x1F
                if type == 5 || type == 1 {  // IDR or non-IDR slice
                    self.decodeNALUnit(nal, rotationDegrees: rotationDegrees, completion: completion)
                    return
                }
            }

            // No decodable NAL found
            self.framesDropped += 1
            completion(nil, nil)
        }
    }

    public func decodeForDisplay(_ nalData: Data, isKeyframe: Bool, rotationDegrees: Double = 0,
                                  completion: @escaping (UIImage?) -> Void) {
        decode(nalData, isKeyframe: isKeyframe, rotationDegrees: rotationDegrees) { _, image in
            completion(image)
        }
    }

    public func reset() {
        decodeQueue.async { [weak self] in
            self?.destroySession()
            self?.spsData = nil
            self?.ppsData = nil
            self?.sessionConfigured = false
            self?.currentWidth = 0
            self?.currentHeight = 0
        }
    }

    // MARK: - NAL Unit Parsing

    private func parseNALUnits(_ data: Data) -> [Data] {
        var nalUnits: [Data] = []
        var currentStart: Int?

        data.withUnsafeBytes { ptr in
            guard let basePtr = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            let count = ptr.count
            var i = 0

            while i < count - 3 {
                // Look for start code: 00 00 01 or 00 00 00 01
                if basePtr[i] == 0x00 && basePtr[i+1] == 0x00 {
                    var startCodeLen = 0
                    if basePtr[i+2] == 0x01 {
                        startCodeLen = 3
                    } else if i < count - 4 && basePtr[i+2] == 0x00 && basePtr[i+3] == 0x01 {
                        startCodeLen = 4
                    }

                    if startCodeLen > 0 {
                        // Save previous NAL unit
                        if let start = currentStart {
                            let nalData = Data(bytes: basePtr.advanced(by: start), count: i - start)
                            if !nalData.isEmpty {
                                nalUnits.append(nalData)
                            }
                        }
                        currentStart = i + startCodeLen
                        i += startCodeLen
                        continue
                    }
                }
                i += 1
            }

            // Save last NAL unit
            if let start = currentStart, start < count {
                let nalData = Data(bytes: basePtr.advanced(by: start), count: count - start)
                if !nalData.isEmpty {
                    nalUnits.append(nalData)
                }
            }
        }

        // If no start codes found, treat entire data as single NAL
        if nalUnits.isEmpty && !data.isEmpty {
            nalUnits.append(data)
        }

        return nalUnits
    }

    // MARK: - Session Management

    private func createFormatDescription(sps: Data, pps: Data) {
        var formatDesc: CMFormatDescription?

        sps.withUnsafeBytes { spsPtr in
            pps.withUnsafeBytes { ppsPtr in
                guard let spsBase = spsPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let ppsBase = ppsPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return
                }

                var pointers: [UnsafePointer<UInt8>] = [spsBase, ppsBase]
                var sizes: [Int] = [sps.count, pps.count]

                let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: &pointers,
                    parameterSetSizes: &sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &formatDesc
                )

                if status == noErr, let desc = formatDesc {
                    // Get dimensions from format description
                    let dimensions = CMVideoFormatDescriptionGetDimensions(desc)
                    let newWidth = Int(dimensions.width)
                    let newHeight = Int(dimensions.height)

                    // Check if resolution changed
                    let resolutionChanged = (newWidth != self.currentWidth || newHeight != self.currentHeight)

                    if resolutionChanged || !self.sessionConfigured {
                        // Destroy old session if exists
                        self.destroySession()

                        self.formatDescription = desc
                        self.currentWidth = newWidth
                        self.currentHeight = newHeight

                        self.createDecompressionSession(formatDescription: desc, width: newWidth, height: newHeight)
                    }
                }
            }
        }
    }

    private func createDecompressionSession(formatDescription: CMFormatDescription, width: Int, height: Int) {
        let decoderSpecification: [String: Any] = [
            kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder as String: true
        ]

        // Request BGRA output for easy UIImage conversion
        let destinationAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]

        var outputCallback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: nil,
            decompressionOutputRefCon: nil
        )

        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: decoderSpecification as CFDictionary,
            imageBufferAttributes: destinationAttributes as CFDictionary,
            outputCallback: &outputCallback,
            decompressionSessionOut: &decompressionSession
        )

        if status == noErr {
            sessionConfigured = true
        } else {
            sessionConfigured = false
        }
    }

    private func destroySession() {
        if let session = decompressionSession {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
            decompressionSession = nil
        }
        formatDescription = nil
        sessionConfigured = false
    }

    // MARK: - Frame Decoding

    private func decodeNALUnit(_ nalUnit: Data, rotationDegrees: Double,
                                completion: @escaping (CVPixelBuffer?, UIImage?) -> Void) {
        guard sessionConfigured,
              let session = decompressionSession,
              let formatDesc = formatDescription else {
            completion(nil, nil)
            return
        }

        // Convert Annex-B to AVCC format (replace start code with length)
        var nalWithLength = Data(count: 4 + nalUnit.count)
        let length = UInt32(nalUnit.count).bigEndian
        nalWithLength.replaceSubrange(0..<4, with: withUnsafeBytes(of: length) { Data($0) })
        nalWithLength.replaceSubrange(4..<nalWithLength.count, with: nalUnit)

        // Create block buffer
        var blockBuffer: CMBlockBuffer?
        let dataLength = nalWithLength.count

        nalWithLength.withUnsafeBytes { ptr in
            guard let basePtr = ptr.baseAddress else { return }
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: UnsafeMutableRawPointer(mutating: basePtr),
                blockLength: dataLength,
                blockAllocator: kCFAllocatorNull,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: dataLength,
                flags: 0,
                blockBufferOut: &blockBuffer
            )
        }

        guard let block = blockBuffer else {
            completion(nil, nil)
            return
        }

        // Create sample buffer
        var sampleBuffer: CMSampleBuffer?
        var sampleSize = dataLength
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: Int32(VideoConfig.targetFPS)),
            presentationTimeStamp: CMTime(value: CMTimeValue(framesDecoded), timescale: Int32(VideoConfig.targetFPS)),
            decodeTimeStamp: .invalid
        )

        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: formatDesc,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )

        guard sampleStatus == noErr, let sample = sampleBuffer else {
            completion(nil, nil)
            return
        }

        // Decode frame
        var outputFlags = VTDecodeInfoFlags()
        let decodeStatus = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sample,
            flags: [._EnableAsynchronousDecompression],
            infoFlagsOut: &outputFlags
        ) { [weak self] status, _, imageBuffer, _, _ in
            guard let self = self else { return }

            if status == noErr, let pixelBuffer = imageBuffer {
                self.framesDecoded += 1
                let uiImage = self.pixelBufferToUIImage(pixelBuffer, rotationDegrees: rotationDegrees)
                completion(pixelBuffer, uiImage)
            } else {
                self.framesDropped += 1
                completion(nil, nil)
            }
        }

        if decodeStatus != noErr {
            framesDropped += 1
            completion(nil, nil)
        }
    }

    // MARK: - Image Conversion

    private func pixelBufferToUIImage(_ pixelBuffer: CVPixelBuffer, rotationDegrees: Double) -> UIImage? {
        // Lock the pixel buffer to access raw pixels
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard CVPixelBufferGetBaseAddress(pixelBuffer) != nil else {
            return nil
        }

        // Use CIImage for proper color space conversion from VideoToolbox output
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let ciContext = CIContext(options: [.useSoftwareRenderer: false])

        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            return nil
        }

        // Map rotation degrees to UIImage.Orientation
        // UIImage orientation handles rotation efficiently without manual CGContext drawing
        let orientation: UIImage.Orientation
        let normalizedDegrees = Int(rotationDegrees.truncatingRemainder(dividingBy: 360))

        switch normalizedDegrees {
        case 90, -270:
            orientation = .rightMirrored  // 90° clockwise + horizontal flip
        case 180, -180:
            orientation = .downMirrored   // 180° + horizontal flip
        case 270, -90:
            orientation = .leftMirrored   // 270° clockwise (90° CCW) + horizontal flip
        default:
            orientation = .upMirrored     // 0° + horizontal flip
        }

        let result = UIImage(cgImage: cgImage, scale: 1.0, orientation: orientation)

        return result
    }

    // MARK: - Statistics

    public func getStats() -> (decoded: UInt64, dropped: UInt64) {
        return (framesDecoded, framesDropped)
    }

    public func getResolution() -> (width: Int, height: Int) {
        return (currentWidth, currentHeight)
    }
}
