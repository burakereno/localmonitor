# Project Reliability Implementation Plan

**Goal:** Implement all six agreed reliability features without publishing or changing the application version.

**Architecture:** Keep preflight, launch planning, dependency installation, service orchestration, resource sampling and failure diagnosis in focused services. Store only non-secret settings and installation fingerprints. The existing model owns UI state and cancels pending operations; SwiftUI displays actionable results and per-project settings.

**Tech Stack:** SwiftPM, SwiftUI, Foundation Process/URLSession, CryptoKit, Swift Testing.

## Global constraints

- The user must explicitly request any new release. No tags, publication, version bumps or installed-app replacement in this task.
- Preserve previous Node changes, saved project IDs, custom commands and working servers.
- Bound subprocess output and duration, metadata size, traversal, retry history and resource histories.
- Never persist environment values or raw secret-bearing logs in diagnosis history.
- Installation and Compose startup happen only through explicit user actions/configuration.

## 1. Bounded command execution

Files: `Support/Shell.swift`, `Tests/LocalMonitorTests/CommandExecutionTests.swift`.

- [x] Drain stdout/stderr concurrently with process execution, cap retained bytes, and support cwd/environment overrides.
- [x] Cancel/timeout owned processes and children; test output floods, nonzero exits, timeouts and cancellation using isolated fixtures.

## 2. Project launch requirements and dependency installation

Files: `Models/ProjectReliability.swift`, `Services/ProjectPackageRuntime.swift`, `Services/ProjectDependencyInstallation.swift`, `Services/ProjectEnvironmentChecker.swift`, `Services/PreflightChecker.swift`, `Services/ProjectProcessManager.swift`.

- [x] Read nearest `packageManager` / `devEngines.packageManager` pins and validate manager versions in the selected Node environment.
- [x] Resolve cached Corepack versions without changing global defaults; use executable shims so nested commands inherit the choice.
- [x] Track successful installs by lockfile/package hashes and Node major; expose an explicit frozen-lockfile install action.
- [x] Compare configured required keys and `.env.example` keys against framework/mode-specific files and actual shell variables, without exposing values.
- [x] Pass a prepared launch environment from preflight to process launch to avoid duplicate probes.

```swift
let result = await checker.check(project)
try await manager.start(project: project, launchEnvironment: result.launchEnvironment)
```

## 3. Dependent services

Files: `Services/ProjectServiceDependencies.swift`, `Stores/LocalMonitorModel.swift`.

- [x] Persist saved-project dependencies and explicitly selected Compose services with backward-compatible defaults.
- [x] Topologically validate the entire project graph before starting anything; reject cycles and missing projects.
- [x] Start dependencies in order and await their health endpoints with cancellation and a bounded deadline.
- [x] Validate Compose healthchecks, start selected services with `up --detach --wait`, and report daemon/readiness failures clearly.

## 4. Resource monitoring and crash control

Files: `Services/ProjectResources.swift`, `Services/ProjectFailureDiagnosis.swift`, `Stores/LocalMonitorModel.swift`.

- [x] Aggregate parent and child CPU/RSS from one bounded `ps` snapshot per refresh.
- [x] Keep a bounded sample history and warn for sustained thresholds or growing memory without killing projects.
- [x] Replace unlimited immediate retries with capped exponential backoff, cancellation, and manual reset.
- [x] Persist bounded structured failure history with actionable, deterministic diagnosis and no raw log content.

## 5. UI and integration

Files: `Views/ProjectReliabilityViews.swift`, `Views/StatusPanelView.swift`, `Views/ProjectViews.swift`, `Views/ProjectSettingsEditorView.swift`, `README.md`.

- [x] Show preflight results, install progress, resource use and failure history alongside each project's logs.
- [x] Add settings for required environment keys, mode, saved-project/Compose dependencies and resource/retry limits.
- [x] Keep controls accessible, disable conflicting operations and preserve existing settings.

## 6. Verification

- [x] Cover manager pins, install fingerprints, environment precedence, missing keys, DAG cycles, service readiness, process aggregation, retry exhaustion, redaction and legacy decoding.
- [x] Run the full Swift test suite with limited build parallelism and an external time/RSS watchdog.
- [x] Run `./scripts/build-app.sh` with the current version and ad-hoc local signing only; do not publish or install.
- [x] Verify the rendered local UI in an isolated application-data directory and inspect the final diff.

Execution is inline under the user's explicit request to implement all six features.


## Verification evidence — 2026-10-29

- Full `swift test --jobs 2`: 56 XCTest tests and 75 Swift Testing cases passed (131 total). An external watchdog bounded test duration to 240 seconds and owned-process RSS to 3 GB; the final run peaked at 683.2 MB.
- Local release-configuration bundle built with the existing version 0.1.24 / build 24, two build jobs and ad-hoc signing. No install, release, tag, publication or version bump.
- Native UI checked in a debug bundle with a separate identifier and isolated project data: missing keys, validation, saved settings, diagnostics/history, a real test API process and updating CPU/RAM charts. Closing the preview stopped its owned API process.
- Compose configuration, healthcheck validation and dependency readiness are covered by isolated tests. No real Docker services were started.
- Final diff and shell syntax checks passed; the installed application's executable checksum remained unchanged. Preview processes and test listeners were cleaned up.
