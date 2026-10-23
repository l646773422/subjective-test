import 'dart:convert';
import 'dart:io';
import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver(
  writeResponseOnFailure: true,
  responseDataCallback: (data) async {
    final root = Directory(
      Platform.environment['STUDY_ARTIFACT_DIR'] ?? 'validation/native',
    );
    await root.create(recursive: true);
    final report = Map<String, dynamic>.from(data ?? {});
    final images = Map<String, dynamic>.from(
      report.remove('artifacts') as Map? ?? {},
    );
    for (final entry in images.entries) {
      if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(entry.key)) {
        throw const FormatException('Unsafe screenshot name');
      }
      await File(
        '${root.path}/${entry.key}.png',
      ).writeAsBytes(base64Decode(entry.value as String), flush: true);
    }
    report.putIfAbsent(
      'testTimingMode',
      () =>
          'default 2s/3s timing and >5s answer wait; accelerated schema-1 46-trial and schema-2 generic flows',
    );
    await File('${root.path}/report.json').writeAsString(
      const JsonEncoder.withIndent('  ').convert(report),
      flush: true,
    );
    stdout.writeln('Native validation artifacts saved: ${root.path}');
  },
);
