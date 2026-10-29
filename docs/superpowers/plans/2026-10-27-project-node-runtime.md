# Project Node Runtime Implementation Plan

**Goal:** Start each project with an installed Node runtime satisfying its declared version, independently of the login shell's default.

**Architecture:** Read the nearest version file, falling back to package metadata. Resolve installed runtimes asynchronously, then prepend the selected binary directory after login-shell initialization. Reuse that selection logic for package-manager preflight checks; preserve custom command text and process ownership.

**Tech Stack:** Swift, Foundation Process, SwiftPM, Swift Testing, zsh.

## Constraints

- No changes to global Node defaults or shell configuration; no automatic downloads.
- Treat version files as data, quote paths and diagnostics, preserve environment assignments and compound commands.
- Support `.nvmrc`, `.node-version`, `package.json` `volta.node` and `engines.node`, including ancestor metadata.
- Discover installed PATH, fnm, nvm, Volta, mise, asdf and Homebrew runtimes. Delegate named aliases to installed fnm/nvm.
- Unsupported declarations and missing versions must fail with an actionable error.

## Task 1: Requirement and installed-runtime resolution

Create `Sources/LocalMonitor/Services/NodeVersionRange.swift`, `Sources/LocalMonitor/Services/ProjectNodeRuntime.swift`, and `Tests/LocalMonitorTests/ProjectNodeRuntimeTests.swift`.

- [x] Implement `NodeVersionRange.init(_:) throws` and `contains(_:)` for stable numeric versions, partial versions, wildcards, comparisons, caret, tilde, hyphen and OR ranges.
- [x] Implement `ProjectNodeRequirement.read(in:) throws` with closest version file taking precedence over fallback package engines. Parse comments without executing metadata.
- [x] Implement `ProjectNodeRuntimeResolver.resolve(in:) async throws -> ProjectNodeRuntime?` with injectable candidate directories for isolated tests.
- [x] Verify exact pins, patch floors, upper bounds, monorepo inheritance, local overrides, missing runtimes, aliases and shell metacharacters.

```swift
let range = try NodeVersionRange(">=22.23.4 <25 || ^26.8.2")
#expect(range.contains(try NodeVersion("22.23.2")) == false)
#expect(range.contains(try NodeVersion("24.21.0")))
```

Run `swift test --filter ProjectNodeRuntimeTests`; expected: all runtime-selection tests pass without modifying the machine's Node defaults.

## Task 2: Launch and preflight integration

Modify `ProjectProcessManager.swift`, `PreflightChecker.swift`, `LocalMonitorModel.swift`, and existing process launch tests.

- [x] Resolve asynchronously before launching and check process ownership again after suspension.
- [x] Prefix the resolved binary directory after zsh login startup; log the actual version and declaration source.
- [x] Run package-manager discovery with the same environment preparation; report unavailable required runtimes as preflight errors.
- [x] Exercise real child processes using isolated fake runtimes to prove PATH selection, compound command handling and project isolation.

```swift
let runtime = try await nodeRuntimeResolver.resolve(in: project.folderURL)
process.arguments = ["-lc", runtime?.command(project.resolvedCommand) ?? project.resolvedCommand]
```

## Task 3: Verify and activate locally

Modify `README.md` to document supported declarations, installed runtime discovery, logs and missing-version behavior.

- [x] Run `swift test` and `./scripts/build-app.sh` as required by AGENTS.md.
- [x] Run `./script/build_and_run.sh --verify` for app-launch verification.
- [x] Remove only the Galata PATH workaround saved in the preceding turn after automatic selection is validated against its real declaration.
- [x] Verify Galata uses Node 26.8.2 and other installed projects resolve their own versions without starting their servers.

Execution proceeds inline under the user's request to implement the feature.
