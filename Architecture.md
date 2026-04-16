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
3. The host starts capture for the requested desktop or app content.
4. Captured frames are converted into the format expected by the active encoder.
5. The host encodes video, packetizes media, and sends it over the media plane.
6. The client receives packets, reassembles frames, decodes video and audio, and schedules presentation.
7. Local keyboard, pointer, touch, and system actions are translated into host-side input events and sent back over the control plane.

That loop continues until the stream is stopped or the session ends.

## Host Pipeline

### 1. Capture

The host is responsible for turning macOS content into a streamable source.

Depending on the session, that can mean:

- capturing a desktop
- capturing one or more app windows
- managing a virtual display for remote-only desktops
- tracking geometry, cursor policy, and stream lifecycle

Capture is host-owned because the host has direct access to the real window server, display topology, and input focus.

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
- host-side session state such as cursor mode and clipboard availability

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

This keeps Mirage's model clean:

- the client owns local interaction capture
- the protocol carries normalized intent across the control plane
- the host owns final input injection against real host state

## Shared Responsibilities

Some responsibilities are shared across host and client because both sides have to agree on them:

- protocol messages and versioning
- stream identifiers and lifecycle semantics
- media security and session keys
- geometry and stream-configuration contracts
- diagnostics vocabulary

These shared contracts live in `MirageKit` so the host and client remain aligned.

## Architectural Invariants

The following rules should remain true unless the architecture itself is being changed:

- the host is the authority for capture, stream production, and final input injection
- the client is the authority for decode, presentation, and local interaction capture
- control traffic and media traffic stay logically separate
- shared protocol, security, and stream contracts live in `MirageKit`, not in host- or client-only targets
- session negotiation completes before interactive media starts flowing
- input is transported as protocol-level intent and resolved against real host state on the host side

## Design Intent

MirageKit is structured around a few stable architectural ideas:

- host owns capture and input injection
- client owns decode and presentation
- control and media stay separate
- shared contracts live in one place
- session negotiation is explicit before media starts flowing

If a future change affects how capture, encode, transport, decode, display, or input translation work together, update this document. If it only changes a specific implementation strategy, keep that detail in code comments or focused subsystem documentation instead.
