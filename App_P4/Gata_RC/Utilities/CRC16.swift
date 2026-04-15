//
//  CRC16.swift
//  VehicleControl
//
//  OPTIMIZED: Lookup table based CRC16-CCITT
//

import Foundation

// MARK: - CRC16 Lookup Table (Pre-computed at compile time)
private let crc16Table: [UInt16] = {
    var table = [UInt16](repeating: 0, count: 256)
    for i in 0..<256 {
        var crc = UInt16(i) << 8
        for _ in 0..<8 {
            crc = ((crc & 0x8000) != 0) ? (crc << 1) ^ 0x1021 : (crc << 1)
        }
        table[i] = crc
    }
    return table
}()

// MARK: - CRC16 Functions

/// Compute CRC16-CCITT with lookup table optimization
/// - Parameter data: Array of bytes to compute CRC for
/// - Returns: 16-bit CRC value
@inline(__always)
public func crc16_ccitt(_ data: [UInt8]) -> UInt16 {
    var crc: UInt16 = 0xFFFF
    for byte in data {
        let index = Int((crc >> 8) ^ UInt16(byte)) & 0xFF
        crc = (crc << 8) ^ crc16Table[index]
    }
    return crc
}

/// Zero-copy CRC16 computation using UnsafeBufferPointer
/// OPTIMIZED: Avoids array copy for Data types
@inline(__always)
public func crc16_ccitt_unsafe(_ data: Data) -> UInt16 {
    return data.withUnsafeBytes { ptr -> UInt16 in
        guard let baseAddress = ptr.baseAddress else { return 0xFFFF }
        let buffer = UnsafeBufferPointer(start: baseAddress.assumingMemoryBound(to: UInt8.self), 
                                          count: ptr.count)
        var crc: UInt16 = 0xFFFF
        for byte in buffer {
            let index = Int((crc >> 8) ^ UInt16(byte)) & 0xFF
            crc = (crc << 8) ^ crc16Table[index]
        }
        return crc
    }
}

/// Compute CRC for a slice of bytes
@inline(__always)
public func crc16_ccitt_slice(_ data: ArraySlice<UInt8>) -> UInt16 {
    var crc: UInt16 = 0xFFFF
    for byte in data {
        let index = Int((crc >> 8) ^ UInt16(byte)) & 0xFF
        crc = (crc << 8) ^ crc16Table[index]
    }
    return crc
}
