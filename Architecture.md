# MirageKit Architecture

This document describes the architecture of the MirageKit Swift package.

It is a package-internal reference for engineers working in:

- `Sources/MirageKit`
- `Sources/MirageKitClient`
- `Sources/MirageKitHost`
- `Sources/MirageHostBootstrapRuntime`
- `Tests/MirageKitTests`
- `Tests/MirageKitClientTests`
- `Tests/MirageKitHostTests`
- `Tests/MirageHostBootstrapRuntimeTests`

It does not describe app-target UI architecture in `Mirage/`, `Mirage Host/`, or daemon app bundles except where they call MirageKit APIs.

## 1. Package Topology

MirageKit is one SwiftPM package with four products:

- `MirageKit`
  Shared protocol code, stream models, configuration defaults, security helpers, diagnostics, and package-wide constants.
- `MirageKitClient`
  Client connection state, media receive and decode, stream presentation, input forwarding, and session coordination.
- `MirageKitHost`
  Host connection orchestration, capture and encode, stream lifecycle, input injection, menu bar passthrough, and software update flows.
- `MirageHostBootstrapRuntime`
  Host bootstrap and unlock runtime for daemon-side pre-login control flows.

Package constraints from `Package.swift`:

- Swift tools: `6.2`
- Platforms: `macOS 14+`, `iOS 17.4+`, `visionOS 26+`

## 2. High-Level Runtime Model

MirageKit is split into two runtime planes:

- Control plane
  Typed `ControlMessage` frames over a persistent control connection.
- Media plane
  UDP channels for video (`MIRG`), audio (`MIRA`), and quality test (`MIRQ`).

Session setup is explicit:

1. Control connection is established.
2. Loom authenticates the peer identity and runs trust evaluation.
3. Mirage opens its control stream on top of the authenticated Loom session and exchanges bootstrap request/response control messages to negotiate protocol compatibility and media registration state.
4. Client registers stream and audio channels.
5. Host begins sending media packets once registration succeeds. The first startup keyframe uses a temporary protection window with stronger keyframe FEC, tighter sender pacing, and a longer client-side startup timeout than steady-state traffic.

This separation keeps connection ownership, protocol negotiation, and media throughput concerns isolated from one another.

The control-plane transport boundary is strict:

- Loom owns the authenticated control session lifecycle, remote endpoint observation, path observation, and multiplexed stream transport.
- Mirage owns the `ControlMessage` schema, bootstrap semantics, and all post-bootstrap request/response handling carried over the Loom control stream.
- Raw `NWConnection` access is reserved for non-control transport concerns such as UDP media/audio/quality-test sockets and temporary file-transfer listeners.

## 3. Shared Target (`Sources/MirageKit`)

### 3.1 Wire Contracts

Core wire definitions live under `Internal/Protocol`:

- `ControlMessageType` defines the control taxonomy.
- `ControlMessage` is the framed envelope used on the control plane.
- `FrameHeader`, `AudioPacketHeader`, and `QualityTestPacketHeader` define the media-plane packet formats.
- Desktop stream startup uses explicit `desktopStreamStarted`, `desktopStreamFailed`, and `desktopStreamStopped` control messages so startup rejection is distinguishable from later transport loss.

The shared target also owns:

- protocol version and feature negotiation constants
- stream lifecycle message payloads
- app-stream inventory and icon streaming payloads
- shared clipboard status and update control message contracts
- menu bar and remote input message schemas
- software update message contracts

### 3.2 Shared Security

Security is composed out of a few narrow pieces:

- Loom-authenticated peer identity and trust evaluation
- session-derived media keys and registration tokens
- session-key encryption for shared clipboard text on the control plane
- per-packet authenticated encryption for video and audio payloads

`MirageMediaSecurity` is the package-local boundary for media key derivation, token validation, and packet encryption/decryption.

### 3.3 Shared Defaults and Helpers

`MirageKit` also owns package-wide defaults and helper APIs, including:

- `_mirage._tcp` service discovery naming
- shared device identifier keys
- CloudKit record naming helpers
- encoder configuration defaults and `MirageStreamColorDepth` tier mapping
- internal color-depth descriptors that resolve bit depth, color space, chroma sampling, capture formats, encoder profile candidates, and decoder output preferences
- quality test plans and stream policy types

These values stay in the shared target so host and client behavior remain aligned.

