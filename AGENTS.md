# MirageKit Agent Guidelines

## Overview
MirageKit is the Swift Package that implements the core streaming framework for macOS, iOS, and visionOS clients.

## Behavior Notes
- MirageKit license: PolyForm Shield 1.0.0 with the line-of-business notice for dedicated remote window/desktop/secondary display/drawing-tablet streaming.
- Stream scale: client-provided scale derived from the app's resolution limit; encoder overrides define bitrate targets.
- ProMotion preference: refresh override based on MTKView cadence, 120 when supported and enabled, otherwise 60.
- Backpressure: queue-based frame drops.
- Encoder quality: derived from target bitrate and output resolution; QP bounds mapping when supported.
- Capture pixel format: 10-bit P010 when supported; NV12 fallback; 4:4:4 formats only when explicitly selected.
- Encode flow: limited in-flight frames; completion-driven next encode.
- In-flight cap: 120Hz 2 frames; 60Hz 1 frame.
- Keyframe payload: 4-byte parameter set length prefix; Annex B parameter sets; AVCC frame data.
- iPad modifier input uses flags snapshots with gesture resync to avoid stuck keys.
- Custom mode: encoder overrides for pixel format, color space, bitrate, and keyframe interval.
- `MIRAGE_SIGNPOST=1` enables Instruments signposts for decode/render timing.
- Automatic quality tests use staged UDP payloads (warmup + ramp until plateau) plus VideoToolbox benchmarks for encode/decode timing.

## Interaction Guidelines
- Planning phase: detailed step list; explicit plan.
- Complex issues: code review + plan before action.
- Unclear requirements or behavior: questions first.
- Comments and READMEs: static descriptions; avoid update-history phrasing.

## Keeping This Document Current
AGENTS.md is the live reference for MirageKit. Include entries for new files, directories, modules, architecture shifts, build commands, dependencies, and coding conventions.

## Project Structure
```
MirageKit/
├─ Package.swift
├─ Sources/
│  └─ MirageKit/
│     ├─ Public/
│     │  ├─ Host/
│     │  ├─ Client/
│     │  ├─ Input/
│     │  ├─ Types/
│     │  ├─ Views/
│     │  └─ Utilities/
│     └─ Internal/
│        ├─ Host/
│        ├─ Capture/
│        ├─ Encoding/
│        ├─ Decoding/
│        ├─ Network/
│        ├─ Protocol/
│        ├─ Rendering/
│        ├─ Cursor/
│        ├─ VirtualDisplay/
│        └─ Utilities/
└─ Tests/
   └─ MirageKitTests/
```

Docs: `If-Your-Computer-Feels-Stuttery.md` - ColorSync stutter cleanup commands.

## Public API (`Sources/MirageKit/Public/`)
- Host services and delegates: `Host/`.
- Host frame-rate helpers: `Host/MirageHostService+FrameRate.swift`.
- Client services, delegates, session stores, metrics, cursor snapshots, cursor position snapshots: `Client/` (includes `MirageClientService+QualityTest.swift`).
- Input event types: `Input/`.
- Shared types and configuration (including `MirageDesktopStreamMode`, `MirageQualityTestPlan`, `MirageQualityTestSummary`): `Types/`.
- Stream rendering views: `Views/` (Metal-backed stream view, input capture, and representables).
- Software keyboard input helpers: `Views/InputCapturingView+SoftwareKeyboard.swift`.
- Utilities: `Utilities/`.

## Internal Implementation (`Sources/MirageKit/Internal/`)
- Host: app enumeration, session state, menu bar capture, unlock handling, stream lifecycle, power assertions, packet buffer reuse for UDP sends.
- Capture: capture orchestration, frame metadata, Metal copy, differential encoding.
- Encoding/Decoding: HEVC encoder and decoder, frame reassembly buffer reuse.
- Network: discovery and connectivity (Bonjour, TLS transport).
- Protocol: wire format and serialization (quality test messages and UDP header).
- VirtualDisplay: CGVirtualDisplay bridge and shared display coordination.
- Rendering: Metal renderer.
- Cursor: cursor position tracking.
- Logging: unified logging and signposts.
- Utilities: codec benchmark timing storage, bitrate-to-quality mapping, and helpers for automatic quality tests.

## Architecture Patterns
- `MirageHostService` and `MirageClientService` are the main entry points.
- Delegate pattern for event callbacks.
- Services are `@Observable` and `@MainActor`.

## Streaming Pipeline
- Host: ApplicationScanner → WindowCaptureEngine → MetalFrameDiffer → HEVCEncoder → Network.
- Client: Network → HEVCDecoder → MirageStreamView (Metal rendering).
- Client rendering reads frames from `MirageFrameCache` inside Metal views to avoid SwiftUI per-frame churn.
- Stream scaling: capture at `streamScale` output resolution; content rects are in scaled pixel coordinates.
- Adaptive stream scale: not supported; streams keep the client-selected `streamScale` throughout the session.
- SCK buffer lifetime: captured frames are copied into a CVPixelBufferPool before encode to avoid retaining SCK buffers.
- Queue limits: packet queue thresholds scale with encoded area and frame rate.
- Frame rate selection: host follows client refresh rate (120fps when supported) across streams.
- Desktop streaming: packet-queue backpressure and scheduled keyframe deferral during high motion/queue pressure.
- Low-latency backpressure: queue spikes drop frames to keep latency down; recovery keyframes are requested separately.
- Keyframe throttling: host ignores repeated keyframe requests while a keyframe is in flight; encoding waits for UDP registration so the first keyframe is delivered.
- Decoder recovery: client enters keyframe-only mode after decode errors until a fresh keyframe arrives.

