# MirageKit Agent Guidelines

## Package Summary
- MirageKit is the core streaming package used by Mirage host/client apps on macOS, iOS, and visionOS.
- Source layout is split into public API in `Sources/*/Public`, implementation in `Sources/*/Internal`, and tests in `Tests/`.
- MirageKit is licensed under PolyForm Shield 1.0.0.

## Core Rules
- Pre-release package: compatibility is not locked yet for internal code or public API.
- Remove dead code completely (signatures, implementations, call sites, tests); no shims, wrappers, or dormant compatibility layers.
- Platform parity across clients is the default unless a task explicitly scopes platforms.
- Target latest supported OS releases; avoid availability checks.
- Keep public API additions minimal, intentional, and documented.
- Do not add third-party dependencies without explicit approval.
- Comments and README text should be static descriptions of current behavior.

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