### 3.4 Diagnostics and Instrumentation

Mirage uses two separate internal observability layers:

- structured logging for runtime diagnostics
- `MirageInstrumentation` for milestone and performance timeline events

Instrumentation is intentionally cross-target so handshake, approval, capture, render, and unlock flows can be observed with one event vocabulary.

## 4. Host Target (`Sources/MirageKitHost`)

`MirageHostService` is the top-level coordinator for host runtime on macOS.

Its responsibilities include:

- advertising host availability and accepting control connections
- tracking connected clients and enforcing the single-client policy
- enumerating windows, apps, desktops, and login-display state
- starting and stopping stream sessions
- managing capture, encode, and packet send pipelines
- injecting remote input and activating host windows
- publishing menu bar state and handling menu actions
- exposing host-side software update status and install flows

Host startup is staged:

1. Start control and media listeners.
2. Publish host capabilities and metadata.
3. Refresh capture inventory.
4. Start cursor, session-state, and app-stream monitors.
5. Accept clients and provision per-client stream state on demand.

Desktop stream startup uses a two-layer virtual-display cache:

- a descriptor/profile cache in `CGVirtualDisplayBridge` keyed by machine + mode to prefer the last known-good private-API descriptor path
- a higher-level startup-target cache keyed by requested virtual-display settings so repeated starts can jump directly to the last known-good Retina or fallback target

Gross Retina activation mismatches, such as a requested ~`3008x1688` logical mode materializing as `800x600`, are treated as poisoned startup paths and aborted early instead of spending the full validation ladder on that descriptor profile.

The host keeps stream-specific policy local to the host runtime. That includes frame rate, bitrate, performance mode, window/app routing, virtual display ownership, and session-state behavior.

Connection approval is also host-owned policy. `MirageHostService` distinguishes two control-plane origins:

- local
  direct LAN or peer-to-peer sessions discovered through Bonjour or other local reachability
- remote
  direct QUIC sessions established from signaling-published presence

That origin is passed into `MirageHostDelegate` so the app target can apply different approval policy without leaking app-specific trust rules into the package. Local sessions keep the existing trust-provider and manual-approval flow. Remote sessions are explicit opt-in: the app must decide whether a specific trusted client is allowed to reconnect over the internet.

Remote signaling authorization is intentionally not a package-level trust primitive. MirageKit only carries the handshake origin and the signed authorization result. The Mirage app targets own the persistence and UI for per-client remote grants.

Color depth is now negotiated as a capability-driven tier instead of exposing raw bit depth on the wire:

- `standard`
  8-bit, sRGB, 4:2:0 (`NV12`)
- `pro`
  10-bit, Display P3, 4:2:0 (`P010`)
- `ultra`
  strict 10-bit 4:4:4 target (`xf44` preferred) that is only advertised when the host can validate the full path end to end

The host advertises supported color-depth tiers in peer metadata, clamps incoming requests to the highest supported tier, and logs downgrades when a requested tier is unavailable. `Ultra` support is probed by creating a temporary `xf44` HEVC session and validating the encoded SPS `chroma_format_idc`; active streams repeat that validation at runtime, export host-encoder and client-decoder fidelity telemetry over stream metrics, and automatically downgrade to `pro` if the encoder falls below 4:4:4.

Shared clipboard is also coordinated at the host-service layer. It is negotiated per connection, status is published over the control channel, and clipboard bridging only runs while the host session is `.ready` and at least one app or desktop stream is active. Both bridges treat the newest accepted clipboard update as authoritative, reject stale remote writes, and keep the last accepted remote text available for client-side manual paste sync until the local pasteboard advances again.

While interactive app or desktop startup/workload is active, the host defers nonessential reliable metadata replies such as app lists, app icons, host hardware icons, and software-update status. Only the latest pending request per client is retained and replayed once the workload returns to idle so startup control traffic stays ahead of bulk metadata on the Loom control stream.

QUIC connections require ALPN negotiation. Both host and client set `quicALPN` on `LoomNetworkConfiguration` to `["mirage-v2"]` so that the Loom transport layer passes the ALPN token through to `NWProtocolQUIC.Options`. Without ALPN, the TLS 1.3 handshake embedded in QUIC will fail.

