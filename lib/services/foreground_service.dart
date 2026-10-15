import 'package:flutter/services.dart';

class ForegroundServiceHelper {
  static const MethodChannel _channel =
      MethodChannel('com.antigravity.pixeldrop/service');

  static int _lastUpdateMillis = 0;

  static Future<void> start({
    required String title,
    required String content,
    int progress = 0,
  }) async {
    try {
      await _channel.invokeMethod('startService', {
        'title': title,
        'content': content,
        'progress': progress,
      });
    } catch (_) {}
  }

  static Future<void> update({
    required String title,
    required String content,
    required int progress,
    bool force = false,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!force && (now - _lastUpdateMillis < 250) && progress < 100) {
      return;
    }
    _lastUpdateMillis = now;

    try {
      await _channel.invokeMethod('updateProgress', {
        'title': title,
        'content': content,
        'progress': progress,
      });
    } catch (_) {}
  }

  static Future<void> stop() async {
    try {
      await _channel.invokeMethod('stopService');
    } catch (_) {}
  }
}
