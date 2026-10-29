# Reliability review — 2026-10-29

User scope: review and fix the six reliability features; do not release or replace the installed application.

## Corrected behavior

- Project launches now own a request identity from preflight onward. Stop, removal, relevant settings changes and Stop All invalidate/cancel pending checks; obsolete completions cannot start a server or restore deleted state. Refresh preserves the checking state.
- Delayed Stop verification is cancelled by a new Start. It cannot kill or overwrite a newer launch.
- Stop All invalidates the rest of bulk startup; group Stop invalidates its pending group startup. Stopping a dependency cancels pending parent chains. Failed, stopped or port-mismatched dependencies cannot pass readiness based on another service's response.
- Restart/cache maintenance also owns a request identity. Stop cancels the pending restart. Old completion timers cannot clear a newer operation's active status. Installation and maintenance cannot run concurrently in the same workspace.
- Dependency installation uses the child project's selected runtime while executing from the workspace root. A shared installation record detects sibling reinstalls with a different Node major or package-manager version. Cancelled/removed installation tasks do not repopulate removed state, and caller cancellation reaches owned commands.
- Corepack probes, direct shim candidates and launches all receive offline/no-auto-pin controls. Only explicit installation allows manager downloads. Unpinned modern Yarn is version-probed so frozen installs use its immutable flag.
- Environment checks recognize leading literal shell assignments without executing command substitutions. Computed assignments are reported as unverifiable warnings. Hono/Wrangler environment-specific dev-vars files replace generic dev-vars and exclude dotenv files. Failed shell checks are not treated as empty successful probes.
- Diagnostic matching no longer lets informational Node/package-manager/environment banners override the actual failure; multiline EBADENGINE errors remain recognized.

## Verification

- Full `swift test --jobs 2`: 56 XCTest tests plus 88 Swift Testing tests passed (144 total). Parameterized regressions include Stop/remove/edit during preflight, caller cancellation, batch cancellation, dependency cancellation, stale Stop checks, Stop during Restart, shared install locking, child Node selection and cancelled installs.
- The external watchdog limits test duration to 240 seconds and owned-process RSS to 3 GB. Final peak: 925.6 MB.
- `git diff --check` and shell syntax validation passed.
- Local package built as version 0.1.24 / build 24 with two build jobs and ad-hoc signing; no release, tag, install or version change. Installed executable checksum unchanged.
- Real Docker services were not started. Compose configuration/health checks and dependency ordering use isolated fixtures. Environment checks do not execute arbitrary project configuration or shell scripts.

## Reference checks

- [Corepack environment controls](https://github.com/nodejs/corepack/blob/main/README.md#environment-variables)
- [Wrangler development environment file precedence](https://developers.cloudflare.com/workers/local-development/environment-variables/)
