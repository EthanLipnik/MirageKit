# MirageKit Architecture

This document describes the architecture of the **entire MirageKit Swift package**.

It is a package-internal architecture reference for engineers working in:

- `Sources/MirageKit`
- `Sources/MirageBootstrapShared`
- `Sources/MirageHostBootstrapRuntime`
- `Sources/MirageKitHost`
- `Sources/MirageKitClient`
- `Tests/MirageKitTests`
- `Tests/MirageKitHostTests`
- `Tests/MirageKitClientTests`

It does not describe app-target UI architecture in `Mirage/`, `Mirage Host/`, or daemon app bundles except where they call MirageKit APIs.

## 1. Package Topology

MirageKit is one SwiftPM package with five products:

- `MirageKit` (shared protocol, security, trust, remote/cloud/bootstrap, diagnostics)
- `MirageBootstrapShared` (bootstrap wire contract, replay/auth primitives, daemon/host telemetry queue schema)
- `MirageHostBootstrapRuntime` (daemon-only unlock/control runtime with local OSLog diagnostics)
- `MirageKitClient` (client connection + media receive/decode/render + client control state)
- `MirageKitHost` (host connection + capture/encode/send + input injection + stream governance)

Package constraints from `Package.swift`:

- Swift tools: `6.2`
- Platforms: `macOS 14+`, `iOS 17.4+`, `visionOS 26+`
- External deps: `swift-nio`, `swift-nio-ssh`

