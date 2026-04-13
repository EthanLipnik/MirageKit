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
  UDP channels for video (`MIRG`) and audio (`MIRA`), plus Loom multiplexed media streams for video (`video/<streamID>`), audio (`audio/<streamID>`), and connection testing (`quality-test/<uuid>`).

Session setup is explicit:

1. Control connection is established.
2. Loom authenticates the peer identity and runs trust evaluation.
3. Mirage opens its control stream on top of the authenticated Loom session and exchanges bootstrap request/response control messages to negotiate protocol compatibility and media registration state.
   When bootstrap is rejected, the host still delivers the rejection response on the control stream and then closes only that stream in-order so the client can surface the real rejection reason before either peer tears the full Loom session down.
4. Client registers stream and audio channels.
5. Host begins sending media packets once registration succeeds. The first startup keyframe uses a temporary protection window with stronger keyframe FEC, tighter sender pacing, and a longer client-side startup timeout than steady-state traffic.

Steady-state media transport is explicitly bounded. Loom owns ordered unreliable media submission with queue profiles instead of one global budget: latency-sensitive interactive media keeps the default shallow outstanding datagram/byte budget (`1024` packets / `2 MB`), while explicit throughput probes can request a much deeper queue sized to saturate fast local links (`262_144` packets / `512 MB`). Mirage host-side packet pacing applies to both keyframes and P-frames. Mirage clears post-keyframe P-frame holds once packets have been handed to Loom rather than waiting for network completion callbacks. Under sustained transport pressure, the host prefers dropping stale P-frames over spending bandwidth on already-obsolete intermediate frames, and the client can fast-forward to a newer in-progress keyframe instead of waiting through a long forward-gap stall. Host quality relief, client receiver-health backoff, and bottleneck classification all treat queue growth, packet-budget overrun, packet-pacer sleep, transport drops, and real encoded-to-delivered deficits as primary transport stress; send-delay averages stay advisory unless one of those primary signals is already present. Higher layers can also reset one queued-unreliable profile without closing the whole Loom stream, which Mirage uses to flush stale throughput-probe backlog after an overload boundary.

This separation keeps connection ownership, protocol negotiation, and media throughput concerns isolated from one another.

The control-plane transport boundary is strict:

- Loom owns the authenticated control session lifecycle, remote endpoint observation, path observation, and multiplexed stream transport, including ad-hoc file transfers such as host support-log export.
- Mirage owns the `ControlMessage` schema, bootstrap semantics, and all post-bootstrap request/response handling carried over the Loom control stream.
- Raw `NWConnection` access is reserved for non-control transport concerns such as UDP media/audio sockets.

## 3. Shared Target (`Sources/MirageKit`)

### 3.1 Wire Contracts

Core wire definitions live under `Internal/Protocol`:

- `ControlMessageType` defines the control taxonomy.
- `ControlMessage` is the framed envelope used on the control plane.
- `FrameHeader`, `AudioPacketHeader`, and `QualityTestPacketHeader` define the media-plane packet formats.
- Desktop stream startup uses explicit `desktopStreamStarted`, `desktopStreamFailed`, and `desktopStreamStopped` control messages so startup rejection is distinguishable from later transport loss.
- Desktop cursor presentation is negotiated per desktop stream with `StartDesktopStreamMessage.cursorPresentation` and updated in place at runtime with `desktopCursorPresentationChange`.
- Stream-start requests carry geometry, encoder, and cursor policy, but not refresh-rate policy. New app, window, and desktop streams start at the default host frame rate and then receive any client refresh override through the live `streamRefreshRateChange` control message after startup is established.

The shared target also owns:

- protocol version and feature negotiation constants
- stream lifecycle message payloads
- app-stream inventory and icon streaming payloads
- shared clipboard status and update control message contracts
- menu bar and remote input message schemas, including host-owned system-action requests that resolve against the host's symbolic-hotkey configuration at execution time
- software update message contracts

### 3.2 Shared Security

Security is composed out of a few narrow pieces:

- Loom-authenticated peer identity and trust evaluation
- session-derived media keys and registration tokens
- AES-256-GCM session-key encryption for shared clipboard text on the control plane
- AES-256-GCM per-packet authenticated encryption for video and audio payloads

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
- tracking connected clients, surfacing availability through discovery metadata, and enforcing the single-client policy
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
- a desktop-resize target cache keyed by requested pixel resolution, refresh rate, HiDPI mode, and color space so repeated live resizes can retry the last known-good target before falling back to a broader recreate ladder

