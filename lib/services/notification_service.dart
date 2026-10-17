import 'dart:io';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';

class NotificationService {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  static bool _isInitialized = false;
  static int _lastUpdateMillis = 0;

  static const String progressChannelId = 'pixeldrop_progress';
  static const String progressChannelName = 'PixelDrop 任务进度';

  static const String completeChannelId = 'pixeldrop_complete';
  static const String completeChannelName = 'PixelDrop 完成通知';

  static Future<void> init() async {
    if (!Platform.isAndroid) return;
    if (_isInitialized) return;

    const androidInit = AndroidInitializationSettings('@drawable/ic_notification');
    const initSettings = InitializationSettings(android: androidInit);

    await _plugin.initialize(initSettings);

    // Request notification permission on Android 13+
    if (Platform.isAndroid) {
      final status = await Permission.notification.status;
      if (status.isDenied) {
        await Permission.notification.request();
      }
    }

    _isInitialized = true;
  }

  static Future<void> showProgress({
    required int id,
    required String title,
    required String body,
    required int progress,
    required int maxProgress,
    bool force = false,
  }) async {
    if (!Platform.isAndroid) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    // Throttle notification updates to at most once per 300ms unless forced
    if (!force && (now - _lastUpdateMillis < 300) && progress < maxProgress) {
      return;
    }
    _lastUpdateMillis = now;

    try {
      final androidDetails = AndroidNotificationDetails(
        progressChannelId,
        progressChannelName,
        channelDescription: '显示当前视频编码或还原的实时进度',
        importance: Importance.low,
        priority: Priority.low,
        playSound: false,
        enableVibration: false,
        showProgress: true,
        maxProgress: maxProgress,
        progress: progress,
        ongoing: true,
        autoCancel: false,
        icon: '@drawable/ic_notification',
      );

      await _plugin.show(
        id,
        title,
        body,
        NotificationDetails(android: androidDetails),
      );
    } catch (_) {}
  }

  static Future<void> showComplete({
    required int id,
    required String title,
    required String body,
  }) async {
    if (!Platform.isAndroid) return;
    try {
      const androidDetails = AndroidNotificationDetails(
        completeChannelId,
        completeChannelName,
        channelDescription: '任务完成提醒',
        importance: Importance.high,
        priority: Priority.high,
        ongoing: false,
        autoCancel: true,
        icon: '@drawable/ic_notification',
      );

      await _plugin.show(
        id,
        title,
        body,
        const NotificationDetails(android: androidDetails),
      );
    } catch (_) {}
  }

  static Future<void> cancel(int id) async {
    if (!Platform.isAndroid) return;
    try {
      await _plugin.cancel(id);
    } catch (_) {}
  }
}
