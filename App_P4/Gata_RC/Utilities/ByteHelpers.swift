//
//  ByteHelpers.swift
//  VehicleControl
//
//  OPTIMIZED: Inline byte conversion helpers with zero-copy support
//

import Foundation

// MARK: - Little Endian Byte Extensions

extension UInt16 {
    /// Convert to little-endian byte array
    @inline(__always)
    public var leBytes: [UInt8] {
        [UInt8(self & 0xFF), UInt8((self >> 8) & 0xFF)]
    }
    
    /// Read from little-endian bytes (zero-copy)
    @inline(__always)
    public static func fromLE(_ bytes: UnsafeRawBufferPointer, offset: Int) -> UInt16 {
        let ptr = bytes.baseAddress!.advanced(by: offset)
        return ptr.loadUnaligned(as: UInt16.self)
    }
}

extension UInt32 {
    /// Convert to little-endian byte array
    @inline(__always)
    public var leBytes: [UInt8] {
        [UInt8(self & 0xFF),
         UInt8((self >> 8) & 0xFF),
         UInt8((self >> 16) & 0xFF),
         UInt8((self >> 24) & 0xFF)]
    }
    
    /// Read from little-endian bytes (zero-copy)
    @inline(__always)
    public static func fromLE(_ bytes: UnsafeRawBufferPointer, offset: Int) -> UInt32 {
        let ptr = bytes.baseAddress!.advanced(by: offset)
        return ptr.loadUnaligned(as: UInt32.self)
    }
}

extension Int16 {
    /// Convert to little-endian byte array
    @inline(__always)
    public var leBytes: [UInt8] {
        let u = UInt16(bitPattern: self)
        return [UInt8(u & 0xFF), UInt8((u >> 8) & 0xFF)]
    }
    
    /// Read from little-endian bytes (zero-copy)
    @inline(__always)
    public static func fromLE(_ bytes: UnsafeRawBufferPointer, offset: Int) -> Int16 {
        let ptr = bytes.baseAddress!.advanced(by: offset)
        return ptr.loadUnaligned(as: Int16.self)
    }
}

extension Float {
    /// Read from little-endian bytes (zero-copy)
    @inline(__always)
    public static func fromLE(_ bytes: UnsafeRawBufferPointer, offset: Int) -> Float {
        let ptr = bytes.baseAddress!.advanced(by: offset)
        return ptr.loadUnaligned(as: Float.self)
    }
}

// MARK: - Data Extensions

extension Data {
    /// Zero-copy access to underlying bytes
    @inline(__always)
    public func withUnsafeUInt8Pointer<R>(_ body: (UnsafeBufferPointer<UInt8>) -> R) -> R {
        return self.withUnsafeBytes { rawBuffer in
            let buffer = UnsafeBufferPointer(
                start: rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                count: rawBuffer.count
            )
            return body(buffer)
        }
    }
    
    /// Read UInt16 at offset (little-endian)
    @inline(__always)
    public func readUInt16LE(at offset: Int) -> UInt16 {
        return self.withUnsafeBytes { ptr in
            UInt16.fromLE(ptr, offset: offset)
        }
    }
    
    /// Read UInt32 at offset (little-endian)
    @inline(__always)
    public func readUInt32LE(at offset: Int) -> UInt32 {
        return self.withUnsafeBytes { ptr in
            UInt32.fromLE(ptr, offset: offset)
        }
    }
    
    /// Read Float at offset (little-endian)
    @inline(__always)
    public func readFloatLE(at offset: Int) -> Float {
        return self.withUnsafeBytes { ptr in
            Float.fromLE(ptr, offset: offset)
        }
    }
}

// MARK: - Mach Time Helpers

/// Cached timebase info for mach_absolute_time conversions
public enum MachTime {
    private static var timebaseInfo: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()
    
    /// Convert mach_absolute_time ticks to nanoseconds
    @inline(__always)
    public static func toNanoseconds(_ ticks: UInt64) -> UInt64 {
        return ticks * UInt64(timebaseInfo.numer) / UInt64(timebaseInfo.denom)
    }
    
    /// Convert mach_absolute_time ticks to milliseconds
    @inline(__always)
    public static func toMilliseconds(_ ticks: UInt64) -> Double {
        return Double(toNanoseconds(ticks)) / 1_000_000.0
    }
    
    /// Convert mach_absolute_time ticks to seconds
    @inline(__always)
    public static func toSeconds(_ ticks: UInt64) -> Float {
        return Float(toNanoseconds(ticks)) / 1_000_000_000.0
    }
    
    /// Get elapsed time in seconds between two mach_absolute_time values
    @inline(__always)
    public static func elapsedSeconds(from start: UInt64, to end: UInt64) -> Float {
        return toSeconds(end - start)
    }
}