Gross Retina activation mismatches, such as a requested ~`3008x1688` logical mode materializing as `800x600`, are treated as poisoned startup paths and aborted early instead of spending the full validation ladder on that descriptor profile.

Desktop virtual-display startup is session-owned rather than manager-owned. `DesktopVirtualDisplayStartupSession` plans preferred, descriptor-fallback, and conservative attempts up front, classifies failures by activation vs readiness/Space binding, and decides which rung is eligible next. `SharedVirtualDisplayManager` owns the OS object lifecycle, but the desktop path asks it to execute one explicit creation attempt at a time.

Live desktop resize follows the same explicit policy. The host first asks `SharedVirtualDisplayManager` for an in-place update preview, only suspends and restores mirroring when that preview proves recreation is required, and reuses the desktop-resize target cache to prefer a previously validated recreate path. Failed cached resize targets are evicted immediately instead of being retried through the rest of the session. Resize-driven host recovery keyframes are staged immediately before encoding resumes instead of during the capture reset itself so the `desktopStreamStarted` token advance can arrive before the first post-resize keyframe.

The host keeps stream-specific policy local to the host runtime. That includes frame rate, bitrate, performance mode, window/app routing, virtual display ownership, and session-state behavior.

Desktop cursor presentation is also session-owned host policy for desktop streams. The client chooses between:

- `Client`
  the host keeps `ScreenCaptureKit` cursor capture disabled and the client uses its own local cursor presentation
- `Simulated`
  the host keeps `ScreenCaptureKit` cursor capture disabled and the client renders Mirage's software cursor presentation
- `Host`
  the host sets `showsCursor = true` on desktop display capture and keeps that value sticky across resize, refresh-rate, display-switch, and encoder reconfiguration updates

Runtime cursor-presentation overrides do not restart the desktop stream. The host updates the active desktop stream context's `captureShowsCursor` state and applies the new `ScreenCaptureKit` configuration in place.

App-stream visible slots are lifecycle-bound to the app session rather than permanently bound to the first discovered host window ID. During initial startup, the host keeps trying to fill each visible slot until the startup deadline expires, re-evaluating the app's current eligible primary windows after launcher, document-picker, or first-window churn. After startup, the host preserves the current streamed primary window until that window closes or otherwise fails out of the slot lifecycle, at which point the slot-replacement path can rebind the same stream identity to another eligible primary window from the same app.

The host keeps one shared app-stream virtual display mirrored from the current physical-display set. App-stream capture is display-based, not `desktopIndependentWindow`-based: each visible slot resolves a window cluster made of the selected primary window plus attached supplementary descendants, applies a display filter that includes only those windows, and crops that cluster with `sourceRect`. The encoded canvas stays fixed for the life of the slot stream; live app resize and supplementary-window churn update only the display filter plus `sourceRect` / `destinationRect`, so the client receives a stable encoded stream with a moving `contentRect` instead of a resize-driven encoder reset and recovery keyframe. The wire/session model is still window-centric: the active visible slot is the live stream, while other visible slots use the passive snapshot tier.

Connection approval is also host-owned policy. `MirageHostService` distinguishes two control-plane origins:

- local
  direct LAN or peer-to-peer sessions discovered through Bonjour or other local reachability
- remote
  direct QUIC sessions established from signaling-published presence

That origin is passed into `MirageHostDelegate` so the app target can apply different approval policy without leaking app-specific trust rules into the package. Local sessions use the trust-provider and manual-approval flow. Remote sessions are explicit opt-in: the app must decide whether a specific trusted client is allowed to reconnect over the internet.

Manual approval happens during the Loom-authenticated control-session bootstrap, before the session reaches `.ready`. When the host signals pending approval, `MirageClientService` keeps the waiting UI alive on a longer approval-specific timeout budget instead of reusing the shorter transport-latency timeout used for normal control-session establishment.

Remote signaling authorization is intentionally not a package-level trust primitive. MirageKit only carries the handshake origin and the signed authorization result. The Mirage app targets own the persistence and UI for per-client remote grants.

Color depth is negotiated as a capability-driven tier:

