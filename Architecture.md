# MirageKit Architecture

This document explains MirageKit at a high level.

It focuses on the end-to-end streaming pipeline:

- capture on the host
- encode and packetize on the host
- transport between peers
- decode and presentation on the client
- input translation back to the host

It does not try to catalog every type, message, cache, heuristic, or fallback path in the package. Those details belong in the implementation.

## Package Boundaries

MirageKit is split into four products:

- `MirageKit`
  Shared protocol definitions, stream models, defaults, diagnostics, and security helpers.
- `MirageKitClient`
  Client connection state, media receive/decode, presentation, and input forwarding.
- `MirageKitHost`
  Host connection orchestration, capture, encode, media send, and input injection.
- `MirageHostBootstrapRuntime`
  Host bootstrap support for pre-login and daemon-controlled flows.

At a system level, MirageKit has two planes:

- control plane
  Reliable session setup, capability negotiation, stream lifecycle, status, and commands.
- media plane
  Low-latency video and audio transport for active streams.

The control plane decides what should happen. The media plane carries the frames and audio that make the session feel live.

## End-to-End Flow

A normal interactive session looks like this:

1. A client establishes a control connection to the host.
2. The peers authenticate, negotiate capabilities, and agree on stream parameters.
3. The host confirms that the session can occupy the single interactive client slot.
4. The host starts capture for the requested desktop or app content.
5. Captured frames are converted into the format expected by the active encoder.
6. The host encodes video, packetizes media, and sends it over the media plane.
7. The client receives packets, reassembles frames, decodes video and audio, and schedules presentation.
8. Local keyboard, pointer, touch, and system actions are translated into host-side input events and sent back over the control plane.

That loop continues until the stream is stopped or the session ends.

## Session Availability

Host availability is part of the shared session contract rather than a UI-only hint.

The host publishes whether it can accept a new interactive client, whether it is temporarily busy, and whether it is in software-update maintenance. A client may request takeover of a busy host during bootstrap. The host remains the authority: trusted takeover requests can replace the existing client, while untrusted or non-takeover requests are rejected with an explicit reason.

Short client backgrounding is modeled as a bounded lease. During that lease the host can preserve quick resume semantics without leaving an unbounded stale reservation. When the lease expires or reconciliation fails, the host releases the slot and republishes availability.

## Host Pipeline

### 1. Capture

The host is responsible for turning macOS content into a streamable source.

Depending on the session, that can mean:

- capturing a desktop
- capturing one or more app windows
- consuming an application-provided custom source
- managing a virtual display for remote-only desktops
- tracking geometry, cursor policy, and stream lifecycle

Capture is host-owned because the host has direct access to the real window server, display topology, and input focus.

App streaming uses direct window capture for active windows. When multiple logical app windows are active for one client, the host composites their captured frames into one physical app-atlas media stream and reports each logical window's atlas region over the control plane. Client views share that media stream and crop to their logical window, while input, resize, focus, and close commands continue to target the logical stream ID.

Capture cadence is measured as part of the host pipeline. The host records compact wall-clock, ScreenCaptureKit timing, status, and callback-duration telemetry for active streams, then reports interval snapshots through stream metrics. If desktop capture cadence remains bad while encode, send, and queue health are otherwise clean, MirageKit first restarts ScreenCaptureKit capture and only escalates to virtual-display timing recovery under cooldown.

Custom streams keep this ownership model but move source-specific capture behind an app-provided `MirageCustomStreamSource`. MirageKit negotiates the stream, owns encoding, transport, decode, presentation, and input forwarding, while the host app owns what the stable custom kind means and how frames are produced.

### 2. Encode

Once the host has frames, it prepares them for network delivery.

At a high level, the host:

- chooses the active stream geometry and color pipeline
- feeds frames into the video encoder
- produces compressed video frames and audio packets
- encrypts and packetizes media for transport

This stage is where Mirage trades raw pixels for something that can move across a peer-to-peer network with low enough latency to feel interactive.

### 3. Send

After encoding, the host sends media over the media plane while continuing to use the control plane for commands and stream state.

The host remains the authority for:

- when a stream starts and stops
- what content is currently being captured
- bitrate, frame-rate, and quality policy
- host-side session state such as cursor mode, clipboard availability, and host maintenance status

MirageKit keeps media freshness and capture recovery policy above Loom. Loom moves the unreliable packets between peers, while MirageKit's sender still understands frame boundaries, keyframes, startup state, target frame budgets, and host capture cadence. That lets the host pace live media for the current frame interval, preserve keyframe and recovery boundaries, reset stale queued media before asking the encoder for a recovery keyframe, and recover ScreenCaptureKit or virtual-display timing without treating it as a transport problem.

Adaptive quality changes use live receiver and host telemetry first. Active-stream promotion probes are shaped like streaming traffic, remain subordinate to media, climb gradually, and keep cooldown history when probing is suppressed. A probe that overlaps frame gaps, freezes, or loss is treated as a negative signal for future targets.

## Client Pipeline

### 1. Receive

The client receives control messages and media packets independently.

The client uses the control plane to understand session state and uses the media plane to ingest the live stream itself. This separation keeps transport and UI coordination from collapsing into one channel.

### 2. Decode

The client reassembles incoming media, validates and decrypts it, and hands it to the decode pipeline.

At a high level, the client is responsible for:

- receiving packetized video and audio
- reconstructing encoded frames
- decoding into presentation-ready media buffers
- handling timing and frame replacement under real network conditions