## Input Handling
- Host input clears stuck modifiers after 0.5s of modifier inactivity.
- iPad modifier input uses flags snapshots with gesture resync to avoid stuck keys.
- Client cursor state is read from `MirageClientCursorStore` inside input views to avoid SwiftUI-driven cursor churn.
- Secondary display cursor position is read from `MirageClientCursorPositionStore` for locked cursor rendering.

## Network Configuration
- Service type: `_mirage._tcp` (Bonjour).
- Control port: 9847; Data port: 9848.
- Protocol version: 1.
- Hybrid transport with TLS encryption.
- UDP packet sizing: `MirageNetworkConfiguration.maxPacketSize` caps Mirage header + payload to avoid IPv6 fragmentation; `StreamContext` uses it for frame fragmentation.
- `StreamPacketSender` sends bounded bursts and tracks queued bytes for backpressure.
- Quality feedback messages: none.

## Virtual Display Behavior
- App streaming: `acquireDisplay(for:clientResolution:)` creates a display sized to client resolution; window is moved onto it for isolation.
- Desktop streaming: `acquireDisplayForConsumer(.desktopStream)` creates display at client-requested resolution (capped at 5K); main display is mirrored onto it.
- Display capture for login/desktop streams uses the virtual display pixel resolution override to avoid HiDPI half-resolution captures.

## Platform Support
- macOS: host + client capability.
- iOS/iPadOS: client only.
- visionOS: client only.
- Conditional compilation with `#if os(macOS)` throughout.

## Build and Test
- Build: `swift build --package-path MirageKit`.
- Test: `swift test --package-path MirageKit`.

## Coding Style and Naming
- Use 4 spaces for indentation and keep line wrapping consistent with surrounding code.
- Types use `UpperCamelCase`, functions and properties use `lowerCamelCase`.
- Public API types keep the `Mirage` prefix.
- Match file names to the primary type and use `// MARK: -` for sections.
- New Swift files include the standard header with author and a 1-2 line summary of file purpose, for example:
  ```
  //
  //  ExampleThing.swift
  //  MirageKit
  //
  //  Created by Ethan Lipnik on 1/16/26.
  //
  //  Stream session state for client rendering.
  //
  ```
- For `Created by` lines in Swift headers, check the system date or the file creation date before setting the date.
- Keep public API edits in `Sources/MirageKit/Public` minimal and well documented.
- Break different types into separate Swift files rather than placing multiple structs, classes, or enums in one file.
- Do not introduce third-party frameworks without asking first.
- Comments and READMEs use static descriptions; avoid update-history phrasing.

## Swift Guidelines
- Target Swift 6.2+ with strict concurrency.
- Always mark `@Observable` classes with `@MainActor`.
- Never use `DispatchQueue.main.async()`; use Swift concurrency instead.
- Never use `Task.sleep(nanoseconds:)`; use `Task.sleep(for:)` instead.
- Prefer Swift-native alternatives to Foundation methods where they exist:
  - Use `replacing("hello", with: "world")` instead of `replacingOccurrences(of:with:)`.
  - Use `URL.documentsDirectory` and `appending(path:)` for URL handling.
- Never use C-style number formatting like `String(format: "%.2f", value)`; use formatters instead.
- Prefer static member lookup over struct instances.
- Use `localizedStandardContains()` instead of `contains()` for user-input text filtering.
- Avoid force unwraps and force `try` unless failure is unrecoverable.
- Avoid UIKit unless specifically requested.

## SwiftUI Guidelines
- Always use `foregroundStyle()` instead of `foregroundColor()`.
- Always use `clipShape(.rect(cornerRadius:))` instead of `cornerRadius()`.
- Always use the `Tab` API instead of `tabItem()`.
- Always use `NavigationStack` with `navigationDestination(for:)` instead of `NavigationView`.
- Use `.scrollIndicators(.hidden)` instead of `showsIndicators: false` in scroll view initializers.
- Prefer `ImageRenderer` over `UIGraphicsImageRenderer` for rendering SwiftUI views.
- Do not use `ObservableObject`; prefer `@Observable`.
- Do not break views up using computed properties; extract new `View` structs instead.
- Avoid `AnyView` unless absolutely required.
- Avoid `GeometryReader` if newer alternatives work (`containerRelativeFrame()`, `visualEffect()`).
- Never use `onChange()` with 1 parameter; use the 2-parameter or 0-parameter variant.
- Never use `onTapGesture()` unless tap location or count is needed; use `Button` otherwise.
- For image buttons, include text: `Button("Tap me", systemImage: "plus", action: myAction)`.
- Never use `UIScreen.main.bounds` to read available space.
- Do not force specific font sizes; prefer Dynamic Type.
- When using `ForEach` with `enumerated()`, do not convert to an array first.
- Avoid UIKit colors in SwiftUI code.

## SwiftData Guidelines (if applicable)
- Never use `@Attribute(.unique)`.
- Model properties have default values or are optional.
- All relationships are optional.

## File Size Guidelines
- Target: no file exceeds 500 lines.
- When a file grows beyond 500 lines, extract related functionality into separate manager classes or extensions.

## Testing Guidelines
- Tests use Swift Testing (`import Testing`) with `@Suite`, `@Test`, and `#expect` assertions.
- Place new tests under `Tests/MirageKitTests` and name them descriptively.

## Compilation Checks
- When finishing work, build MirageKit with `swift build --package-path MirageKit`.