- `standard`
  8-bit, sRGB, 4:2:0 (`NV12`)
- `pro`
  10-bit, Display P3, 4:2:0 (`P010`)
- `ultra`
  strict 10-bit 4:4:4 target (`xf44` preferred) that is only advertised when the host can validate the full path end to end

The host advertises supported color-depth tiers in peer metadata, clamps incoming requests to the highest supported tier, and logs downgrades when a requested tier is unavailable. `Ultra` support is probed by creating a temporary `xf44` HEVC session and validating the encoded SPS `chroma_format_idc`; active streams repeat that validation at runtime, export host-encoder and client-decoder fidelity telemetry over stream metrics, and automatically downgrade to `pro` if the encoder falls below 4:4:4.

Shared clipboard is also coordinated at the host-service layer. It is negotiated per connection, status is published over the control channel, and clipboard bridging only runs while the host session is `.ready` and at least one app or desktop stream is active. Both bridges treat the newest accepted clipboard update as authoritative, reject stale remote writes, and keep the last accepted remote text available for client-side manual paste sync until the local pasteboard advances again.

Client-owned stream options use the same control-plane pattern. The client mirrors its current stream-options display mode and status-overlay preference back to the host, and the host can issue remote stream-options commands that ask the client to switch between `In Stream` and `Host Menu Bar`, toggle the status overlay, update active desktop cursor presentation, or stop a specific active app/desktop stream from the client side without introducing a second authority for those preferences.

While interactive app or desktop startup/workload is active, the host defers bulk app-list refresh work. Smaller host metadata replies such as inline wallpaper, hardware icon, and software-update status bypass that gate so startup control traffic does not starve connected-selection UI refreshes behind the app-list queue.

QUIC connections require ALPN negotiation. Both host and client set `quicALPN` on `LoomNetworkConfiguration` to `["mirage-v2"]` so that the Loom transport layer passes the ALPN token through to `NWProtocolQUIC.Options`. Without ALPN, the TLS 1.3 handshake embedded in QUIC will fail.

Peer-to-peer (AWDL) transport is available on all client platforms (macOS, iOS, visionOS) and gated by the Mirage Pro subscription. When enabled, `includePeerToPeer = true` is set on transport and Bonjour discovery parameters so the system can use AWDL/Wi-Fi Direct when a conventional infrastructure path is unavailable. When peer-to-peer is disabled, Mirage does not browse or advertise Bonjour services over peer-to-peer interfaces.

Remote signaling is a direct-QUIC reachability system. Mirage does not forward control traffic through the signaling service; instead, the host publishes its reachable QUIC candidate and clients connect to that endpoint directly. Host-side publication keeps the last successfully published QUIC candidate sticky across transient STUN probe failures or listener startup delays, and only clears that candidate when hosting stops, remote access is disabled, or the process restarts. The same publication also carries whether the host is currently accepting a new client session, matching the Bonjour advertisement metadata so occupied hosts surface as busy before a second client retries the bootstrap path.

When the host accepts a Loom-authenticated control session, the bootstrap response includes whether that client is currently allowed to reconnect remotely. Clients cache that remote capability only after Loom has authenticated the peer identity and Mirage has accepted the bootstrap request.

## 5. Client Target (`Sources/MirageKitClient`)

`MirageClientService` is the top-level coordinator for client runtime.

Its responsibilities include:

- initiating control connections and handshake flow
- tracking connection state and approval state
- maintaining host window, app, and stream inventories
- registering for video and audio media, and receiving quality-test media over dedicated Loom streams
- decoding audio and video payloads
- forwarding local input events back to the host
- bridging shared clipboard updates with newest-update preference when the host enables the feature for the connection
- coordinating UI-facing state through `MirageClientSessionStore`

Client presentation is split from transport:

- `MirageRenderStreamStore` and the decode pipeline own latest-frame ingestion
- `MirageRenderPresentationScheduler` owns main-actor submission policy, coalescing, and display-link fallback for interactive streams
- `MirageSampleBufferPresenter` owns sample-buffer mapping and `AVSampleBufferDisplayLayer` enqueue
- `MirageStreamViewRepresentable` owns presentation through `MirageSampleBufferView` and `AVSampleBufferDisplayLayer`
- `MirageStreamContentView` bridges presentation, focus, resize, and input capture for app UI