Peer-to-peer (AWDL) transport is available on all client platforms (macOS, iOS, visionOS) and gated by the Mirage Pro subscription. When enabled, `includePeerToPeer = true` is set on `NWParameters` so the system can use AWDL/Wi-Fi Direct when a conventional infrastructure path is unavailable.

Remote signaling remains a direct-QUIC reachability system. Mirage does not forward control traffic through the signaling service; instead, the host publishes its reachable QUIC candidate and clients connect to that endpoint directly. Host-side publication now keeps the last successfully published QUIC candidate sticky across transient STUN probe failures or listener startup delays, and only clears that candidate when hosting stops, remote access is disabled, or the process restarts.

When the host accepts a Loom-authenticated control session, the bootstrap response includes whether that client is currently allowed to reconnect remotely. Clients cache that remote capability only after Loom has authenticated the peer identity and Mirage has accepted the bootstrap request.

## 5. Client Target (`Sources/MirageKitClient`)

`MirageClientService` is the top-level coordinator for client runtime.

Its responsibilities include:

- initiating control connections and handshake flow
- tracking connection state and approval state
- maintaining host window, app, and stream inventories
- registering for video, audio, and quality-test media
- decoding audio and video payloads
- forwarding local input events back to the host
- bridging shared clipboard updates with newest-update preference when the host enables the feature for the connection
- coordinating UI-facing state through `MirageClientSessionStore`

Client presentation is split from transport:

- `MirageFrameCache` and the decode pipeline own frame ingestion
- `MirageStreamViewRepresentable` owns presentation through `AVSampleBufferDisplayLayer`
- `MirageStreamContentView` bridges presentation, focus, resize, and input capture for app UI

That split keeps high-frequency media state out of SwiftUI update paths.

Recovery policy is package-owned inside `MirageKitClient`:

- desktop and app streams only clear client-side transport state from authoritative host stop/disconnect events
- desktop startup failures prefer the host's explicit `desktopStreamFailed` control message; the client-side startup timeout remains the fallback when the host never reaches a response path
- freeze detection distinguishes keyframe-starved stalls from packet-starved stalls
- the first active-stream freeze uses bounded recovery, while repeated freezes escalate to the existing hard reset path
- activation and hard-recovery resets now use a short first-frame watchdog and resend bounded keyframe requests until packet flow resumes
- adaptive color-depth fallback for custom quality mode steps `ultra -> pro -> standard` and restores in the reverse order

Client connection establishment tries UDP first when the peer advertises it, then falls back to the advertised TCP endpoint when the UDP control path times out or fails with a retryable pre-bootstrap transport classification. The client resolves endpoints through Bonjour service discovery and connects using the Loom node's `connect()` method, which handles transport parameter construction including ALPN for QUIC. Direct UDP control attempts treat the advertised `hostName` as an explicit mDNS hostname when present, and otherwise derive a `.local` Bonjour host from the discovered peer name instead of treating the UI service name as a routable hostname. Each transport attempt uses the existing control-session timeout budget.

The client also tracks whether the connected host explicitly granted remote signaling access in the accepted hello response. MirageKit does not decide how that grant is surfaced in app UI, but it exposes the signed result so the app can remember remote-capable hosts independently from CloudKit sharing.

## 6. Bootstrap Runtime (`Sources/MirageHostBootstrapRuntime`)

The bootstrap runtime is responsible for pre-login and unlock-oriented host control.

Key types are:

- `MirageHostBootstrapConfiguration`
- `MirageHostBootstrapUnlockService`
- `MirageHostBootstrapDaemonStateMachine`

This target owns:

- bootstrap configuration serialization and metadata projection
- unlock orchestration
- daemon state transitions
- app-group queue handoff into the host app

Authenticated bootstrap network serving is provided by Loom's `LoomBootstrapControlServer`.

Keeping that logic in its own product prevents the main host runtime from carrying daemon-only policy and lifecycle state.

## 7. Invariants

Keep these boundaries intact:

- Shared wire contracts belong in `MirageKit`.
- Host-only capture, encode, and input behavior belongs in `MirageKitHost`.
- Client-only decode, presentation, and input-capture behavior belongs in `MirageKitClient`.
- Bootstrap and unlock orchestration belong in `MirageHostBootstrapRuntime`.
- Do not introduce parallel transport or discovery stacks inside feature-specific subsystems.
- Remove dead code instead of leaving compatibility shims behind.
- Update this document in the same change whenever package boundaries or message flow change.
