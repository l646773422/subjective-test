import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

class PlatformBridge {
  static const channel = MethodChannel('cn.pcnl.study/platform');
  static Future<String> appDirectory() async => Platform.isAndroid
      ? (await channel.invokeMethod<String>('appDirectory'))!
      : p.join(
          Platform.environment['LOCALAPPDATA'] ?? Directory.current.path,
          'PCNL',
          'SubjectiveStudy',
        );
  static Future<String?> pickDirectory() =>
      channel.invokeMethod<String>('pickDirectory');
  static Future<Map<String, dynamic>?> pickMaterialDirectory() async =>
      channel.invokeMapMethod<String, dynamic>('pickMaterialDirectory');
  static Future<Uint8List> readMaterial(String uri) async =>
      (await channel.invokeMethod<Uint8List>('readMaterial', uri))!;
  static Future<void> presentation(bool enabled) async {
    await channel.invokeMethod<void>('presentation', enabled);
    if (Platform.isAndroid) {
      await SystemChrome.setEnabledSystemUIMode(
        enabled ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
      );
      await SystemChrome.setPreferredOrientations(
        enabled
            ? [
                DeviceOrientation.landscapeLeft,
                DeviceOrientation.landscapeRight,
              ]
            : DeviceOrientation.values,
      );
    }
  }
}
