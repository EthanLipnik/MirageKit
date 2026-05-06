# MirageKit Agent Guidelines

## Package Summary
- MirageKit is the core streaming package used by Mirage host/client apps on macOS, iOS, and visionOS.
- Source layout is split into public API in `Sources/*/Public`, implementation in `Sources/*/Internal`, and tests in `Tests/`.
- MirageKit is licensed under PolyForm Shield 1.0.0.

## Core Rules
- Released package: preserve compatibility for existing clients, hosts, persisted data, wire protocols, public APIs, and documented behavior unless a task explicitly authorizes a breaking change.
- Cutovers must include explicit migration, version-gating, or compatibility handling for existing installs; keep transitional paths active, tested, and tied to a clear removal condition.
- When a change might require a migration, ask for explicit permission before implementing the migration or compatibility path.
- Remove dead code completely (signatures, implementations, call sites, tests); no no-op wrappers, dormant adapters, or compatibility layers that are not exercised by a current migration or version gate.
- Platform parity across clients is the default unless a task explicitly scopes platforms.
- Target latest supported OS releases; avoid availability checks.
- Keep public API additions minimal, intentional, and documented.
- Do not add third-party dependencies without explicit approval.
- When releasing MirageKit, make the git tag match `MirageKit.version` exactly.
- Never increase inflight for low latency mode.
- In Network.framework, enabling peer-to-peer transport also allows AWDL paths over wired USB-C links when the system exposes them that way; account for that when reasoning about path selection and diagnostics.
- Comments and README text should be static descriptions of current behavior.
- When architecture, message flow, transport behavior, or subsystem boundaries change, update `Architecture.md` in the same change.
- `Architecture.md` is a high-level overview only. Keep it focused on capture, encode, transport, decode, display, input translation, and shared package boundaries. Do not turn it into a type inventory or implementation-detail dump.

## Coding Standards
- 4-space indentation; `UpperCamelCase` types; `lowerCamelCase` members.
- Public API types keep the `Mirage` prefix.
- Prefer one primary type per file and use `// MARK: -` in larger files.
- New Swift files include the standard header with `Created by Ethan Lipnik` and an accurate date.
- Swift 6.2 strict concurrency baseline.
- `@Observable` classes are `@MainActor`.
- Prefer Swift concurrency over GCD.
- Use `Task.sleep(for:)`, not `Task.sleep(nanoseconds:)`.
- Avoid force unwraps / force `try` unless failure is unrecoverable.
- For SwiftUI, prefer modern APIs (`NavigationStack`, `Tab`, `foregroundStyle`, etc.) and avoid `AnyView` unless necessary.
- Do not keep unused owned function parameters as `_:` placeholders after refactors; remove the parameter and update call sites unless a framework, protocol, override, selector, or compatibility boundary requires the signature.

## Build and Test
- Build MirageKit: `swift build --package-path MirageKit`
- Test MirageKit: `swift test --package-path MirageKit`
- For host-integration-sensitive changes, also build: `xcodebuild -project Mirage.xcodeproj -scheme 'Mirage Host' -configuration Debug -destination 'platform=macOS' build`
- Tests use Swift Testing and should be placed in matching targets:
  - `Tests/MirageKitTests`
  - `Tests/MirageKitHostTests`
  - `Tests/MirageKitClientTests`

## File Hygiene
- Keep files under ~500 lines when practical by splitting responsibilities.
- Remove unused declarations and related tests in the same change.