Audio playback is generation-gated across reconnects. Decoded audio is only scheduled after the playback graph is configured for the active stream generation and format; stale or mismatched frames are discarded.

### 3. Display

Decoded frames are then scheduled onto the platform presentation layer.

The client presentation side is intentionally separate from transport and decode so that:

- high-frequency media updates do not drive SwiftUI state directly
- display timing can be tuned for responsiveness
- local UI concerns such as resizing, focus, and overlays stay outside the core transport path

The result is a presentation pipeline whose job is simple: show the newest valid frame as smoothly and quickly as possible.

## Input Translation

Mirage is not just video playback. The return path matters just as much.

The client captures local interaction and translates it into host-meaningful input:

- keyboard events
- pointer movement and clicks
- touch or gesture-driven pointer behavior
- scroll input
- host actions such as menu or system commands

The host receives those commands and injects them into the local macOS environment.

High-frequency stylus input is still control-plane intent, but it has live-stream freshness rules. Pencil contact samples are batched in order so drawing strokes preserve coalesced pressure, tilt, roll, and position samples. Hover is batched as lower-priority input: small jitter is ignored, stale hover can be replaced, and bounded queues keep hover from delaying contact drawing or discrete keyboard and click events.

For custom streams, the host can register a source-specific input handler. The protocol still carries normalized `MirageInputEvent` values; MirageKit routes those events to the custom handler instead of applying desktop or app-window injection policy.

This keeps Mirage's model clean:

- the client owns local interaction capture
- the protocol carries normalized intent and custom action bindings across the control plane
- the host owns final input injection against real host state

Keyboard translation separates special keys from printable text. Platform-specific key strings such as Escape use host key codes, while Unicode fallback is reserved for actual text input. Custom bindings are represented as Mirage actions so shortcuts, display metadata, and host key injection share the same preference model as built-in controls.

## Shared Clipboard

Shared clipboard state is coordinated over the control plane while media continues on its separate path.

The host and client exchange clipboard declarations with ordering tokens so a newer host copy can suppress stale client pasteboard content without requiring the client to read its local pasteboard. Transferable clipboard contents are sent as encrypted chunks only when the representation is supported and bounded. Oversized or unsupported contents still advance shared clipboard ordering through metadata, so paste into the remote Mac can use the host's current pasteboard directly.

On iPadOS, Mirage watches pasteboard change counts and system pasteboard change notifications while a stream is active, but it reads pasteboard contents only during an explicit paste action that needs to send local client data to the host. Host-side pasteboard observation can inspect macOS pasteboard contents directly and mirrors small supported text, image, and file payloads back to the client OS clipboard.

## Diagnostics

Diagnostics are split by their relationship to the live stream.

Hot-path telemetry records compact counters, timings, and fixed-size events into preallocated buffers. Encode, packet send, receive, reassembly, decode, and media delivery paths may record primitive values such as frame gaps, queue depth, pacing sleep, sender delay, and frame-size buckets, but they do not format logs, write files, or perform expensive forensic work synchronously.

Forensic diagnostics are explicit and bounded. Frame integrity checks such as CRC and header capture are collected only through opt-in diagnostic sessions, sampled under limits, and formatted away from the media path. Support-log export can format buffered telemetry later, when producing diagnostic artifacts rather than while frames are moving.

Steady-state aggregate log lines are also explicit diagnostics. Broad logging settings do not make live streams emit fixed-cadence capture, encode, packet, control, or view-update summaries; those human-readable snapshots are reserved for targeted diagnostic sessions.

## Host Software Updates

Software updates are coordinated through the control plane.

The host owns Sparkle interaction and publishes software-update status snapshots to clients. Those snapshots include the operation phase, progress, cancellability, available version metadata, and terminal error details. Client-triggered updates keep the requesting control connection alive through checking, download, and extraction; the host enters maintenance and disconnects clients only when install or relaunch handoff is ready.

Checking for updates is distinct from installing updates. A host-side watchdog turns a stuck checking session into a terminal idle or failed state so clients and discovery never have to infer update state from silence.

## Shared Responsibilities

Some responsibilities are shared across host and client because both sides have to agree on them:

- protocol messages and versioning
- stream identifiers and lifecycle semantics
- media security and session keys
- geometry and stream-configuration contracts
- custom stream descriptors, requests, and frame/input contracts
- host availability, takeover, background lease, and update-status semantics
- diagnostics vocabulary

These shared contracts live in `MirageKit` so the host and client remain aligned.

## Architectural Invariants

The following rules should remain true unless the architecture itself is being changed:

- the host is the authority for capture, stream production, and final input injection
- the client is the authority for decode, presentation, and local interaction capture
- control traffic and media traffic stay logically separate
- shared protocol, security, and stream contracts live in `MirageKit`, not in host- or client-only targets
- session negotiation completes before interactive media starts flowing
- host availability is resolved by the host during bootstrap, not inferred only from stale discovery state
- input is transported as protocol-level intent and resolved against real host state on the host side

## Design Intent

MirageKit is structured around a few stable architectural ideas:

- host owns capture and input injection
- client owns decode and presentation
- control and media stay separate
- shared contracts live in one place
- session negotiation is explicit before media starts flowing

If a future change affects how capture, encode, transport, decode, display, or input translation work together, update this document. If it only changes a specific implementation strategy, keep that detail in code comments or focused subsystem documentation instead.