That split keeps high-frequency media state out of SwiftUI update paths.

Manual quality tests are single-owner session work. The client marks a quality test active before RTT sampling begins, suppresses heartbeat probes for the duration of that work, and cancels the active test before any interactive app or desktop stream startup begins. Cancellation is explicit on the control channel, so the host tears down the detached `quality-test/<uuid>` Loom stream and resets the throughput-probe queue profile instead of letting stale queued replay traffic continue alongside virtual-display startup or other interactive stream work. Host-side quality-test traffic uses Loom's deeper throughput-probe ordered-unreliable queue profile so the test can find the path's actual overload boundary without relaxing the shallow queue limits used by interactive media streams.

Each quality-test stage has two budgets: a fixed measurement window (`durationMs`) and a bounded settle grace (`settleGraceMs`). The host reports both the fixed measurement end and the final completion time, and the client computes throughput from the fixed measurement window instead of from queue-drain time. If the host cannot keep the fixed window fed, or if throughput-probe packets are still backed up when settle grace expires, the host marks `deliveryWindowMissed = true`, flushes remaining throughput-probe backlog, and reports the stage as an overload boundary even when packet loss is still zero. Automatic quality selection runs only the replay-shaped stages so startup time is spent measuring stream-safe behavior directly. Connection-limit probes can sweep raw transport and replay traffic separately, stop on the first completed stage that reaches `1%` packet loss, and only count stages that stay below `1%` loss without missing the delivery window when reporting transport headroom or streaming-safe bitrate.

Desktop cursor presentation is resolved on the client from a shared `MirageDesktopCursorPresentation` value:

- `source = client`
  suppress host cursor capture, use the platform cursor presentation on the client, and keep cursor-position updates available so the client can mirror host cursor state when needed
- `source = simulated`
  suppress host cursor capture, render Mirage's software cursor presentation, always lock the local cursor for secondary-display desktop streams, and optionally lock mirrored desktop streams through `lockClientCursorWhenUsingMirageCursor`
- `source = host`
  suppress Mirage's synthetic cursor presentation, rely on the captured host cursor in the video stream, and use `lockClientCursorWhenUsingHostCursor` as the client-lock policy

Desktop startup carries that value in `startDesktopStream(...)`, and active desktop sessions can update it without reconnecting. The client render layer keeps cursor lock, local cursor hiding, and synthetic cursor drawing as separate switches so pointer lock can remain active even when the synthetic cursor is disabled. Temporary client-side unlock and recapture are layered above that configuration: pressing unmodified Escape suspends local cursor lock for the active desktop session, and the next local click/tap re-engages it without mutating the saved cursor presentation.
Desktop cursor position updates remain required for secondary-display sessions and also stay enabled for client-cursor and host-cursor desktop sessions so clients can mirror local cursor state to the host position whenever pointer lock is disabled.
For secondary-display sessions, those normalized cursor positions are intentionally allowed to move outside `0...1` while the host cursor crosses onto another host display, which lets locked-cursor input push across display edges instead of pinning at the streamed display border.

Stream sizing is also package-owned through a single canonical resolver. `MirageStreamGeometry` is the shared internal contract used by client startup, host startup, and live resize to resolve logical size, backing scale, encoded size, and capped stream scale from the same inputs. That keeps requested, visible, and encoded geometry from diverging across the client and host codepaths.

Media packet sizing is negotiated per quality test and per stream startup. Clients request a preferred maximum packet size based on the current control-path safety profile, the host clamps that request against its current path classification, and the accepted value is echoed back in startup replies so packetization, reassembly, quality tests, and in-stream probes all use the same payload budget. Direct local paths such as AWDL and wired can use `1400`-byte media packets; all other paths stay on the conservative `1200`-byte profile until explicit MTU probing exists.

Client audio presentation also uses a shared ownership boundary on iOS and visionOS:

- `AudioPlaybackController` owns buffered stream playback
- `InputCapturingView` owns dictation capture and result emission
- `MirageClientAudioSessionCoordinator` arbitrates the shared `AVAudioSession` so playback and dictation can coexist without deactivating each other

That coordination keeps audio-session policy centralized instead of letting playback and dictation independently reconfigure the shared session.

Recovery policy is package-owned inside `MirageKitClient`:

