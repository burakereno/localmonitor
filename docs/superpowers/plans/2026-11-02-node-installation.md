# Missing Node Installation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Install a missing project Node.js runtime from its LocalMonitor error card with one click.

**Architecture:** Preserve the missing requirement as structured preflight data. A separate installer selects an exact stable release and invokes an existing fnm or nvm installation; the model owns cancellable installation tasks and rechecks requirements after success. A shared SwiftUI recovery view appears on both the project card and diagnostics panel.

**Tech Stack:** SwiftPM, Foundation URLSession, SwiftUI, Swift Testing, existing cancellable Shell runner.

## Global Constraints

- No version bump, release, publishing, or replacement of the installed application.
- Ordinary Start and Check Requirements never download Node.
- Installation requires a click, uses fnm or nvm, and does not run a server.
- Do not edit project pins, shell configuration, or explicitly change global Node defaults.
- Use the existing Shell cancellation and timeout support; serialize Node installations.
- Unit tests use fixture runtimes and injected commands/release indexes, never real downloads.

---

### Task 1: Preserve missing requirements and install a matching runtime

**Files:** Modify `Sources/LocalMonitor/Models/ProjectModels.swift`, `Sources/LocalMonitor/Services/PreflightChecker.swift`; create `Sources/LocalMonitor/Services/ProjectNodeInstaller.swift`, `Tests/LocalMonitorTests/Services/ProjectNodeInstallerTests.swift`.

**Interfaces:** `PreflightIssue.missingNode: ProjectNodeRequirement?`; `PreflightResult.missingNodeRequirement: ProjectNodeRequirement?`; `ProjectNodeInstaller.install(_:in:resolver:) async throws -> ProjectNodeRuntime`. Inject release-index loading and command execution into the installer.

- [x] Add parameterized release-selection tests for exact pins, semver ranges, and LTS aliases. For `>=24 <25`, an index containing 22.23.2, 24.18.0, 24.21.0, and 26.8.2 must select 24.21.0. Reject unmatched ranges and shell expressions.
- [x] Preserve `NodeRuntimeError.unavailable` as structured issue metadata:
  ```swift
  } catch NodeRuntimeError.unavailable(let requirement) {
      issues.append(PreflightIssue(severity: .error,
          message: NodeRuntimeError.unavailable(requirement).localizedDescription,
          missingNode: requirement))
  }
  ```
- [x] Implement exact release selection using `NodeVersion` / `NodeVersionRange` and the official HTTPS Node release index for ranges. Invoke `fnm install VERSION --progress never` or `nvm install VERSION` in a child shell (source nvm with `--no-use`); use shell quoting and standard Homebrew/nvm discovery paths. Report missing managers and installer failures with actionable messages.
- [x] Re-read the requirement before and after installation, check cancellation, and resolve the installed runtime again. A zero exit code alone must never certify success.
- [x] Run `swift test --filter ProjectNodeInstallerTests` and the existing runtime tests.

### Task 2: Connect cancellable installation to the project card

**Files:** Create `Sources/LocalMonitor/Stores/LocalMonitorNodeInstallation.swift`, `Sources/LocalMonitor/Views/ProjectNodeInstallationView.swift`, `Tests/LocalMonitorTests/Stores/NodeInstallationIntegrationTests.swift`; modify `LocalMonitorModel.swift`, `LocalMonitorReliability.swift`, `ProjectViews.swift`, `ProjectReliabilityViews.swift`, `StatusPanelView.swift`, and `README.md`.

**Interfaces:** `installNode(for:) async`, `cancelNodeInstallation(for:)`, `isInstallingNode(for:)`, and published per-project `ProjectNodeInstallationState`. Recovery view receives requirement, state, disabled status, install action, and cancel action.

- [x] Test the model with a fake installer that creates an executable fixture runtime. Assert the missing-node issue disappears after installation, no server starts, and blocked launch state clears when all requirements pass.
- [x] Test cancellation, removal, install failures, duplicate requests, changed pins, and shutdown; removed projects must not regain state.
- [x] Add a serialized task per clicked project, propagate caller cancellation, cancel on Stop/removal/shutdown, recheck requirements on success, and block conflicting Start/restart/dependency installation.
- [x] Add `Install Node.js SELECTOR`, progress, cancellation, retry, and success feedback to both card and diagnostics. Keep the source filename visible and the error actionable without opening a terminal.
- [x] Document explicit opt-in installation and supported managers in README.
- [x] Run `swift test`, then `./scripts/build-app.sh`. Review the diff for unwanted files and validate the recovery UI in an isolated local preview if feasible.

Execution: implement inline in this chat under the user's existing authorization.

UI verification found that assigning nil to `NSTask.environment` drops inherited variables on this macOS version. Preserve the app environment in `Shell.execute` when no override is supplied, with a regression test using `/usr/bin/printenv HOME`. This is required for the installer to honor `FNM_DIR` and `NVM_DIR` consistently with discovery.

Final validation: `swift test` passed (56 XCTest tests and 108 Swift Testing tests). `./scripts/build-app.sh` built the local app bundle. In an isolated native-app preview, clicking Install Node.js installed the real 24.18.0 runtime into a temporary fnm directory and automatically displayed “installed and verified”; the fixture server remained stopped.
