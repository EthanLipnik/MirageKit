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
2. Signed hello and hello-response messages validate identity and protocol compatibility.
3. Host returns media registration state and session-specific transport metadata.
4. Client registers stream and audio channels.
5. Host begins sending media packets once registration succeeds.

This separation keeps connection ownership, protocol negotiation, and media throughput concerns isolated from one another.

## 3. Shared Target (`Sources/MirageKit`)

### 3.1 Wire Contracts

Core wire definitions live under `Internal/Protocol`:

- `ControlMessageType` defines the control taxonomy.
- `ControlMessage` is the framed envelope used on the control plane.
- `FrameHeader`, `AudioPacketHeader`, and `QualityTestPacketHeader` define the media-plane packet formats.

The shared target also owns:

- protocol version and feature negotiation constants
- stream lifecycle message payloads
- app-stream inventory and icon streaming payloads
- menu bar and remote input message schemas
- software update message contracts

### 3.2 Shared Security

Security is composed out of a few narrow pieces:

- signed hello payloads with deterministic encoding
- replay protection for handshake and bootstrap flows
- session-derived media keys and registration tokens
- per-packet authenticated encryption for video and audio payloads

`MirageMediaSecurity` is the package-local boundary for media key derivation, token validation, and packet encryption/decryption.

### 3.3 Shared Defaults and Helpers

`MirageKit` also owns package-wide defaults and helper APIs, including:

- `_mirage._tcp` service discovery naming
- shared device identifier keys
- CloudKit record naming helpers
- encoder configuration defaults
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

The host keeps stream-specific policy local to the host runtime. That includes frame rate, bitrate, performance mode, window/app routing, virtual display ownership, and session-state behavior.

## 5. Client Target (`Sources/MirageKitClient`)

`MirageClientService` is the top-level coordinator for client runtime.

Its responsibilities include:

- initiating control connections and handshake flow
- tracking connection state and approval state
- maintaining host window, app, and stream inventories
- registering for video, audio, and quality-test media
- decoding audio and video payloads
- forwarding local input events back to the host
- coordinating UI-facing state through `MirageClientSessionStore`

Client presentation is split from transport:

- `MirageFrameCache` and the decode pipeline own frame ingestion
- `MirageStreamViewRepresentable` owns presentation through `AVSampleBufferDisplayLayer`
- `MirageStreamContentView` bridges presentation, focus, resize, and input capture for app UI

That split keeps high-frequency media state out of SwiftUI update paths.

## 6. Bootstrap Runtime (`Sources/MirageHostBootstrapRuntime`)

The bootstrap runtime is responsible for pre-login and unlock-oriented host control.

Key types are:

- `MirageHostBootstrapConfiguration`
- `MirageHostBootstrapControlServer`
- `MirageHostBootstrapUnlockService`
- `MirageHostBootstrapDaemonStateMachine`

This target owns:

- bootstrap request handling
- bootstrap configuration serialization and metadata projection
- unlock orchestration
- daemon state transitions
- app-group queue handoff into the host app

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
