import 'dart:io';
import 'package:flutter/services.dart';

class WakelockHelper {
  static const MethodChannel _channel =
      MethodChannel('com.antigravity.pixeldrop/wakelock');

  static Future<void> enable() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('enable');
    } catch (_) {}
  }

  static Future<void> disable() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('disable');
    } catch (_) {}
  }
}
