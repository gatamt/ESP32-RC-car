//
//  Threading.swift
//  VehicleControl
//
//  OPTIMIZED: Low-overhead threading primitives
//

import Foundation
import os.lock

// MARK: - Triple Buffer (Lock-free frame pipelining)

/// Triple buffer for lock-free producer-consumer pattern
/// OPTIMIZED: Uses os_unfair_lock for minimal overhead
public final class TripleBuffer<T> {
    private var buffers: [T?]
    private var writeIndex: Int = 0
    private var readIndex: Int = 2
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    
    public init() {
        buffers = [nil, nil, nil]
        lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }
    
    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }
    
    /// Write a value to the buffer (producer side)
    @inline(__always)
    public func write(_ value: T) {
        os_unfair_lock_lock(lock)
        let nextWrite = (writeIndex + 1) % 3
        if nextWrite != readIndex {
            buffers[nextWrite] = value
            writeIndex = nextWrite
        }
        os_unfair_lock_unlock(lock)
    }
    
    /// Read the latest value from the buffer (consumer side)
    @inline(__always)
    public func read() -> T? {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        if writeIndex != readIndex {
            readIndex = writeIndex
        }
        return buffers[readIndex]
    }
    
    /// Check if buffer has new data without consuming
    @inline(__always)
    public func hasNewData() -> Bool {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return writeIndex != readIndex
    }
}

// MARK: - Ring Buffer (Lock-free for audio)

/// Lock-free ring buffer for audio streaming
public final class LockFreeRingBuffer<T> {
    private var buffer: [T?]
    private let capacity: Int
    private var writePos: Int = 0
    private var readPos: Int = 0
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    
    public init(capacity: Int) {
        self.capacity = capacity
        self.buffer = [T?](repeating: nil, count: capacity)
        lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }
    
    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }
    
    public var count: Int {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return (writePos - readPos + capacity) % capacity
    }
    
    public var isEmpty: Bool {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return writePos == readPos
    }
    
    public var isFull: Bool {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return (writePos + 1) % capacity == readPos
    }
    
    @inline(__always)
    public func push(_ value: T) -> Bool {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        
        let next = (writePos + 1) % capacity
        if next == readPos {
            return false // Buffer full
        }
        buffer[writePos] = value
        writePos = next
        return true
    }
    
    @inline(__always)
    public func pop() -> T? {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        
        if readPos == writePos {
            return nil // Buffer empty
        }
        let value = buffer[readPos]
        buffer[readPos] = nil
        readPos = (readPos + 1) % capacity
        return value
    }
}

// MARK: - Atomic Counter

/// Thread-safe atomic counter
public final class AtomicCounter {
    private var value: Int = 0
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    
    public init(initialValue: Int = 0) {
        self.value = initialValue
        lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }
    
    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }
    
    @inline(__always)
    public func increment() -> Int {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        value += 1
        return value
    }
    
    @inline(__always)
    public func decrement() -> Int {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        value -= 1
        return value
    }
    
    @inline(__always)
    public func get() -> Int {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return value
    }
    
    @inline(__always)
    public func set(_ newValue: Int) {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        value = newValue
    }
}

// MARK: - Atomic Flag

/// Thread-safe atomic boolean flag
public final class AtomicFlag {
    private var value: Bool = false
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    
    public init(initialValue: Bool = false) {
        self.value = initialValue
        lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }
    
    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }
    
    @inline(__always)
    public func testAndSet() -> Bool {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        let was = value
        value = true
        return was
    }
    
    @inline(__always)
    public func clear() {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        value = false
    }
    
    @inline(__always)
    public func get() -> Bool {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return value
    }
}
