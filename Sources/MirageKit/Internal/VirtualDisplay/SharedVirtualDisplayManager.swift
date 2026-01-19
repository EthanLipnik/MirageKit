import Foundation
import CoreGraphics

#if os(macOS)
import ScreenCaptureKit

/// Manages a single shared virtual display for all Mirage streams
/// Uses reference counting to create on first client and destroy when last client releases
actor SharedVirtualDisplayManager {

    // MARK: - Singleton

    static let shared = SharedVirtualDisplayManager()

    private init() {}

    // MARK: - Types

    /// Context for a managed virtual display
    struct ManagedDisplayContext: Sendable {
        let displayID: CGDirectDisplayID
        let spaceID: CGSSpaceID
        let resolution: CGSize
        let refreshRate: Double
        let colorSpace: MirageColorSpace
        let createdAt: Date

        /// Display reference (non-Sendable, managed internally)
        fileprivate let displayRef: UncheckedSendableBox<AnyObject>
    }

    /// Box for non-Sendable display reference
    final class UncheckedSendableBox<T>: @unchecked Sendable {
        let value: T
        init(_ value: T) {
            self.value = value
            MirageLogger.host("UncheckedSendableBox created for display reference")
        }
        deinit {
            MirageLogger.host("UncheckedSendableBox DEALLOCATED - display reference released")
        }
    }

    /// Information about a client using the shared display
    struct ClientDisplayInfo: Sendable {
        let resolution: CGSize
        let windowID: WindowID
        let colorSpace: MirageColorSpace
        let acquiredAt: Date
    }

    /// Consumer types that can acquire the shared display
    enum DisplayConsumer: Hashable, Sendable {
        case stream(StreamID)
        case loginDisplay
        case unlockKeyboard
        case desktopStream
    }

    /// Error types for shared display operations
    enum SharedDisplayError: Error, LocalizedError {
        case apiNotAvailable
        case creationFailed(String)
        case noActiveDisplay
        case clientNotFound(StreamID)
        case spaceNotFound(CGDirectDisplayID)
        case scDisplayNotFound(CGDirectDisplayID)

        var errorDescription: String? {
            switch self {
            case .apiNotAvailable:
                return "CGVirtualDisplay APIs are not available"
            case .creationFailed(let reason):
                return "Failed to create virtual display: \(reason)"
            case .noActiveDisplay:
                return "No active shared virtual display"
            case .clientNotFound(let streamID):
                return "No client found for stream \(streamID)"
            case .spaceNotFound(let displayID):
                return "No space found for display \(displayID)"
            case .scDisplayNotFound(let displayID):
                return "SCDisplay not found for virtual display \(displayID)"
            }
        }
    }

    // MARK: - State

    /// The single shared virtual display (nil when no clients)
    private var sharedDisplay: ManagedDisplayContext?

    /// Active consumers using the shared display
    private var activeConsumers: [DisplayConsumer: ClientDisplayInfo] = [:]

    /// Counter for display naming
    private var displayCounter: UInt32 = 0

    // MARK: - Display Acquisition

    /// Acquire the shared virtual display for a stream
    /// Creates the display if this is the first client, otherwise returns existing
    /// - Parameters:
    ///   - streamID: The stream acquiring the display
    ///   - clientResolution: The client's display resolution
    ///   - windowID: The window being streamed
    ///   - refreshRate: Refresh rate in Hz (default 60)
    /// - Returns: The managed display context
    // TODO: HDR support - add hdr: Bool parameter when EDR configuration is figured out
    func acquireDisplay(
        for streamID: StreamID,
        clientResolution: CGSize,
        windowID: WindowID,
        refreshRate: Int = 60,
        colorSpace: MirageColorSpace
    ) async throws -> ManagedDisplayContext {
        let consumer = DisplayConsumer.stream(streamID)

        // Check if this consumer already has the display
        if activeConsumers[consumer] != nil, let display = sharedDisplay {
            MirageLogger.host("Stream \(streamID) already has shared display, returning existing")
            return display
        }

        // Register this consumer
        activeConsumers[consumer] = ClientDisplayInfo(
            resolution: clientResolution,
            windowID: windowID,
            colorSpace: colorSpace,
            acquiredAt: Date()
        )

        // Calculate optimal resolution (fixed 3K)
        let optimalResolution = calculateOptimalResolution()

        MirageLogger.host("Stream \(streamID) acquiring shared display. Consumers: \(activeConsumers.count), client res: \(Int(clientResolution.width))x\(Int(clientResolution.height)) → virtual display: \(Int(optimalResolution.width))x\(Int(optimalResolution.height)), color=\(colorSpace.displayName)")

        // Create or resize display as needed
        if sharedDisplay == nil {
            // First consumer - create the display
            sharedDisplay = try await createDisplay(resolution: optimalResolution, refreshRate: refreshRate, colorSpace: colorSpace)
        } else if sharedDisplay?.colorSpace != colorSpace {
            MirageLogger.host("Recreating shared display for color space change (\(sharedDisplay?.colorSpace.displayName ?? "Unknown") → \(colorSpace.displayName))")
            sharedDisplay = try await recreateDisplay(newResolution: optimalResolution, refreshRate: refreshRate, colorSpace: colorSpace)
        } else if needsResize(currentResolution: sharedDisplay!.resolution, targetResolution: optimalResolution) {
            // Consumer needs larger display - recreate
            MirageLogger.host("Resizing shared display from \(Int(sharedDisplay!.resolution.width))x\(Int(sharedDisplay!.resolution.height)) to \(Int(optimalResolution.width))x\(Int(optimalResolution.height))")
            sharedDisplay = try await recreateDisplay(newResolution: optimalResolution, refreshRate: refreshRate, colorSpace: colorSpace)
        }

        guard let display = sharedDisplay else {
            throw SharedDisplayError.noActiveDisplay
        }

        return display
    }

    /// Release the shared display for a stream
    /// Destroys the display if this was the last consumer
    /// - Parameter streamID: The stream releasing the display
    func releaseDisplay(for streamID: StreamID) async {
        let consumer = DisplayConsumer.stream(streamID)
        guard activeConsumers.removeValue(forKey: consumer) != nil else {
            MirageLogger.host("Stream \(streamID) was not using shared display")
            return
        }

        MirageLogger.host("Stream \(streamID) released shared display. Remaining consumers: \(activeConsumers.count)")

        if activeConsumers.isEmpty {
            // Last consumer - destroy the display
            await destroyDisplay()
        }
        // Note: We don't downsize when consumers leave to avoid disruption
        // The display will be destroyed when all consumers leave
    }

    // MARK: - Consumer-Based Acquisition (for non-stream consumers)

    /// Acquire the shared virtual display for a non-stream purpose (login display, unlock, desktop stream)
    /// Creates the display if this is the first consumer, otherwise returns existing
    /// - Parameters:
    ///   - consumer: The consumer type acquiring the display
    ///   - resolution: Optional resolution for the display (used by desktop streaming, capped at 5K)
    ///   - refreshRate: Refresh rate in Hz (default 60, use 120 for high refresh rate clients)
    /// - Returns: The managed display context
    // TODO: HDR support - add hdr: Bool parameter when EDR configuration is figured out
    func acquireDisplayForConsumer(
        _ consumer: DisplayConsumer,
        resolution: CGSize? = nil,
        refreshRate: Int = 60,
        colorSpace: MirageColorSpace = .displayP3
    ) async throws -> ManagedDisplayContext {
        // Use provided resolution or fall back to default
        let targetResolution = resolution ?? CGSize(width: 2880, height: 1800)

        // Check if this consumer already has the display
        if activeConsumers[consumer] != nil, let display = sharedDisplay {
            MirageLogger.host("\(consumer) already has shared display, returning existing")
            return display
        }

        // Register this consumer with the target resolution
        activeConsumers[consumer] = ClientDisplayInfo(
            resolution: targetResolution,
            windowID: 0,
            colorSpace: colorSpace,
            acquiredAt: Date()
        )

        MirageLogger.host("\(consumer) acquiring shared display at \(Int(targetResolution.width))x\(Int(targetResolution.height))@\(refreshRate)Hz, color=\(colorSpace.displayName). Consumers: \(activeConsumers.count)")

        // Create display if needed, or resize if resolution differs
        if sharedDisplay == nil {
            sharedDisplay = try await createDisplay(resolution: targetResolution, refreshRate: refreshRate, colorSpace: colorSpace)
        } else if sharedDisplay?.colorSpace != colorSpace {
            MirageLogger.host("Recreating shared display for color space change (\(sharedDisplay?.colorSpace.displayName ?? "Unknown") → \(colorSpace.displayName))")
            sharedDisplay = try await recreateDisplay(newResolution: targetResolution, refreshRate: refreshRate, colorSpace: colorSpace)
        } else if needsResize(currentResolution: sharedDisplay!.resolution, targetResolution: targetResolution) {
            MirageLogger.host("Resizing shared display from \(Int(sharedDisplay!.resolution.width))x\(Int(sharedDisplay!.resolution.height)) to \(Int(targetResolution.width))x\(Int(targetResolution.height))")
            sharedDisplay = try await recreateDisplay(newResolution: targetResolution, refreshRate: refreshRate, colorSpace: colorSpace)
        }

        guard let display = sharedDisplay else {
            throw SharedDisplayError.noActiveDisplay
        }

        return display
    }

    /// Release the display for a non-stream consumer
    /// Destroys the display if this was the last consumer
    /// - Parameter consumer: The consumer type releasing the display
    func releaseDisplayForConsumer(_ consumer: DisplayConsumer) async {
        guard activeConsumers.removeValue(forKey: consumer) != nil else {
            MirageLogger.host("\(consumer) was not using shared display")
            return
        }

        MirageLogger.host("\(consumer) released shared display. Remaining consumers: \(activeConsumers.count)")

        if activeConsumers.isEmpty {
            await destroyDisplay()
        }
    }

    /// Update the resolution for a stream (when client moves to different display)
    /// - Parameters:
    ///   - streamID: The stream to update
    ///   - newResolution: The new client resolution
    func updateClientResolution(
        for streamID: StreamID,
        newResolution: CGSize,
        refreshRate: Int = 60
    ) async throws {
        let consumer = DisplayConsumer.stream(streamID)
        guard var clientInfo = activeConsumers[consumer] else {
            throw SharedDisplayError.clientNotFound(streamID)
        }

        // Update stored resolution
        clientInfo = ClientDisplayInfo(
            resolution: newResolution,
            windowID: clientInfo.windowID,
            colorSpace: clientInfo.colorSpace,
            acquiredAt: clientInfo.acquiredAt
        )
        activeConsumers[consumer] = clientInfo

        // Check if we need to resize
        let optimalResolution = calculateOptimalResolution()

        if let current = sharedDisplay, needsResize(currentResolution: current.resolution, targetResolution: optimalResolution) {
            MirageLogger.host("Client resolution change requires display resize to \(Int(optimalResolution.width))x\(Int(optimalResolution.height))")
            sharedDisplay = try await recreateDisplay(newResolution: optimalResolution, refreshRate: refreshRate, colorSpace: clientInfo.colorSpace)
        }
    }

    /// Update the display resolution for a consumer (used for desktop streaming resize)
    /// This updates the existing display's resolution in place without recreation
    /// - Parameters:
    ///   - consumer: The consumer requesting the resize
    ///   - newResolution: The new resolution to resize to
    ///   - refreshRate: Refresh rate in Hz (default 60)
    func updateDisplayResolution(
        for consumer: DisplayConsumer,
        newResolution: CGSize,
        refreshRate: Int = 60
    ) async throws {
        guard activeConsumers[consumer] != nil else {
            MirageLogger.error(.host, "Cannot update resolution: consumer \(consumer) not found")
            return
        }

        guard let display = sharedDisplay else {
            MirageLogger.error(.host, "Cannot update resolution: no active display")
            return
        }

        let requestedColorSpace = activeConsumers[consumer]?.colorSpace ?? .displayP3
        // Update stored resolution for this consumer
        activeConsumers[consumer] = ClientDisplayInfo(
            resolution: newResolution,
            windowID: 0,
            colorSpace: requestedColorSpace,
            acquiredAt: Date()
        )
        if display.colorSpace != requestedColorSpace {
            MirageLogger.host("Display color space mismatch (\(display.colorSpace.displayName) → \(requestedColorSpace.displayName)); recreating")
            sharedDisplay = try await recreateDisplay(newResolution: newResolution, refreshRate: refreshRate, colorSpace: requestedColorSpace)
            return
        }

        MirageLogger.host("Updating display \(display.displayID) for \(consumer) to \(Int(newResolution.width))x\(Int(newResolution.height))")

        // Try to update the existing display's resolution in place
        // This avoids display leak issues and is faster than destroy/recreate
        let success = CGVirtualDisplayBridge.updateDisplayResolution(
            display: display.displayRef.value,
            width: Int(newResolution.width),
            height: Int(newResolution.height),
            refreshRate: Double(refreshRate),
            hiDPI: true
        )

        if success {
            // Update our stored resolution
            sharedDisplay = ManagedDisplayContext(
                displayID: display.displayID,
                spaceID: display.spaceID,
                resolution: newResolution,
                refreshRate: Double(refreshRate),
                colorSpace: display.colorSpace,
                createdAt: display.createdAt,
                displayRef: display.displayRef  // Keep same reference
            )
            MirageLogger.host("Display resolution updated in place to \(Int(newResolution.width))x\(Int(newResolution.height))")
        } else {
            // Fallback to recreate if in-place update fails
            MirageLogger.host("In-place update failed, falling back to recreate")
            sharedDisplay = try await recreateDisplay(newResolution: newResolution, refreshRate: refreshRate, colorSpace: requestedColorSpace)
        }
    }

    // MARK: - Display Access

    /// Get the shared display ID
    func getDisplayID() -> CGDirectDisplayID? {
        return sharedDisplay?.displayID
    }

    /// Get the shared display space ID
    func getSpaceID() -> CGSSpaceID? {
        return sharedDisplay?.spaceID
    }

    /// Get the shared display context
    func getDisplayContext() -> ManagedDisplayContext? {
        return sharedDisplay
    }

    /// Get the shared display bounds
    /// Uses the known resolution instead of CGDisplayBounds (which returns stale values for new displays)
    func getDisplayBounds() -> CGRect? {
        guard let display = sharedDisplay else { return nil }
        return CGVirtualDisplayBridge.getDisplayBounds(display.displayID, knownResolution: display.resolution)
    }

    /// Check if there's an active shared display
    func hasActiveDisplay() -> Bool {
        return sharedDisplay != nil
    }

    /// Get count of active consumers
    func activeConsumerCount() -> Int {
        return activeConsumers.count
    }

    /// Get all active stream IDs (filters out non-stream consumers)
    func activeStreamIDs() -> [StreamID] {
        return activeConsumers.keys.compactMap { consumer in
            if case .stream(let streamID) = consumer {
                return streamID
            }
            return nil
        }
    }

    // MARK: - ScreenCaptureKit Integration

    /// Find the SCDisplay corresponding to the shared virtual display
    func findSCDisplay() async throws -> SCDisplayWrapper {
        guard let displayID = sharedDisplay?.displayID else {
            throw SharedDisplayError.noActiveDisplay
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

        guard let scDisplay = content.displays.first(where: { $0.displayID == displayID }) else {
            MirageLogger.error(.host, "SCDisplay not found for displayID \(displayID). Available: \(content.displays.map { $0.displayID })")
            throw SharedDisplayError.scDisplayNotFound(displayID)
        }

        MirageLogger.host("Found SCDisplay \(displayID): \(scDisplay.width)x\(scDisplay.height)")
        return SCDisplayWrapper(display: scDisplay)
    }

    /// Find the SCDisplay for the main display (used for desktop streaming capture).
    /// When mirroring is active, content renders on the main display even though it shows
    /// the virtual display's content. Capturing the main display ensures SCK sees actual
    /// content changes rather than the mirrored virtual display which may update sporadically.
    func findMainSCDisplay() async throws -> SCDisplayWrapper {
        let mainDisplayID = CGMainDisplayID()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

        guard let scDisplay = content.displays.first(where: { $0.displayID == mainDisplayID }) else {
            MirageLogger.error(.host, "Main SCDisplay not found for displayID \(mainDisplayID). Available: \(content.displays.map { $0.displayID })")
            throw SharedDisplayError.scDisplayNotFound(mainDisplayID)
        }

        MirageLogger.host("Found main SCDisplay \(mainDisplayID): \(scDisplay.width)x\(scDisplay.height)")
        return SCDisplayWrapper(display: scDisplay)
    }

    // MARK: - Private Helpers

    /// Fixed 3K resolution for virtual display
    /// 2880×1800 (16:10) - balanced between 4K (text too small) and 1080p (text too big)
    /// With HiDPI this gives 1440×900 logical points
    private func calculateOptimalResolution() -> CGSize {
        return CGSize(width: 2880, height: 1800)
    }

    /// Check if display needs to be resized
    private func needsResize(currentResolution: CGSize, targetResolution: CGSize) -> Bool {
        let widthDiff = abs(currentResolution.width - targetResolution.width)
        let heightDiff = abs(currentResolution.height - targetResolution.height)
        // Allow small tolerance (2 pixels) for rounding differences
        return widthDiff > 2 || heightDiff > 2
    }

    /// Create the shared virtual display
    // TODO: HDR support - add hdr: Bool parameter when EDR configuration is figured out
    private func createDisplay(resolution: CGSize, refreshRate: Int, colorSpace: MirageColorSpace) async throws -> ManagedDisplayContext {
        displayCounter += 1
        let displayName = "Mirage Shared Display (#\(displayCounter))"

        guard let displayContext = CGVirtualDisplayBridge.createVirtualDisplay(
            name: displayName,
            width: Int(resolution.width),
            height: Int(resolution.height),
            refreshRate: Double(refreshRate),
            hiDPI: true,  // Enable HiDPI for Retina-quality rendering
            colorSpace: colorSpace
        ) else {
            throw SharedDisplayError.creationFailed("CGVirtualDisplay creation returned nil")
        }

        guard let readyBounds = await CGVirtualDisplayBridge.waitForDisplayReady(
            displayContext.displayID,
            expectedResolution: resolution
        ) else {
            throw SharedDisplayError.creationFailed("Display \(displayContext.displayID) did not become ready")
        }

        // Get the space ID for the display
        let spaceID = CGVirtualDisplayBridge.getSpaceForDisplay(displayContext.displayID)

        guard spaceID != 0 else {
            throw SharedDisplayError.spaceNotFound(displayContext.displayID)
        }

        let managedContext = ManagedDisplayContext(
            displayID: displayContext.displayID,
            spaceID: spaceID,
            resolution: resolution,
            refreshRate: displayContext.refreshRate,
            colorSpace: displayContext.colorSpace,
            createdAt: Date(),
            displayRef: UncheckedSendableBox(displayContext.display)
        )

        MirageLogger.host("Created shared virtual display: \(Int(resolution.width))x\(Int(resolution.height))@\(refreshRate)Hz, color=\(displayContext.colorSpace.displayName), displayID=\(displayContext.displayID), spaceID=\(spaceID), bounds=\(readyBounds)")

        return managedContext
    }

    /// Recreate the display at a new resolution
    // TODO: HDR support - add hdr: Bool parameter when EDR configuration is figured out
    private func recreateDisplay(newResolution: CGSize, refreshRate: Int, colorSpace: MirageColorSpace) async throws -> ManagedDisplayContext {
        // Destroy current display
        await destroyDisplay()

        // Small delay for cleanup
        try await Task.sleep(nanoseconds: 50_000_000)  // 50ms

        // Create new display
        return try await createDisplay(resolution: newResolution, refreshRate: refreshRate, colorSpace: colorSpace)
    }

    /// Destroy the shared display
    private func destroyDisplay() async {
        guard let display = sharedDisplay else { return }

        let displayID = display.displayID
        MirageLogger.host("Destroying shared virtual display, displayID=\(displayID)")

        // Clear the reference - ARC will deallocate the CGVirtualDisplay
        // which removes it from the system display list
        sharedDisplay = nil

        // Small delay to let the system process the display removal
        try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms

        // Verify the display was actually removed
        let stillExists = CGVirtualDisplayBridge.isDisplayOnline(displayID)
        if stillExists {
            MirageLogger.error(.host, "WARNING: Virtual display \(displayID) still exists after destruction!")
        } else {
            MirageLogger.host("Virtual display \(displayID) successfully destroyed")
        }
    }

    // MARK: - Cleanup

    /// Destroy the shared display and clear all consumers
    /// Called during host shutdown
    func destroyAllAndClear() async {
        activeConsumers.removeAll()
        await destroyDisplay()
        MirageLogger.host("Destroyed shared display and cleared all consumers")
    }

    /// Get statistics about the shared display
    func getStatistics() -> (hasDisplay: Bool, consumerCount: Int, resolution: CGSize?) {
        return (
            hasDisplay: sharedDisplay != nil,
            consumerCount: activeConsumers.count,
            resolution: sharedDisplay?.resolution
        )
    }
}

#endif
