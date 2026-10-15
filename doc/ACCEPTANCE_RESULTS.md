# BLE acceptance result template

Status: **NOT RUN**. Copy this template per device combination; do not overwrite
the template with a blanket platform approval.

| Environment | Recorded value |
| --- | --- |
| Date / tester | |
| Source commit / package version | |
| Flutter / Dart versions | |
| Host model / OS / adapter / driver | |
| Client A model / OS / adapter / driver | |
| Client B model / OS / adapter / driver (if used) | |
| Debug or release / dependency manager | |
| Run ID / maximum payload / assembly deadline | |
| Negotiated payload limit, if available | |
| Foreground/background / permission state | |
| Client output / host log locations | |

Use **PASS**, **FAIL** or **NOT RUN** for every row. Add observations and the
configuration when it differs from the defaults.

| Check | Result | Evidence / notes |
| --- | --- | --- |
| Discovery and logical server name | NOT RUN | |
| UTF-8 and binary integrity | NOT RUN | |
| 4,096-byte bidirectional round trip | NOT RUN | |
| 65,535-byte round trip with default deadline | NOT RUN | |
| Larger deadline (optional; record value) | NOT RUN | |
| Oversized rejection and recovery | NOT RUN | |
| Two clients: private routing and broadcast to both | NOT RUN | |
| Typed fields: read/write/notify/cancel | NOT RUN | |
| Intentional reconnect cycles | NOT RUN | |
| Permission denied, then granted | NOT RUN | |
| Bluetooth disabled, then enabled | NOT RUN | |
| Abrupt radio loss during scan / transfer | NOT RUN | |
| Automatic reconnect, restored watches and session resume | NOT RUN | |
| Host stop/restart and client disposal while active | NOT RUN | |
| Rejected field writes / pairing / encrypted fields | NOT RUN | |
| Foreground/background / process termination | NOT RUN | |
| Sustained operation (record duration and message count) | NOT RUN | |
| Separate application integration / public API review | NOT RUN | |

Release decision and remaining limitations:

- Decision: pending.
- Failures and reproducible steps:
- Deferred platforms/features:
- API changes required before 1.0:
