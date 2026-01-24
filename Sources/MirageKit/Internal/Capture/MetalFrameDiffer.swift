//
//  MetalFrameDiffer.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/9/26.
//

import Foundation
import Metal
import CoreVideo

#if os(macOS)

/// Metal-based frame differencing to work around ScreenCaptureKit's broken dirty rect reporting
/// on virtual displays. SCK reports 100% dirty for all frames on virtual displays, preventing
/// tile encoding optimization. This class accurately detects changed regions without blocking.
///
/// Key design:
/// 1. Uses pipelined async GPU operations - never blocks on GPU completion
/// 2. Copies frames to persistent MTLTextures to avoid SCK's CVPixelBuffer reuse
/// 3. Returns previous frame's result while computing current frame's diff
/// 4. Triple-buffering: current, previous, and pending textures
final class MetalFrameDiffer: @unchecked Sendable {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let computePipeline: MTLComputePipelineState

    /// Triple buffer textures for pipelined async operation
    /// - texture0, texture1, texture2 rotate through roles
    private var textures: [MTLTexture] = []

    /// Index of texture receiving current frame
    private var currentTextureIndex: Int = 0

    /// Buffer to store per-block dirty flags (double-buffered for async)
    private var dirtyFlagsBuffers: [MTLBuffer] = []
    private var currentBufferIndex: Int = 0

    /// Dimensions of current textures
    private var textureWidth: Int = 0
    private var textureHeight: Int = 0

    /// Pending command buffer from previous frame (for async completion check)
    private var pendingCommandBuffer: MTLCommandBuffer?

    /// Cached result from pending GPU work (populated when async work completes)
    private var pendingResult: DetectionResult?

    /// Frame count since init/reset (for pipeline warmup)
    private var frameCount: Int = 0

    /// Block size for dirty detection (resolution-dependent)
    /// Smaller blocks for higher resolutions improve typing/small-change latency
    private var blockSize: Int = 128

    /// Result of dirty region detection
    struct DetectionResult {
        /// Bounding rectangle of all changed pixels (nil if no changes)
        let dirtyRect: CGRect?
        /// Individual dirty block coordinates
        let dirtyBlocks: [(x: Int, y: Int)]
        /// Percentage of frame that changed (0.0 - 100.0)
        let changePercentage: Float
        /// Detection time in milliseconds
        let detectionTimeMs: Double
    }

