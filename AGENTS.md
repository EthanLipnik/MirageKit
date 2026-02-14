# MirageKit Agent Guidelines

## Overview
MirageKit is the Swift Package that implements the core streaming framework for macOS, iOS, and visionOS clients.

## Behavior Notes
- MirageKit license: PolyForm Shield 1.0.0 with the line-of-business notice for dedicated remote window/desktop/secondary display/drawing-tablet streaming.
- Stream scale: client-provided scale derived from the app's resolution limit; encoder overrides define bitrate targets.
- Hello handshake includes typed protocol negotiation with feature selection (`MirageProtocolNegotiation`, `MirageFeatureSet`).
- ProMotion preference: refresh override based on CAMetalLayer display-link cadence, 120 when supported and enabled, otherwise 60.
- Backpressure: queue-based frame drops.
- Encoder quality: derived from target bitrate and output resolution; QP bounds mapping when supported.
- Bitrate-derived quality mapping biases low-bitrate streams toward stronger compression, and queue-pressure quality drops accelerate for bitrate-constrained streams.
- Capture pixel format: 10-bit P010 when supported; NV12 fallback; 4:4:4 formats only when explicitly selected.
- Encode flow: limited in-flight frames; completion-driven next encode.
- In-flight cap: 120Hz 2 frames; 60Hz 1 frame.
- Keyframe payload: 4-byte parameter set length prefix; Annex B parameter sets; AVCC frame data.
- iPad modifier input uses flags snapshots with gesture resync to avoid stuck keys.
- iPad Apple Pencil input supports global mode selection, and Pencil contact forwards pressure plus stylus orientation metadata for tablet-aware apps in both `mouse` and `drawingTablet` modes.
- iPad direct touch input supports `normal`, `dragCursor`, and `exclusive` modes; exclusive mode routes single-finger touch through native scroll physics while pointer clicks come from Apple Pencil or indirect pointer input.
- Apple Pencil squeeze triggers a secondary click at the hover location when available, or the latest pointer location.
- Custom mode: encoder overrides for pixel format, color space, bitrate, and keyframe interval.
- `MIRAGE_SIGNPOST=1` enables Instruments signposts for decode/render timing.
- Automatic quality tests use staged UDP payloads (warmup + ramp until plateau) plus VideoToolbox benchmarks for encode/decode timing.
- Automatic quality selection uses staged throughput and loss results as the bitrate baseline, with fixed resolution and pixel-format viability checks.
- Automatic quality test cadence follows ProMotion preference (max refresh when enabled, 60 Hz cap when disabled).
- Host setting `muteLocalAudioWhileStreaming` mutes host output while audio streaming is active and restores prior mute state when audio streaming stops.
- MirageKit targets the latest supported OS releases; availability checks are not used in MirageKit code.
- Lights Out mode: host-side blackout overlay + input block for app streaming and mirrored desktop streaming; overlay windows use non-shareable window policy, ScreenCaptureKit display capture excludes the overlay windows, and screenshot hotkeys (`⌘⇧3`, `⌘⇧4`, `⌘⇧5`) temporarily suspend Lights Out until screenshot UI is no longer active.
- Lights Out emergency shortcut: host service exposes a configurable local shortcut that is matched inside the Lights Out event tap to run emergency recovery (disconnect clients, clear overlays, lock host).
- Host app streaming enforces Stage Manager off during active app-stream sessions; when Mirage disables it for streaming, host restores the prior enabled state after the last app-stream session ends.
- Remote unlock HID credential entry requires visible lock/login UI; if lock UI is not visible, unlock returns a retryable timeout without typing into the active app session.
- Client startup retries stream registration until the first UDP packet arrives.
- Virtual display serial recovery alternates between two deterministic serial slots per color space to bound ColorSync profile churn while preserving mode-mismatch recovery.
- Virtual display creation attempts Retina first and can fall back to 1x logical resolution when Retina activation does not validate; display snapshots carry active scale factors so bounds, capture, and input paths follow the active mode.
- Desktop streaming uses a main-display capture fallback when shared virtual display activation is unavailable, preserving stream startup with physical-display bounds and without shared-display resize orchestration for that session.
- Virtual display readiness validates HiDPI mode using paired logical and pixel dimensions from `CGDisplayCopyDisplayMode`, while desktop input bounds prefer cached logical display bounds.
- CGVirtualDisplay settings use `hiDPI=2` when Retina mode is requested; `hiDPI=1` can resolve to non-Retina 1x modes on some hosts.
- Capture watchdog restart requests are canceled once stream shutdown begins; display-capture stall recovery uses a 1.5-second threshold, while window-capture stall recovery uses an 8-second threshold for extended menu-tracking pauses.
- Capture recovery distinguishes fallback-resume keyframe requests from capture-restart requests; fallback resume queues an urgent keyframe without epoch reset, and capture restart uses reset+epoch escalation only after repeated restart streaks.
- Capture restart pacing uses exponential cooldown for repeated restarts (base 3 seconds, 2x multiplier, 18-second cap) and resets the streak after a 20-second stable window.
- iOS drawable size changes are reported immediately once they exceed the resize tolerance (0.5% or 4px).
- iOS/visionOS virtual-display sizing derives from native screen metrics (`nativeBounds`, `nativeScale`) while drawable-size callbacks continue to drive live desktop resize transactions.
- Host/client control-message dispatch uses handler registries keyed by `ControlMessageType`.
- Signed identity handshake v2 requires `identityAuthV2` with canonical payload signatures and replay protection.
- Accepted hello negotiation requires `identityAuthV2`, `udpRegistrationAuthV1`, and `encryptedMediaV1`; signed hello responses include `mediaEncryptionEnabled` plus a per-session UDP registration token.
- Media-session security uses ECDH/HKDF-derived keys with ChaCha20-Poly1305 for UDP video/audio and parity payloads, and client packet handling decrypts encrypted payloads before reassembly and CRC checks.
- UDP stream/audio/quality registrations carry the per-session token and host registration validates token matches in constant time.
- Remote signaling helpers include signed Worker requests, STUN probes, and host candidate parsing for direct remote readiness.
- Host remote path runs a dedicated QUIC control listener (`MirageHostService+Remote.swift`) and publishes STUN-derived `hostCandidates` through signed signaling heartbeats.
- Remote diagnostics logging spans client remote preflight/join/connect, host remote listener and advertise/heartbeat loops, and signaling request outcomes.

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
├─ .github/
│  └─ workflows/
│     └─ ci.yml
├─ Package.swift
├─ Sources/
│  ├─ MirageKit/ (shared)
│  │  ├─ Public/
│  │  │  ├─ CloudKit/
│  │  │  ├─ Remote/
│  │  │  ├─ Input/
│  │  │  ├─ Shared/
│  │  │  └─ Types/
│  │  └─ Internal/
│  │     ├─ Logging/
│  │     ├─ Protocol/
│  │     └─ Utilities/
│  ├─ MirageKitClient/
│  │  ├─ Public/
│  │  │  ├─ Client/
│  │  │  └─ Views/
│  │  └─ Internal/
│  │     ├─ Client/
│  │     ├─ Decoding/
│  │     ├─ Network/
│  │     ├─ Rendering/
│  │     └─ Utilities/
│  └─ MirageKitHost/
│     ├─ Public/
│     │  ├─ Host/
│     │  └─ Utilities/
│     ├─ Internal/
│     │  ├─ Capture/
│     │  ├─ Cursor/
│     │  ├─ Encoding/
│     │  ├─ Host/
│     │  ├─ Network/
│     │  ├─ Utilities/
│     │  └─ VirtualDisplay/
└─ Tests/
   ├─ MirageKitClientTests/
   ├─ MirageKitHostTests/
   └─ MirageKitTests/
