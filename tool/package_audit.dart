import 'dart:convert';
import 'dart:io';

/// Audits a clean package copy without duplicating generated native builds.
/// Run: dart run tool/package_audit.dart /path/to/flutter
Future<void> main(List<String> arguments) async {
  if (arguments.length != 1) {
    stderr.writeln('Usage: dart run tool/package_audit.dart /path/to/flutter');
    exitCode = 64;
    return;
  }
  final root = Directory.current;
  final flutter = Directory(arguments.single).absolute;
  final dartSdk = Directory('${flutter.path}/bin/cache/dart-sdk');
  final dart = '${dartSdk.path}/bin/dart${Platform.isWindows ? '.exe' : ''}';
  final files = await Process.run('git', [
    'ls-files',
    '--cached',
    '--others',
    '--exclude-standard',
    '-z',
  ]);
  if (files.exitCode != 0) {
    throw StateError('Run this tool from the Git package root.');
  }
  final temporary = await Directory.systemTemp.createTemp('ble-package-audit-');
  final snapshot = await Directory(
    '${temporary.path}/universal_ble_server',
  ).create();
  try {
    for (final relative in (files.stdout as String).split('\u0000').toSet()) {
      if (relative.isEmpty ||
          relative.endsWith('.docx') ||
          relative
              .split('/')
              .any(
                const {
                  '.git',
                  '.dart_tool',
                  'build',
                  'Pods',
                  '.symlinks',
                  'ephemeral',
                  'coverage',
                }.contains,
              )) {
        continue;
      }
      final source = File('${root.path}/$relative');
      if (await FileSystemEntity.type(source.path, followLinks: false) !=
          FileSystemEntityType.file) {
        continue;
      }
      final destination = File('${snapshot.path}/$relative');
      await destination.parent.create(recursive: true);
      await source.copy(destination.path);
    }
    final process = await Process.start(dart, [
      'pub',
      'global',
      'run',
      'pana',
      '--dart-sdk',
      dartSdk.path,
      '--flutter-sdk',
      flutter.path,
      '--json',
      snapshot.path,
    ]);
    final errors = process.stderr.listen(stderr.add);
    final report = await utf8.decoder.bind(process.stdout).join();
    final code = await process.exitCode;
    await errors.cancel();
    final output = File('${root.path}/build/package-audit.json');
    await output.parent.create(recursive: true);
    await output.writeAsString(report);
    stdout.writeln('Package audit saved to ${output.path}');
    exitCode = code;
  } finally {
    await temporary.delete(recursive: true);
  }
}