    init?() {
        // Get the default Metal device
        guard let device = MTLCreateSystemDefaultDevice() else {
            MirageLogger.error(.capture, "Metal device not available for frame differencing")
            return nil
        }
        self.device = device

        guard let commandQueue = device.makeCommandQueue() else {
            MirageLogger.error(.capture, "Failed to create Metal command queue")
            return nil
        }
        self.commandQueue = commandQueue

        // Create compute pipeline for frame comparison
        let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;

        // Compare two frames block by block
        // Each thread handles one block (size varies by resolution: 64-128 pixels)
        kernel void compareFrames(
            texture2d<half, access::read> currentFrame [[texture(0)]],
            texture2d<half, access::read> previousFrame [[texture(1)]],
            device atomic_uint* dirtyFlags [[buffer(0)]],
            constant uint2& textureDims [[buffer(1)]],
            constant uint& blockSize [[buffer(2)]],
            uint2 gid [[thread_position_in_grid]]
        ) {
            uint blockX = gid.x;
            uint blockY = gid.y;

            uint startX = blockX * blockSize;
            uint startY = blockY * blockSize;

            // Check if this block is within texture bounds
            if (startX >= textureDims.x || startY >= textureDims.y) {
                return;
            }

            uint endX = min(startX + blockSize, textureDims.x);
            uint endY = min(startY + blockSize, textureDims.y);

            // Sample multiple points within the block for faster detection
            // We check a 4x4 grid of sample points instead of every pixel
            uint sampleStep = max(1u, blockSize / 4);
            bool isDirty = false;

            for (uint y = startY; y < endY && !isDirty; y += sampleStep) {
                for (uint x = startX; x < endX && !isDirty; x += sampleStep) {
                    uint2 pos = uint2(x, y);
                    half4 current = currentFrame.read(pos);
                    half4 previous = previousFrame.read(pos);

                    // Check if pixels differ (threshold 0.03 ignores HEVC compression artifacts)
                    half4 diff = abs(current - previous);
                    if (diff.r > 0.03h || diff.g > 0.03h || diff.b > 0.03h) {
                        isDirty = true;
                    }
                }
            }

            // Calculate linear block index
            uint blocksPerRow = (textureDims.x + blockSize - 1) / blockSize;
            uint blockIndex = blockY * blocksPerRow + blockX;

            // Write dirty flag
            if (isDirty) {
                atomic_store_explicit(&dirtyFlags[blockIndex], 1u, memory_order_relaxed);
            }
        }
        """

        do {
            let library = try device.makeLibrary(source: shaderSource, options: nil)
            guard let function = library.makeFunction(name: "compareFrames") else {
                MirageLogger.error(.capture, "Failed to find compareFrames kernel")
                return nil
            }
            self.computePipeline = try device.makeComputePipelineState(function: function)
        } catch {
            MirageLogger.error(.capture, "Failed to create Metal compute pipeline: \(error)")
            return nil
        }

        MirageLogger.capture("Metal frame differ initialized")
    }

    /// Calculate optimal block size to target ~200 total blocks
    /// This keeps dirty percentage meaningful - small changes don't inflate to 50%+
    /// Block count between 128-256 regardless of resolution
    private static func optimalBlockSize(for width: Int, height: Int) -> Int {
        // Target ~200 tiles total (between 128 and 256)
        let targetTiles = 200

        // Calculate block size to achieve target tile count
        let area = width * height
        let tileArea = area / targetTiles
        let blockSize = Int(sqrt(Double(tileArea)))

        // Round to multiple of 32 for GPU efficiency, clamp to reasonable range
        let rounded = ((blockSize + 16) / 32) * 32
        return max(128, min(rounded, 384))  // Between 128 and 384 pixels
    }

    /// Detect dirty regions using pipelined async GPU operations.
    /// Returns result from PREVIOUS frame's comparison (one frame latency for zero blocking).
    /// Returns nil during pipeline warmup (first 2 frames) or if GPU is overloaded.
    func detectDirtyRegions(pixelBuffer: CVPixelBuffer) -> DetectionResult? {
        let startTime = CFAbsoluteTimeGetCurrent()

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        // Ensure textures exist and match dimensions
        if textureWidth != width || textureHeight != height {
            setupTextures(width: width, height: height)
        }

        guard textures.count == 3,
              dirtyFlagsBuffers.count == 2 else {
            return nil
        }

        // Get texture for current frame
        let currentTexture = textures[currentTextureIndex]

        // Copy pixel buffer to current texture
        guard copyPixelBufferToTexture(pixelBuffer, texture: currentTexture) else {
            return nil
        }

        frameCount += 1

        // Check if previous GPU work completed and read results
        var resultToReturn: DetectionResult? = nil
        if let pending = pendingCommandBuffer {
            if pending.status == .completed {
                // GPU work done - read the results
                resultToReturn = readDirtyFlagsResult(
                    bufferIndex: 1 - currentBufferIndex,  // Read from OTHER buffer
                    width: width,
                    height: height,
                    startTime: startTime
                )
                pendingCommandBuffer = nil
            } else if pending.status == .error {
                // GPU error - clear pending and continue
                MirageLogger.error(.capture, "Metal frame differ GPU error")
                pendingCommandBuffer = nil
            }
            // else: still running, return nil (GPU overloaded)
        }

        // Pipeline warmup: need at least 2 frames before we can compare
        if frameCount < 2 {
            rotateTextures()
            return nil
        }

        // Start GPU work for current frame comparison
        let previousTextureIndex = (currentTextureIndex + 2) % 3  // Two frames ago
        let previousTexture = textures[previousTextureIndex]

        // Clear dirty flags buffer for this frame
        let blocksX = (width + blockSize - 1) / blockSize
        let blocksY = (height + blockSize - 1) / blockSize
        let totalBlocks = blocksX * blocksY
        let dirtyBuffer = dirtyFlagsBuffers[currentBufferIndex]
        memset(dirtyBuffer.contents(), 0, totalBlocks * MemoryLayout<UInt32>.size)

        // Create and dispatch GPU work (non-blocking)
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            rotateTextures()
            return resultToReturn
        }

        encoder.setComputePipelineState(computePipeline)
        encoder.setTexture(currentTexture, index: 0)
        encoder.setTexture(previousTexture, index: 1)
        encoder.setBuffer(dirtyBuffer, offset: 0, index: 0)

        // Set texture dimensions
        var dims = SIMD2<UInt32>(UInt32(width), UInt32(height))
        encoder.setBytes(&dims, length: MemoryLayout<SIMD2<UInt32>>.size, index: 1)

        // Set block size
        var blockSizeValue = UInt32(blockSize)
        encoder.setBytes(&blockSizeValue, length: MemoryLayout<UInt32>.size, index: 2)

        // Dispatch one thread per block
        let threadgroupSize = MTLSize(width: 8, height: 8, depth: 1)
        let threadgroups = MTLSize(
            width: (blocksX + threadgroupSize.width - 1) / threadgroupSize.width,
            height: (blocksY + threadgroupSize.height - 1) / threadgroupSize.height,
            depth: 1
        )
        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadgroupSize)
        encoder.endEncoding()

        // Commit GPU work (non-blocking!)
        commandBuffer.commit()
        pendingCommandBuffer = commandBuffer

        // Rotate textures and buffer indices for next frame
        rotateTextures()
        currentBufferIndex = 1 - currentBufferIndex

        return resultToReturn
    }

    /// Read dirty flags from completed GPU work
    private func readDirtyFlagsResult(bufferIndex: Int, width: Int, height: Int, startTime: CFAbsoluteTime) -> DetectionResult {
        let blocksX = (width + blockSize - 1) / blockSize
        let blocksY = (height + blockSize - 1) / blockSize
        let totalBlocks = blocksX * blocksY

        let flagsPointer = dirtyFlagsBuffers[bufferIndex].contents().bindMemory(to: UInt32.self, capacity: totalBlocks)

        var dirtyBlocks: [(x: Int, y: Int)] = []
        var minX = width, maxX = 0, minY = height, maxY = 0
        var dirtyCount = 0

        for blockY in 0..<blocksY {
            for blockX in 0..<blocksX {
                let index = blockY * blocksX + blockX
                if flagsPointer[index] != 0 {
                    dirtyCount += 1
                    dirtyBlocks.append((x: blockX * blockSize, y: blockY * blockSize))

                    let pixelX = blockX * blockSize
                    let pixelY = blockY * blockSize
                    minX = min(minX, pixelX)
                    maxX = max(maxX, min(pixelX + blockSize, width))
                    minY = min(minY, pixelY)
                    maxY = max(maxY, min(pixelY + blockSize, height))
                }
            }
        }

        let detectionTime = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        let changePercentage = Float(dirtyCount) / Float(totalBlocks) * 100.0

        if dirtyCount == 0 {
            return DetectionResult(
                dirtyRect: nil,
                dirtyBlocks: [],
                changePercentage: 0,
                detectionTimeMs: detectionTime
            )
        }

        let dirtyRect = CGRect(
            x: minX,
            y: minY,
            width: maxX - minX,
            height: maxY - minY
        )

        return DetectionResult(
            dirtyRect: dirtyRect,
            dirtyBlocks: dirtyBlocks,
            changePercentage: changePercentage,
            detectionTimeMs: detectionTime
        )
    }

    /// Rotate texture indices for triple-buffering
    private func rotateTextures() {
        currentTextureIndex = (currentTextureIndex + 1) % 3
    }

    private func setupTextures(width: Int, height: Int) {
        // Calculate optimal block size for this resolution
        blockSize = Self.optimalBlockSize(for: width, height: height)

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .shared

        // Create triple-buffered textures
        textures = []
        for _ in 0..<3 {
            if let texture = device.makeTexture(descriptor: descriptor) {
                textures.append(texture)
            }
        }
        currentTextureIndex = 0

        // Create double-buffered dirty flags
        let blocksX = (width + blockSize - 1) / blockSize
        let blocksY = (height + blockSize - 1) / blockSize
        let totalBlocks = blocksX * blocksY
        dirtyFlagsBuffers = []
        for _ in 0..<2 {
            if let buffer = device.makeBuffer(
                length: totalBlocks * MemoryLayout<UInt32>.size,
                options: .storageModeShared
            ) {
                dirtyFlagsBuffers.append(buffer)
            }
        }
        currentBufferIndex = 0

        textureWidth = width
        textureHeight = height
        frameCount = 0
        pendingCommandBuffer = nil

        MirageLogger.capture("Metal frame differ textures created: \(width)x\(height), \(totalBlocks) blocks (\(blockSize)px each)")
    }

    private func copyPixelBufferToTexture(_ pixelBuffer: CVPixelBuffer, texture: MTLTexture) -> Bool {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return false
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        texture.replace(
            region: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                              size: MTLSize(width: texture.width, height: texture.height, depth: 1)),
            mipmapLevel: 0,
            withBytes: baseAddress,
            bytesPerRow: bytesPerRow
        )

        return true
    }

    /// Reset the differ (e.g., after dimension change or fallback resume)
    func reset() {
        pendingCommandBuffer = nil
        textures = []
        dirtyFlagsBuffers = []
        textureWidth = 0
        textureHeight = 0
        frameCount = 0
        currentTextureIndex = 0
        currentBufferIndex = 0
    }
}

#endif