![MirageKit Package Topology](Assets/Architecture-PackageTopology.svg#gh-light-mode-only)
![MirageKit Package Topology](Assets/Architecture-PackageTopology-dark.svg#gh-dark-mode-only)

## 2. High-Level Runtime Model

MirageKit is split into two runtime planes:

- **Control plane**: typed `ControlMessage` frames over a persistent control connection.
  - Transport: TCP by default; QUIC is optional for remote/direct control in both host and client control transport enums.
- **Media plane**: UDP channels for video (`MIRG`), audio (`MIRA`), and quality test (`MIRQ`).

Session setup is explicit:

1. Control connection established.
2. Signed `hello`/`helloResponse` handshake validates identity and negotiation.
3. Host returns `dataPort` plus per-session UDP registration token.
4. Client registers stream/client channels over UDP using token.
5. Host begins sending media packets once registration is accepted.

![MirageKit Session Handshake](Assets/Architecture-Handshake.svg#gh-light-mode-only)
![MirageKit Session Handshake](Assets/Architecture-Handshake-dark.svg#gh-dark-mode-only)

## 3. Shared Target (`Sources/MirageKit`) Architecture

### 3.1 Wire Contracts and Message Schema

Core wire definitions live in `Internal/Protocol/*`:

- `ControlMessageType`: complete control taxonomy (hello, stream lifecycle, input, app/desktop, audio, updates, errors).
- `ControlMessage`: framed envelope:
  - `type: UInt8`
  - `payloadLength: UInt32`
  - `payload: Data`
- `ControlMessage.deserialize(...)` is bounded by `MirageControlMessageLimits` and fails closed on malformed/oversized frames.

Important limits in `MirageControlMessageLimits`:

- `maxPayloadBytes`: 8 MB
- `maxAppListPayloadBytes`: 32 MB
- `maxHostHardwareIconPayloadBytes`: 4 MB
- `maxReceiveBufferBytes`: 64 MB
- `maxHelloFrameBytes`: 64 KB

Media packet contracts:

- `FrameHeader` (video): fixed 61 bytes.
  - Includes `streamID`, `sequenceNumber`, `frameNumber`, fragmentation fields, `contentRect`, `dimensionToken`, `epoch`, checksum, flags.
- `AudioPacketHeader` (audio): fixed 47 bytes.
  - Includes codec/rate/channels/samples, fragmentation, checksum, flags.
- `QualityTestPacketHeader`: fixed 37-byte `MIRQ` format for throughput/latency probing.

Protocol constants:

- `mirageProtocolVersion = 2`
- Required feature negotiation includes:
  - `identityAuthV2`
  - `udpRegistrationAuthV1`
  - `encryptedMediaV1`

App-stream runtime control adds host-authoritative per-stream policy distribution:

- `streamPolicyUpdate` (`StreamPolicyUpdateMessage`)
  - `epoch`
  - `policies: [MirageStreamPolicy]`
  - each policy includes `tier`, `targetFPS`, `targetBitrateBps`, `recoveryProfile`

App-list transport is metadata-first with incremental icon streaming:

- `appListRequest` (`AppListRequestMessage`)
  - `requestID`
  - `forceRefresh`
  - `forceIconReset`
  - `priorityBundleIdentifiers`
- `appList` (`AppListMessage`)
  - `requestID`
  - `apps` metadata only (`iconData = nil`)
- `appIconUpdate` (`AppIconUpdateMessage`)
  - `requestID`
  - `bundleIdentifier`
  - `iconData` (HEIF preferred, PNG fallback)
  - `iconSignature` (SHA-256 hex)
- `appIconStreamComplete` (`AppIconStreamCompleteMessage`)
  - `requestID`
  - `sentIconCount`
  - `skippedBundleIdentifiers`

### 3.2 Shared Security Architecture

Security layers are composed, not monolithic:

1. **Identity keys** (`MirageIdentityManager`)
   - P-256 signing key persisted in Keychain (`com.mirage.identity.account.v2`) with sync support.
   - Stable key identifier = SHA-256 of uncompressed ANSI X9.63 public key bytes (`0x04 || x || y`).

2. **Canonical signature payloads** (`MirageIdentitySigning`)
   - Deterministic field ordering and stable JSON encoding for signed hello/response and worker/bootstrap requests.

3. **Replay protection** (`MirageReplayProtector` actor)
   - Nonce + timestamp window validation.
   - Bounded nonce table with pruning and max length enforcement.

4. **Media session derivation** (`MirageMediaSecurity`)
   - ECDH via `MirageIdentityManager.deriveSharedKey(...)` + HKDF with canonical derivation salt.
   - Produces:
     - `sessionKey` (32 bytes)
     - `udpRegistrationToken` (32 bytes)

5. **Per-packet AEAD**
   - ChaCha20-Poly1305 for video/audio payload encryption.
   - Nonce derived from stream/sequence/fragment and direction.
   - Checksum policy:
     - required for unencrypted payloads
     - optional (`0`) for encrypted payloads where AEAD integrity applies

### 3.3 Trust and Authorization Surfaces

Trust is abstracted behind `MirageTrustProvider`:

- `evaluateTrust(for:)` / `evaluateTrustOutcome(for:)`
- `grantTrust(to:)`
- `revokeTrust(for:)`

Concrete trust surfaces in shared target:

- `MirageTrustStore`: local trusted-device persistence.
- `MirageCloudKitTrustProvider`: cloud-share-aware trust decisions, optional manual-approval override.

Host handshake consumes trust outcome and can emit auto-trust notice semantics (`autoTrustGranted`).

### 3.4 Cloud/Remote/Bootstrap Services

`MirageKit` also owns optional infrastructure used by host/client apps:

- **CloudKit**
  - `MirageCloudKitManager`
  - `MirageCloudKitHostProvider`
  - `MirageCloudKitShareManager`
  - `MirageHostCloudKitRegistrar`: background actor for host-discovery record cleanup, registration, and `lastSeen` refresh so recurring host metadata traffic does not run on the UI actor.
  - `MirageCloudKitTrustProvider`

- **Remote signaling**
  - `MirageRemoteSignalingClient`: signed app-authenticated worker API calls.
    - Host advertising is heartbeat-first to refresh liveness without create conflicts.
    - Host create is used only as fallback when signaling returns `session_not_found`.
    - Concurrent create races (`session_exists`) retry heartbeat once before surfacing errors.
  - `MirageStunProbe`: UDP STUN binding probe for external candidate discovery.

- **Bootstrap (wake/unlock before normal session)**
  - `MirageWakeOnLANClient`
  - `MirageSSHBootstrapClient`
  - `MirageBootstrapControlClient`
  - endpoint/metadata protocol types and crypto envelope helpers.

### 3.6 Bootstrap Shared/Runtime Split

Bootstrap daemon code is intentionally split from the monolithic host runtime:

- `MirageBootstrapShared`
  - `HostSessionState`, unlock error codes
  - bootstrap control protocol request/response/auth/encryption payloads
  - replay protection (`MirageReplayProtector`)
  - message size limits (`MirageControlMessageLimits`)
  - minimal identity verification helpers (`MirageBootstrapIdentityVerification`)
  - host/daemon telemetry queue envelope schema used for app-group handoff
  - shared bootstrap configuration payload (`MirageHostBootstrapConfiguration`)

- `MirageHostBootstrapRuntime`
  - `MirageHostBootstrapControlServer`
  - `MirageHostBootstrapUnlockService`
  - `MirageHostBootstrapDaemonStateMachine`
  - unlock/session monitor internals required for pre-login unlock
  - local daemon logger and app-group queue writer for diagnostics/analytics handoff

This split keeps bootstrap daemon linkage independent from `MirageKitHost` and app-owned telemetry SDKs.

### 3.5 Diagnostics and Instrumentation

Two distinct telemetry channels:

- `MirageDiagnostics`
  - Structured log/error sink fan-out.
  - Context-provider registry for snapshotting runtime context.

- `MirageInstrumentation`
  - Step-event timeline for handshake, approval, unlock, and performance-mode milestones.

These are cross-target and intentionally low-coupling (sink interfaces, tokenized registration).

## 4. Host Target (`Sources/MirageKitHost`) Architecture

### 4.1 Host Service as Orchestrator

`MirageHostService` (`@MainActor`, `@Observable`) is the top-level coordinator for host runtime.

Key owned registries/state:

- Control listeners: Bonjour TCP + optional QUIC remote listener.
- UDP data listener.
- Client maps:
  - `clientsByConnection`
  - `clientsByID`
  - strict `singleClientConnectionID` reservation.
- Stream maps:
  - `streamsByID`
  - `activeSessionByStreamID`
  - `activeStreamIDByWindowID`
- Local encoder low-power policy state:
  - `encoderLowPowerModePreference` (`auto`, `on`, `onlyOnBattery`)
  - current power snapshot from `MiragePowerStateMonitor`
  - `isEncoderLowPowerModeActive` effective flag applied to active streams
- Media security/policy maps:
  - `mediaSecurityByClientID`
  - `mediaEncryptionEnabledByClientID`
- Transport maps for video/audio/quality channels.
- Desktop/login/app-stream subsystem state.

Startup sequence (`start()`):

1. Start control listener via `BonjourAdvertiser`.
2. Start UDP data listener.
3. Publish capabilities, then optional remote QUIC listener.
4. Register app-stream and shared-display callbacks.
5. Refresh windows, start cursor monitor, start session monitor.

### 4.2 Handshake, Approval, and Single-Client Policy

`MirageHostService+Connections` enforces:

- signed hello verification
- replay validation
- protocol/feature compatibility
- optional protocol-mismatch-triggered software update request handling
- single active client slot with reconnect preemption by device ID or identity key ID
- trust-provider-first approval, delegate fallback, timeout/closure handling

On acceptance, host builds signed hello response and derives media context:

- `dataPort` + `udpRegistrationToken`
- negotiated selected features
- `mediaEncryptionEnabled` policy (forced for non-local paths)

### 4.3 Host Receive Architecture

`HostReceiveLoop` isolates receive behavior per control connection:

- immediate receive re-arm
- bounded receive buffer
- robust frame parsing (`ControlMessage.deserialize`)
- fast-lane routing for `inputEvent`
- control backlog queue with coalescing for high-rate updates:
  - `displayResolutionChange`
  - `streamScaleChange`
  - `streamRefreshRateChange`
  - `streamEncoderSettingsChange`
- terminal reasons include protocol violation, persistent errors, buffer overflow

Control work is serialized per-client through `SerialWorker`; input can bypass main actor using `inputQueue` and `handleInputEventFast`.

### 4.4 Stream Pipeline (Capture -> Encode -> Packetize -> Send)

Per stream, host uses `StreamContext` actor.

Major responsibilities in `StreamContext`:

- capture mode and source lifecycle (`WindowCaptureEngine`)
- dynamic dimensions and tokens
- keyframe policy and recovery escalation
- quality and backpressure adaptation
- frame inbox and decode/encode pacing
- latency-burst state for desktop typing that can clear buffered host work,
  switch to freshest-frame delivery, and temporarily lower capture queue depth
- packet send coordination (`StreamPacketSender`)
- keyframe packet pacing with bitrate-budget token bucket shaping
- optional encrypted payload wrapping

![Host Stream Pipeline](Assets/Architecture-HostPipeline.svg#gh-light-mode-only)
![Host Stream Pipeline](Assets/Architecture-HostPipeline-dark.svg#gh-dark-mode-only)

### 4.5 Stream Families

Host supports three stream families with separate orchestration:

1. **Window/App streams**
   - Dedicated virtual-display-first strategy, direct capture fallback when placement/display setup fails.
   - Active session maps keep O(1) stream/window routing.

2. **Desktop stream**
   - `startDesktopStream(...)` / `stopDesktopStream(...)`.
   - mirrored vs secondary mode.
   - mirroring snapshot/suspend/restore logic around resize and mode transitions.
   - auto typing bursts can temporarily switch desktop buffering to latency-first
     behavior without changing requested resolution, bitrate, or bit depth.
   - explicit high-resolution standard `Lowest Latency` avoids VT low-latency
     rate control and keeps the stable real-time/no-reorder/max-frame-delay path.
   - transport marks the desktop stream as active in `HostTransportRegistry` so video packets bypass passive queue shedding.

3. **Login display stream**
   - lock-screen path used when host session is not active.
   - watchdog and bounded restart behavior.
   - can borrow desktop stream path in shared-display scenarios.
   - non-borrowed login streams are marked active in `HostTransportRegistry` to preserve keyframe fragment continuity.

### 4.6 Virtual Display Subsystem

Virtual display architecture is first class, not just a helper:

- `SharedVirtualDisplayManager`
- `CGVirtualDisplayBridge`
- `WindowSpaceManager`

Host caches per-window dedicated display state (`WindowVirtualDisplayState`) and tracks generations to avoid stale placement assumptions.

Placement repair flows actively reassert expected space/frame ownership to prevent drift.

### 4.7 App-Streaming Sub-Architecture

App streaming is its own subsystem, centered on:

- `AppStreamManager`
- `AppStreamRuntimeOrchestrator`
- `StreamPolicyApplier`
- `AppStreamDisplayAllocator`
- connection-scoped `MediaConnectionScheduler` in `HostTransportRegistry`

Key properties:

- app list metadata retrieval + launch orchestration
- one-by-one icon updates after metadata snapshot (`appIconUpdate`)
- icon diffing keyed by client + bundle identifier with `forceIconReset` override
- persisted host-side icon signatures with 90-day retention
- initial multi-window startup with retry/backoff and window classification
- visible slot inventory + hidden inventory
- slot swap transactions (`appWindowSwapRequest`/result)
- deterministic host-authoritative policy snapshots (active-first + passive 1fps)
- per-session bitrate budgeting and policy-based allocation
- window lifecycle callbacks for add/remove/failure/termination

### 4.8 Host Input Architecture

Input path is split for latency:

- decoded `InputEventMessage` -> fast path (`handleInputEventFast`) on high-priority queue
- ownership/activation policy checks
- injection via `MirageHostInputController` (mouse, keyboard, scroll, tablet, gestures, desktop actions)
- keyboard/modifier injection is domain-aware:
  - app/window paths inject through session tap (`.cgSessionEventTap`)
  - desktop/login paths inject through HID tap (`.cghidEventTap`)
- stuck-modifier reconciliation reads modifier state from the matching domain source and
  performs dual-domain clear on lifecycle transitions to avoid left/right modifier drift

`InputStreamCacheActor` keeps stream/window/client routing state accessible to fast path.

### 4.9 Host Audio Architecture

Audio flow is client-scoped:

- activation by source stream (`audioSourceStreamByClientID`)
- capture/encode pipeline (`HostAudioPipeline` + `AudioEncoder`)
- packetization (`AudioPacketizer`)
- dedicated UDP channel registration (`MIRA`) and lifecycle control messages (`audioStreamStarted`/`audioStreamStopped`)

### 4.10 Operational Subsystems

Additional host operational concerns integrated into `MirageHostService` extensions:

- session-state monitoring and unlock manager
- lights-out control (`HostLightsOutController`)
- Stage Manager prep/restore (`HostStageManagerController`)
- software update control requests
- AWDL transport experiment path switching and refresh requests
- bootstrap daemon control server/unlock service APIs

## 5. Client Target (`Sources/MirageKitClient`) Architecture

### 5.1 Client Service as Session Coordinator

`MirageClientService` (`@MainActor`, `@Observable`) owns:

- control connection lifecycle
- signed hello handling and host identity verification
- stream/session state for window, desktop, login, and app modes
- UDP video/audio transports and re-registration loops
- `MirageClientFastPathState` lock-backed snapshots for nonisolated UDP receive paths
- `ClientAudioPacketIngressQueue` single-worker audio decode ingress
- per-stream controllers (`controllersByStream`)
- metrics/cursor/session stores consumed by UI layers
- local decoder low-power policy state:
  - `decoderLowPowerModePreference` (`auto`, `on`, `onlyOnBattery`)
  - current power snapshot from `MiragePowerStateMonitor`
  - `isDecoderLowPowerModeActive` effective flag pushed into active decoders

### 5.2 Client Handshake Validation

`MirageClientService+Connection` and `+MessageHandling+Core` enforce:

- nonce binding to pending hello request
- host identity key ID validation
- host signature verification over canonical hello-response payload
- replay validation
- expected-host-key consistency when discovery advertised key ID exists
- negotiation requirements (`identityAuthV2`, `udpRegistrationAuthV1`, `encryptedMediaV1`)
- local derivation of media session key and registration token binding

### 5.3 Control Routing Model

`registerControlMessageHandlers()` maps each control message type to dedicated domain handlers (core, desktop, app, menu bar, audio, software update, quality test).

Control receive parser:

- bounded buffered parse via `ControlMessage.deserialize`
- immediate disconnect on invalid frame or control-buffer overflow
- explicit detection of media payload accidentally arriving on control channel

### 5.4 Video Transport and Ingest Pipeline

`MirageClientService+Video` owns UDP video transport and registration refresh.

Pipeline:

1. start UDP connection to `hostDataPort`
2. send stream registration (`MIRG` + `streamID` + `deviceID` + token)
3. receive packet -> parse `FrameHeader`
4. consult `MirageClientFastPathState` for active-stream membership, startup-pending marker, current reassembler, and cached media packet key
5. validate expected wire length
6. decrypt if encrypted flag set
7. feed `FrameReassembler`

`FrameReassembler` responsibilities:

- fragment accumulation with pooled buffers
- checksum and token validation
- keyframe-anchor and keyframe-only recovery mode
- epoch-aware stale packet rejection
- frame-loss signaling
- optional FEC handling paths

### 5.5 Decode/Recovery Controller per Stream

Each stream has a `StreamController` actor with:

- one `HEVCDecoder`
- one `FrameReassembler`
- ordered decode queue and admission controls
- resize transition gating
- active-only bounded keyframe recovery loops with hard-reset escalation
- first-frame bootstrap watchdog that requests recovery if startup has no decode/presentation progress
- idempotent first-frame awaiter arming during host tier updates (prevents startup wait resets)
- freeze monitoring and escalation
- decode-overload / adaptive fallback signaling

Client runtime tiering is host-authoritative:

- host emits `streamPolicyUpdate`
- client applies policy to session store + stream controllers
- focus/input hints are signals only; they do not elect runtime tier locally
- `GlobalDecodeBudgetController` enforces active-first decode-token admission across streams

`HEVCDecoder` manages VT session lifecycle, parameter sets, in-flight submission limits, and decode error threshold callbacks.

Codec power-efficiency policy is local-only per device:

- host encoder applies `kVTCompressionPropertyKey_MaximizePowerEfficiency`
- client decoder applies `kVTDecompressionPropertyKey_MaximizePowerEfficiency`
- both attempt live runtime updates when a session exists, otherwise changes apply on the next session create

![Client Video Pipeline](Assets/Architecture-ClientPipeline.svg#gh-light-mode-only)
![Client Video Pipeline](Assets/Architecture-ClientPipeline-dark.svg#gh-dark-mode-only)

### 5.6 Rendering Architecture

Rendering uses one shared presentation backend across all client platforms:

- macOS path: `MirageMetalView+macOS` backed by `AVSampleBufferDisplayLayer`
- iOS/visionOS path: `MirageMetalView+iOS` backed by `AVSampleBufferDisplayLayer`
- shared draw/pacing/sample-buffer logic: `MirageSampleBufferPresenter`

Cross-platform render coordination:

- `MirageRenderStreamStore`
- `MirageFrameCache`
- shared cadence/pacing constants (`MirageRenderModePolicy`)

### 5.7 Audio Client Pipeline

`MirageClientService+Audio` defines dedicated audio transport:

- UDP audio socket setup
- registration (`MIRA` + stream/client/token)
- receive/parse/active-stream filter/decrypt/checksum
- enqueue packets onto `ClientAudioPacketIngressQueue`
- worker drains into `AudioJitterBuffer` + `AudioDecoder` sequentially
- `AudioPlaybackController` enqueue/playback

Audio ingress uses generation invalidation on stop/reset so stale queued packets are dropped instead of being delivered after stream teardown. Audio is synchronized through runtime delay hooks driven by metrics snapshot policy.

### 5.8 Desktop/App/Window Control Paths

Client request surfaces:

- window stream start/stop (`startViewing`, `stopViewing`)
- desktop stream start/stop
- app list/select/swap
- app close-blocked alert action request/result round-trip
- encoder setting changes
- keyframe request / manual recovery

Client tracks dimension-token changes per stream family to choose whether controller reset is required on `streamStarted`/`desktopStreamStarted`.

App-stream close-on-client-close routing now includes an explicit control-flow branch:

1. Client emits `stopStream` with `origin = clientWindowClosed` only for real window-close events.
2. Host applies close-attempt gating (`origin` match, app-stream session present, host setting enabled).
3. Host attempts AX close on the source window.
4. If close is blocked by an alert/sheet and another stream remains for that client, host emits `appWindowCloseBlockedAlert` to the selected presenting stream.
5. Client presents actionable UI, then sends `appWindowCloseAlertActionRequest`.
6. Host validates token ownership, executes AX button press, and replies with `appWindowCloseAlertActionResult`.

### 5.9 Quality Test Architecture

Quality-test path combines:

- control-side test plan request (`qualityTestRequest`)
- UDP `MIRQ` packet loop with stage IDs and payload sizing
- local decode benchmark + host benchmark summary result integration
- request-scoped ping/result waiters with timeout ownership tied to the active request ID
- adaptive stage growth/refinement to estimate stable bitrate envelope

## 6. Cross-Cutting Concurrency Model

Concurrency is intentionally mixed by latency sensitivity:

- **MainActor orchestration**
  - `MirageHostService`, `MirageClientService`, session-facing observable state

- **Actors for throughput-critical state machines**
  - host: `StreamContext`, virtual display managers, replay protector
  - client: `StreamController`, `HEVCDecoder`, audio jitter/decode components
  - shared diagnostics stores

- **Lock-protected structs for very hot paths**
  - `Locked<T>` in receive loops, transport registries, lightweight snapshots
  - `MirageClientFastPathState` for client UDP packet filtering and cached routing/materialized state

- **Dispatch queues for hard low-latency paths**
  - host input fast path (`inputQueue`)
  - transport worker queues for timed/serial operations

- **Single-worker async dispatchers**
  - `MirageAsyncDispatchQueue` for diagnostics fanout without task-per-event overhead
  - `ClientAudioPacketIngressQueue` for audio decode ingress without task-per-packet overhead

## 7. Failure and Recovery Strategy

### 7.1 Host Recovery

Host-side recovery mechanisms include:

- receive-loop fail-closed disconnect on protocol violations and persistent errors
- stream-level keyframe urgency and escalation
- encoder reset and stuck detection in `StreamContext`
- capture restart strategies in `WindowCaptureEngine`
- virtual-display fallback to direct capture for startup failures
- transport refresh requests for path-change recovery

### 7.2 Client Recovery

Client-side recovery mechanisms include:

- keyframe requests on decode-threshold/freeze/loss/manual triggers
- reassembler keyframe-only mode until safe decode anchor returns
- resize gating to avoid old-dimension P-frame decode storms
- controller reset decisions based on dimension token advances
- decode submission scheduler escalates only when decode is the bottleneck (not source-limited host cadence)
- optional adaptive fallback state machine for temporary encoder downshift
- automatic transport re-registration on path changes or explicit host request
- passive-tier recovery stays bounded (no recurring keyframe loop)

## 8. Test Architecture as Executable Contract

Three test targets map directly to architecture boundaries:

- `MirageKitTests` (shared contract/security/bootstrap/diagnostics)
- `MirageKitClientTests` (decode/reassembly/recovery/render/audio/transport refresh logic)
- `MirageKitHostTests` (single-client policy, receive loop, stream policy, virtual display math, app-stream governance, lights-out, software updates)

Representative lock points:

- handshake + replay + remote-signing security tests
- packet checksum and media encryption policy tests
- host receive loop robustness tests
- desktop resize and keyframe recovery policy tests
- app-window governance/swap/startup stabilization tests
- AWDL/transport recovery tests on both host and client targets

## 9. Core Architectural Invariants

The package currently relies on these invariants:

1. No accepted control session without successful signed hello validation and replay checks.
2. No UDP media registration accepted without token match against derived session context.
3. Control parsing is bounded and fail-closed by shared message limits.
4. Stream resize transitions propagate via dimension tokens and require token-aware client gating.
5. Host enforces one active client session slot at a time.
6. Stream decode state is owned by per-stream controllers, not views.
7. Diagnostics/instrumentation sinks are optional observers, never control-path dependencies.
8. Host is the source of truth for app-stream tier/fps/bitrate/recovery policy.

## 10. Change Checklist for Architecture Updates

When changing MirageKit architecture-level behavior, update this file in the same change if you modify any of:

- control or media wire schema
- handshake, negotiation, trust, or media security policy
- stream lifecycle ownership between host/client subsystems
- virtual-display, app-stream governance, or input ownership flow
- transport path switching and registration refresh behavior
- concurrency ownership (actor/MainActor/queue boundaries)
- tests that redefine architectural lock points
