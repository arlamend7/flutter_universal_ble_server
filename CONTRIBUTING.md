# Contributing

Keep the common API small. Extend existing classes or add narrowly scoped
extensions before adding a new layer. Preserve legacy calls unless a breaking
release is explicitly planned. Native Bluetooth operations belong in platform
adapters; codecs, framing and request/reply remain plain Dart. Do not add a BLE
plugin dependency, global application singleton or UI/state-management coupling.

## Local checks

Use a compatible Flutter SDK, then run from the package root:

```sh
flutter pub get
dart format --output=none --set-exit-if-changed lib test example/lib tool
flutter analyze
flutter test --coverage
flutter test --platform chrome test/web
node --test test/browser_client_test.cjs
dart run tool/protocol_smoke.dart
dart pub global activate dartdoc
dart pub global run dartdoc --sdk-dir /path/to/flutter/bin/cache/dart-sdk --output /tmp/universal_ble_server_api
flutter pub publish --dry-run
```

Run the example's native build on each claimed platform. CI includes Android,
iOS, macOS, Windows and Linux runners. Browser builds verify graceful unsupported
behavior; they do not imply browser BLE server support. See
[hardware acceptance](doc/HARDWARE_TESTING.md) for radio validation.

Add focused regression tests for lifecycle races, wire behavior and error
recovery. Avoid tests that merely restate a getter or implementation detail.
Do not mark hardware behavior as validated based on fake transports or builds.

## Package quality and release

The package is MIT licensed. Use `pana` as a development tool to inspect current
pub.dev scoring; it is not a runtime dependency. Run it against the clean package
contents, not a workspace full of generated native builds. Pana copies its input,
so including several gigabytes of build output can exhaust temporary storage.

After installing the development checker with `dart pub global activate pana`,
run `dart run tool/package_audit.dart /path/to/flutter`. The report is saved to
`build/package-audit.json`; the temporary copy is removed even on failure.

Generate API docs and inspect warnings. Check the lower dependency bounds using
`flutter pub downgrade`, analyze and test, then restore with `flutter pub get`.
The minimum SDK compatibility job checks the declared Flutter/Dart baseline.

Before creating a release tag:

1. Run CI and physical acceptance for the target platforms.
2. Update CHANGELOG and validation notes with evidence and known limitations.
3. Verify package contents, license, version and repository URLs in the dry run.
4. Commit/push approved changes so the public repository metadata matches.
5. Check the published package version and configure pub.dev trusted publishing.

The tag-triggered workflow publishes only after validation. A local pana score
is a prediction, not a guaranteed hosted pub.dev score. Do not change supported
platform claims simply to improve scoring; Web and Linux server limitations must
remain explicit. Remote repository checks can fail until local changes reach the
public default branch.