- desktop and app streams only clear client-side transport state from authoritative host stop/disconnect events
- desktop startup failures prefer the host's explicit `desktopStreamFailed` control message; the client-side startup timeout remains the fallback when the host never reaches a response path
- desktop resize completions are ordered by `dimensionToken`; once a desktop stream has observed a tokenized start, stale duplicate, older, or missing-token `desktopStreamStarted` echoes are ignored instead of mutating active resize acknowledgement state
- freeze detection distinguishes keyframe-starved stalls from packet-starved stalls
- the first active-stream freeze uses bounded recovery, while repeated freezes escalate to the hard reset path
- activation and hard-recovery resets use a short first-frame watchdog and resend bounded keyframe requests until packet flow resumes
- post-resize recovery keeps keyframe-only decode admission armed until the first newly presented frame, decode-error threshold recovery waits through a short post-resize grace window before requesting another recovery keyframe, and coalesced follow-up desktop resizes stay queued until that first presented frame lands
- app-owned adaptive bitrate recovery is shared by automatic quality mode and custom recovery mode; the receiver-health controller reads client metrics snapshots, ignores startup and resize/scale reconfiguration windows while the client startup-critical section is active, applies the 15%/25% backoff rules only for transport-pressure signals such as send-queue growth, pacing delay, packet drops, or delivery falling behind the host's actual encoded cadence, and probes back upward after sustained non-stressed transport windows without treating source, encode, or decode cadence as a probe gate
- host transport-pressure fields exported through `StreamMetricsMessage` are sampled per metrics-update window rather than lifetime cumulative totals; send-queue depth remains a current-state value, while packet drops and send-delay aggregates are consumed after each emission so transient startup or reset churn does not poison later receiver-health classification
- automatic-mode startup begins from a path-seeded bitrate (`48 Mbps` on AWDL, wired, and loopback paths; `24 Mbps` on Wi-Fi; `10 Mbps` on cellular, other, and unknown paths) and uses the fast-start adaptive loop to climb toward the geometry-driven ceiling once first-frame delivery stabilizes
- automatic-mode bitrate ceilings are geometry-driven rather than path-gated: preset resolution, color depth, and target FPS stay fixed, while bitrate ramps toward the visually saturated HEVC target for that geometry instead of collapsing to a lower preset because the current link is not direct-local
- automatic quality mode and custom `Adaptive` recovery both use the same client-owned bitrate backoff and probe loop; the host does not apply a separate framerate-first degradation path during source stalls
- adaptive sessions keep their requested FPS and color depth fixed on the client side, bounded only by the user-configured custom bitrate ceiling or the automatic-mode geometry ceiling
- single-window app streaming uses the same live-stream cadence and bitrate semantics as desktop streaming, while multi-window app sessions keep exactly one active live stream and throttle only non-focused visible windows down to `1 FPS` snapshot cadence without introducing a separate low-quality mode

Client connection establishment tries UDP first when the peer advertises it, then falls back to the advertised TCP endpoint when the UDP control path times out or fails with a retryable pre-bootstrap transport classification. The client resolves endpoints through Bonjour service discovery and connects using the Loom node's `connect()` method, which handles transport parameter construction including ALPN for QUIC. Direct UDP control attempts treat the advertised `hostName` as an explicit mDNS hostname when present, and otherwise derive a `.local` Bonjour host from the discovered peer name instead of treating the UI service name as a routable hostname. When an established session resolves the host to a concrete direct endpoint, Mirage remembers that non-Bonjour host per device and reuses it for later reconnects so path changes such as Wi-Fi to VPN/cellular handoff do not regress back to an unresolvable `.local` name. UDP control attempts observe Loom's authenticated-session bootstrap phases and keep the attempt alive while transport and hello exchange continue making forward progress, bounded by an absolute startup ceiling. Bonjour metadata also carries hashed local IPv4 subnet signatures for the host's active Wi-Fi and wired interfaces so failed local connection attempts can distinguish likely "different Wi-Fi" or "different Ethernet/VLAN" cases from generic transport loss when AWDL is not involved.

The accepted bootstrap response also carries an optional app-owned off-LAN access hint. MirageKit leaves product policy around remembered off-LAN routes to the app, but it preserves the signed result on the client service so higher layers can decide whether to reuse host-published remote reachability metadata.

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
