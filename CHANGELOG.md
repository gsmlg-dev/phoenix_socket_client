# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.8.8] - 2026-10-20

### Added
- Expose `connection_info/1` with a unique attempt reference, current status, and
  retained error independently of telemetry configuration. HTTP 401/403 upgrade
  rejections remain distinct from transient refusal and timeout (#110).

### Fixed
- Reject duplicate channel topic registration with the existing PID, retaining
  one usable channel and avoiding duplicate wire joins. Safe registration
  failures preserve initialization privacy (#109).
- Cancel pending auto-connect and retry timers on explicit disconnect; ignore
  stale timer and transport events. Duplicate connection notifications no longer
  restart heartbeat timers, and successful attempts clear prior errors (#110).
- Honor the documented `:reconnect?` option, with `:reconnect` taking precedence
  when both are supplied (#110).

## [0.8.7] - 2026-10-19

### Fixed
- Keep private callback arguments and queued messages out of OTP crash reports,
  including initialization, cleanup, and asynchronous message-worker failures.
  Failures use the safe exit reason `:private_callback_failure`, preserving
  transient channel restarts and explicit leave behavior (#108).
- Keep private startup options and channel parameters out of supervisor status,
  startup, and restart reports using separate configuration storage. Supervised
  storage follows the supervising parent's lifetime; direct-start storage closes
  with the client. Release unused specifications with `discard_child_spec/1`.
- Verify published transport status, crash reports, and private reply delivery
  against the upstream diagnostic fix.

### Changed
- Require `http_web_socket` 0.21.14 or later in the 0.21 series, consuming the
  published fix for [http_fetch #136](https://github.com/gsmlg-dev/http_fetch/issues/136).

## [0.8.6] - 2026-10-19

### Fixed
- Restore active channels after transport reconnect, preserving join params,
  custom channel callbacks, and the original message recipient. Channels left
  explicitly stay left.
- Omit private message content, transport options, and exception details from
  telemetry before dispatching to handlers.
- Redact private state, current messages, and callback-provided termination fields
  in client status callbacks.
- Use the numeric release tag when running published-package E2E checks.

### Changed
- Support `http_web_socket` 0.20.x and 0.21.x, locking development to 0.21.13.

### Known Issues
- Full private RPC confidentiality remains blocked by OTP crash reports retaining
  original exception arguments and private state exposure in the underlying
  transport: [#108](https://github.com/gsmlg-dev/phoenix_socket_client/issues/108),
  [http_fetch #136](https://github.com/gsmlg-dev/http_fetch/issues/136).

## [0.7.0] - 2025-09-23

### Changed
- Refactor `Phoenix.SocketClient.Channel` into a protocol.

## [0.6.0] - 2025-09-19

### Changed
- Refactor telemetry event names to be flatter.

## [0.5.0] - 2025-09-18

### Added
- Add default name for supervisor.

### Changed
- Improve docs, specs, and types.

## [0.4.0] - 2025-09-16

### Changed
- Refactor SocketClient API and State Management.
- Rename modules and move supervisor.

## [0.3.0] - 2025-09-16

### Added
- Add support for custom channel mapping.
- Support modules as hooks.
- Add channel hooks for incoming messages.

### Fixed
- Fix bugs.

## [0.2.0] - 2025-09-12

### Fixed
- Optimize docs.

## [0.1.1] - 2025-09-06

### Added
- Add devenv.

## [0.1.0] - 2025-09-04

### Added
- Initial release.
