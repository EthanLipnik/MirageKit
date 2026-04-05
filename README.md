# MirageKit

MirageKit is a window and desktop streaming framework for Apple platforms. It provides a macOS host service for capturing windows or virtual displays and a client service for discovering hosts, receiving low-latency video, and forwarding input back to the host. SwiftUI views are included for rendering streams through a shared `AVSampleBufferDisplayLayer` presentation path on macOS, iOS, and visionOS.

Networking is built on [Loom](https://github.com/EthanLipnik/Loom).

> MirageKit is pre-release. API and architecture can still change.

## Features

- Window, app, and full desktop streaming from macOS hosts
- Bonjour discovery with TCP control plus UDP media transport
- Typed hello negotiation with protocol version and feature selection
- Peer-to-peer connections over AWDL
- Encoder configuration helpers and per-stream overrides
- Input forwarding for mouse, keyboard, scroll, and gestures
- SwiftUI stream views for macOS, iOS, and visionOS
- Session store and streaming content view for UI state
- Host window and input controllers for macOS integration
- Virtual display capture for pixel-perfect rendering
- Native-screen-based display sizing on iOS and visionOS (`nativeBounds` + `nativeScale`)
- Remote session state and unlock support
- Menu bar passthrough and app-centric streaming utilities
- Built-in trust hooks and app preference helpers
- Registry-based control message dispatch in host and client services

## Requirements

- macOS 26+ for host streaming (ScreenCaptureKit)
- iOS 26+ / visionOS 26+ for client streaming
- Swift 6.2+

## Installation

Add MirageKit as a Swift Package Manager dependency.

```swift
// Package.swift
.package(url: "https://github.com/EthanLipnik/MirageKit.git", from: "0.0.1"),
```

MirageKit ships four products:

- `MirageKit` (shared types, protocol, logging, and configuration helpers)
- `MirageKitClient` (client services, session state, and stream views)
- `MirageKitHost` (host services, capture, encode, and input helpers)
- `MirageHostBootstrapRuntime` (host bootstrap and unlock runtime support)

Add the relevant products to your target dependencies.

## Quick Start

### Host (macOS)

```swift
import MirageKitHost

@MainActor
final class HostController: MirageHostDelegate {
    private let hostService = MirageHostService()

    init() {
        hostService.delegate = self
    }

    func start() async throws {
        try await hostService.start()
    }

    func hostService(_ service: MirageHostService, shouldAllowClient client: MirageConnectedClient, toStreamWindow window: MirageWindow) -> Bool {
        true
    }
}
```

### Client (iOS/macOS/visionOS)

```swift
import MirageKitClient

@MainActor
final class ClientController: MirageClientDelegate {
    let clientService = MirageClientService()

    init() {
        clientService.delegate = self
    }

    func connect(to host: LoomPeer) async throws {
        try await clientService.connect(to: host)
        try await clientService.requestWindowList()
    }
}
```

### SwiftUI Stream View

`MirageStreamViewRepresentable` reads frames from `MirageFrameCache` and does not require SwiftUI state updates per frame.

```swift
import MirageKitClient
import SwiftUI

struct StreamView: View {
    let streamID: StreamID

    var body: some View {
        MirageStreamViewRepresentable(
            streamID: streamID,
            onInputEvent: { event in
                // Forward event to MirageClientService
            },
            onDrawableMetricsChanged: { metrics in
                // Use to request updated capture resolution
            }
        )
    }
}
```

MirageKit also includes a higher-level content view that wires input, focus, and resize logic to a `MirageClientSessionStore`:

```swift
let sessionStore = MirageClientSessionStore()
let clientService = MirageClientService(sessionStore: sessionStore)

MirageStreamContentView(
    session: session,
    sessionStore: sessionStore,
    clientService: clientService,
    isDesktopStream: false
)
```

## How It Works

- Hosts advertise via `_mirage._tcp` and accept control connections.
- Hello handshake negotiates protocol compatibility and selected runtime features.
- Video payloads stream over UDP, and clients register stream IDs to receive media.
- Host encode pipeline uses limited in-flight frames with always-latest frame selection.
- The host can create a shared virtual display sized to the client's display for 1:1 pixels.
- iOS and visionOS display sizing derives from native screen metrics, while live desktop resize follows drawable bounds.
- Session state updates allow remote unlock flows for login-screen and locked-session cases.
- Menu bar passthrough lets clients render native menu structures and send actions back.
- Control message routing uses per-message-type handler registries in both host and client services.

## Architecture

For a deeper dive into modules and data flows, see [Architecture.md](Architecture.md).

For ColorSync cleanup guidance, see [If-Your-Computer-Feels-Stuttery.md](If-Your-Computer-Feels-Stuttery.md).

## Configuration

### Encoder Overrides

Clients can supply per-stream overrides with `MirageEncoderOverrides` (keyframe interval, bit depth, capture queue depth, and bitrate). The host applies overrides on top of its `MirageEncoderConfiguration`.

`MirageClientService.runQualityTest()` returns a `MirageQualityTestSummary` with streaming-safe bitrate, packet loss, RTT, and optional transport headroom details. Automatic selection uses replay-shaped stages only, while connection-limit probes can still include a separate raw transport sweep.

### Encoder Settings

`MirageEncoderConfiguration` lets you control codec, frame rate, encoder quality, and stream bit depth.

- Use `.highQuality` or `.balanced` defaults.
- Use `withOverrides` to apply client-specific intervals or encoder quality.
- Use `withTargetFrameRate` to request the client's target FPS (60/120 based on display capabilities).
- `frameQuality` targets inter-frame quality and maps to QP bounds when supported.
- `keyframeQuality` targets keyframe quality and should stay below `frameQuality`.

### Host AWDL Transport Experiment

Host runtime supports an AWDL transport stabilization experiment behind an environment variable:

- `MIRAGE_AWDL_EXPERIMENT=1` enables AWDL path-aware transport refresh and bounded micro-jitter smoothing paths.
- The experiment path keeps stream quality settings unchanged (resolution, bitrate targets, and bit depth policies remain the same).
- When the variable is unset, host and client runtime follow default transport behavior.

### Host Lights Out Kill Switch

- `MIRAGE_DISABLE_LIGHTS_OUT=1` disables host Lights Out activation for desktop and app-stream sessions.

### Streaming Modes

- Window streaming captures a specific window using ScreenCaptureKit.
- Desktop streaming mirrors a virtual display and supports display-sized capture.
- App streaming groups windows by bundle identifier and tracks newly spawned windows.

### Input + UI

- Input events are forwarded via `MirageInputEvent` types (mouse, key, scroll, magnify, rotate).
- Apple Pencil supports configurable `Double Tap` and `Squeeze` gesture mappings, plus `mouse` and `drawingTablet` input modes. `MiragePencilInputMode.drawingTablet` preserves pressure and stylus orientation metadata for tablet-aware host apps.
- Direct touch supports `normal` and `dragCursor` modes. Normal mode uses one-finger native scroll physics, tap-to-click, long-press drag, two-finger secondary click, and two-finger click-drag.
- Pencil hardware gestures can trigger `Secondary Click`, `Toggle Dictation`, or a configured remote Mac shortcut at the hover location when available, or the latest pointer location.
- `MirageStreamViewRepresentable` renders streams through `AVSampleBufferDisplayLayer` and exposes drawable size callbacks for resolution sync.
- `MirageStreamContentView` and `MirageClientSessionStore` coordinate input, focus, and resize UI.
- The host uses `MirageHostDelegate` and the client uses `MirageClientDelegate` for approvals and state updates.

## Permissions

The macOS host uses ScreenCaptureKit and may require Screen Recording permission. To forward input or activate windows, the host app may also need Accessibility permission.

### Local Network (Bonjour)

Both the host and client need local network access for Bonjour discovery and advertising. Add the following to your app target's Info.plist:

```xml
<key>NSBonjourServices</key>
<array>
    <string>_mirage._tcp</string>
</array>

<key>NSLocalNetworkUsageDescription</key>
<string>This app uses the local network to discover and connect to nearby devices running Mirage.</string>
```

Without these keys, `NWBrowser` fails with error `-65555 (NoAuth)` and discovery will not work. In debug builds, MirageKit (via Loom) asserts on missing keys so you see a clear message instead of the opaque system error.

For App Store distribution, you also need the `com.apple.developer.networking.multicast` entitlement. Request it through your Apple Developer account.

## Contributing

Contributions are welcome. Most of this framework was built with agentic coding tools (Claude Code and Codex). Using them is fine as long as you understand and can explain the updates you submit.

## Testing

```bash
swift build --package-path .
swift test --package-path .
```

For host-integration-sensitive changes, also build:

```bash
xcodebuild -project ../Mirage.xcodeproj -scheme 'Mirage Host' -configuration Debug -destination 'platform=macOS' build
```

## License

MirageKit is licensed under the PolyForm Shield 1.0.0 license. Use, modification, and distribution are allowed for non-competing products; providing products that compete with Mirage or other dedicated remote window/desktop/secondary display/drawing-tablet streaming applications and services is prohibited. See `LICENSE`.