```

Docs: `If-Your-Computer-Feels-Stuttery.md` - ColorSync stutter cleanup commands.

## Public API
- Shared types, input events, trust, and CloudKit helpers: `Sources/MirageKit/Public/`.
- Remote signaling and STUN preflight helpers: `Sources/MirageKit/Public/Remote/`.
- Client services, delegates, session stores, metrics, cursor snapshots, and stream views: `Sources/MirageKitClient/Public/`.
- Host services, delegates, window/input controllers, and host utilities: `Sources/MirageKitHost/Public/`.
- Quality probe results are not used.

## Internal Implementation
- Shared protocol, logging, and support utilities: `Sources/MirageKit/Internal/`.
- Client decode, render, and transport: `Sources/MirageKitClient/Internal/`.
- Host capture, encode, virtual display, and host utilities: `Sources/MirageKitHost/Internal/`.
- Host audio mute control: `Sources/MirageKitHost/Internal/Audio/HostAudioMuteController.swift`.
- Host Lights Out support: `Sources/MirageKitHost/Internal/Host/HostLightsOutController.swift`, `Sources/MirageKitHost/Internal/Host/MirageInjectedEventTag.swift`.
- Host Lights Out integration: `Sources/MirageKitHost/Public/Host/MirageHostService+LightsOut.swift`.
- Host Stage Manager guardrail: `Sources/MirageKitHost/Internal/Host/HostStageManagerController.swift`, `Sources/MirageKitHost/Public/Host/MirageHostService+StageManager.swift`.

**Other Modules:**
- Automatic quality testing no longer includes dedicated probe scene or transport-helper paths.
- `Sources/MirageKitClient/Public/Client/MirageClientService+QualityTestHelpers.swift` - Quality test helper routines

## Architecture Patterns
- `MirageHostService` and `MirageClientService` are the main entry points.
- Delegate pattern for event callbacks.
- Services are `@Observable` and `@MainActor`.
- Control-message routing in host/client services uses registry maps keyed by message type.

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
- Latency modes: `lowestLatency`, `auto`, and `smoothest`.
- Auto typing burst: `auto` keeps smooth-mode buffering by default and applies a 350ms text-entry burst for keyDown events without Command/Option/Control; host forces in-flight depth to 1 with a temporary stronger P-frame compression cap, and client presentation trims to newest-frame depth during the burst window.
- Keyframe throttling: host ignores repeated keyframe requests while a keyframe is in flight; encoding waits for UDP registration so the first keyframe is delivered.
- Recovery keyframes: soft recovery sends urgent keyframes without epoch reset; hard recovery escalates on repeated requests within 4 seconds.
- Recovery-only cadence: scheduled periodic keyframes are disabled; startup and recovery keyframes remain active.
- Compression ceiling: frame quality is capped at 0.80 while bitrate targets remain independent.
- FEC policy: loss windows prioritize keyframe parity; P-frame parity is enabled only during hard recovery windows.
- Adaptive fallback: automatic mode applies bitrate-only steps first (15% per trigger, 15-second cooldown, 8 Mbps floor) before disruptive reconfiguration.
- Custom mode recovery: stream parameters remain fixed while stream-health warnings report sustained degradation.
- Decoder recovery: client enters keyframe-only mode after decode errors or decode-backpressure overload until a fresh keyframe arrives.
- Reassembler P-frame delivery requires a delivered keyframe anchor and monotonic frame progression, while missing-frame recovery stays decoder-driven through keyframe recovery paths.
- Presentation catch-up trimming uses oldest-frame age gating to preserve short decode jitter bursts and trims only when latency exceeds the presentation threshold.
- Decode backpressure recovery performs full stream recovery (decoder reset, reassembler reset/keyframe-only, queue flush, and keyframe request) instead of continuing through stale P-frame references.
- Adaptive fallback triggers on decode-storm episodes (two decode-threshold events within an 8-second window) in addition to queue-drop overload signals.
- Client decode submission in-flight limits are frame-rate aware (60Hz: 2, 120Hz: 3) to bound asynchronous VideoToolbox submission pressure.
- Client freeze monitoring requests a recovery keyframe after sustained decode stalls and escalates to full stream recovery on repeated stall windows.
- Client presentation uses custom CAMetalLayer surfaces on iOS, visionOS, and macOS with display-link driven dequeue/present cadence.
- iOS client render admission is latency-mode aware: `lowestLatency` keeps 60Hz in-flight at 1, `auto` uses 2 with typing/recovery forcing 1, and `smoothest` uses 2 with promotion to 3 only during sustained healthy windows; a render recovery state machine clamps in-flight to 1 during sustained low-FPS/drawable-wait collapse.
- MirageFrameCache stores bounded per-stream FIFO frame queues with sequence/age metadata for ordered presentation.
- Render emergency trimming drops oldest queued frames only during sustained backlog conditions and restores queue depth to a safe floor.
- Adaptive fallback overload handling remains signal-only; automatic bitrate and pixel-format mutation is not applied by client fallback triggers.

## Input Handling
- Host input clears stuck modifiers after 0.5s of modifier inactivity.
- iPad modifier input uses flags snapshots with gesture resync to avoid stuck keys.
- Stylus-backed pointer events bypass pointer smoothing paths to preserve pressure and tilt fidelity.
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
- Desktop streaming: `acquireDisplayForConsumer(.desktopStream)` creates display at client-requested resolution; capture/encoder enforce the cap; main display is mirrored onto it.
- Display capture for login/desktop streams uses the virtual display pixel resolution override to avoid HiDPI half-resolution captures.

## Platform Support
- macOS: host + client capability.
- iOS/iPadOS: client only.
- visionOS: client only.
- Conditional compilation with `#if os(macOS)` throughout.

## Build and Test
- Build: `swift build --package-path MirageKit`.
- Test: `swift test --package-path MirageKit`.
- CI: `.github/workflows/ci.yml` runs `swift build` and `swift test` on `macos-26` with `DEVELOPER_DIR=/Applications/Xcode_26.2.app/Contents/Developer`.

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
- Place new tests under the matching package test target directory (`Tests/MirageKitTests`, `Tests/MirageKitHostTests`, or `Tests/MirageKitClientTests`) and name them descriptively.

## Compilation Checks
- When finishing work, build MirageKit with `swift build --package-path MirageKit`.
