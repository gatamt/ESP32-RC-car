//
//  VehicleControl.swift
//  VehicleControl
//
//  Umbrella header - import this to get all modules
//
//  This file serves as documentation for the module structure.
//  In Xcode, you don't need to import this file explicitly as
//  all Swift files in the same target can see each other.
//

/*
 
 MODULE STRUCTURE:
 =================
 
 VehicleControl/
 ├── VehicleControlApp.swift     - App entry point (@main)
 ├── ContentView.swift           - Main UI composition
 ├── VehicleControl.swift        - This file (documentation)
 │
 ├── Core/
 │   ├── Constants.swift         - Global constants, colors, config
 │   └── NetHolder.swift         - Central manager holder
 │
 ├── Models/
 │   ├── DataModels.swift        - Payload, Telemetry, AIDetection
 │   └── AppModel.swift          - Central @Published state
 │
 ├── Utilities/
 │   ├── CRC16.swift             - CRC16-CCITT with lookup table
 │   ├── ByteHelpers.swift       - Zero-copy byte operations
 │   └── Threading.swift         - TripleBuffer, AtomicCounter
 │
 ├── AI/
 │   ├── SIMDKalmanFilter.swift  - SIMD-optimized Kalman filter
 │   ├── PIDController.swift     - Adaptive PID controller
 │   └── AIVisionManager.swift   - Vision framework integration
 │
 ├── Video/
 │   ├── HardwareJPEGDecoder.swift - VideoToolbox decoder
 │   └── UDPVideoClient.swift    - Video streaming client
 │
 ├── Audio/
 │   └── UDPAudioClient.swift    - Low-latency audio client
 │
 ├── Networking/
 │   ├── ControlUDPManager.swift - Control & telemetry UDP
 │   └── ControllerBridge.swift  - Game controller bridge
 │
 ├── UI/
 │   ├── CyberText.swift         - Custom font modifiers
 │   ├── AIOverlayView.swift     - AI detection overlay
 │   └── VideoViews.swift        - Video preview/fullscreen
 │
 └── HUD/
     ├── Shapes.swift            - Custom shapes (TaperBar, etc.)
     └── HUDView.swift           - Main HUD rendering

 
 OPTIMIZATIONS IMPLEMENTED:
 ==========================
 
 1. VIDEO PIPELINE
    - Hardware JPEG decoding via ImageIO/VideoToolbox
    - CVPixelBufferPool for buffer reuse
    - Metal-compatible pixel buffers
    - Zero-copy fast path for display-only mode
    - Triple buffer frame pipelining
 
 2. AI DETECTION
    - VNSequenceRequestHandler (reuses internal state)
    - Region of Interest tracking for faster inference
    - SIMD4-based Kalman filter (4x faster)
    - Adaptive frame skipping based on performance
    - Pre-warmed Vision framework
    - Neural Engine optimization
    - Custom CoreML model support
 
 3. SWIFTUI RENDERING
    - EquatableView for minimal redraws
    - compositingGroup() + drawingGroup() for GPU
    - 120 Hz UI smoothing with decay
    - Separated sub-views for granular invalidation
 
 4. THREADING
    - os_unfair_lock for minimal overhead
    - Lock-free triple buffer
    - Atomic counters and flags
    - Cached mach_timebase_info
    - Dedicated queues with proper QoS
 
 5. MEMORY
    - Pre-allocated frame buffers
    - Audio buffer pooling
    - Int-based detection IDs (not UUID)
    - Zero-copy byte parsing
 
 6. NETWORKING
    - CRC16 lookup table
    - 200 Hz control loop
    - UDP connection pooling
    - Zero-copy telemetry parsing
 
 */

// This file intentionally left mostly empty.
// It serves as documentation for the module structure.
