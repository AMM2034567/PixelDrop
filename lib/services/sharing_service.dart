import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Platform Sharing Intent Service for receiving files shared by external apps.
class SharingService {
  static const MethodChannel _channel =
      MethodChannel('io.github.amm2034567.pixeldrop/sharing');

  static final StreamController<List<String>> _sharedFilesController =
      StreamController<List<String>>.broadcast();

  static bool _initialized = false;

  /// Stream of shared file paths emitted when external apps share files/videos.
  static Stream<List<String>> get onSharedFiles => _sharedFilesController.stream;

  /// Initializes listening to platform share intents.
  static void init() {
    if (_initialized) return;
    _initialized = true;

    if (!Platform.isAndroid) return;

    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onSharedFiles') {
        final dynamic args = call.arguments;
        if (args is List) {
          final paths = args.map((e) => e?.toString() ?? '').where((p) => p.isNotEmpty).toList();
          if (paths.isNotEmpty) {
            _sharedFilesController.add(paths);
          }
        }
      }
    });
  }

  /// Checks if the app was launched via a share intent and retrieves the initial shared files.
  static Future<List<String>> getInitialSharedFiles() async {
    if (!Platform.isAndroid) return [];
    try {
      final dynamic res = await _channel.invokeMethod('getInitialSharedFiles');
      if (res is List) {
        return res.map((e) => e?.toString() ?? '').where((p) => p.isNotEmpty).toList();
      }
    } catch (e) {
      debugPrint('Failed to get initial shared files: $e');
    }
    return [];
  }

  /// Helper to determine if a shared file is a video file (.mp4, .mkv, .mov, etc.)
  static bool isVideoFile(String path) {
    final lower = path.toLowerCase();
    return lower.endsWith('.mp4') ||
        lower.endsWith('.mkv') ||
        lower.endsWith('.mov') ||
        lower.endsWith('.avi');
  }

  /// Helper method for tests to inject shared files without Android runtime.
  @visibleForTesting
  static void dispatchSharedFilesForTesting(List<String> paths) {
    if (paths.isNotEmpty) {
      _sharedFilesController.add(paths);
    }
  }

  /// Resets test state.
  @visibleForTesting
  static void resetForTesting() {
    _initialized = false;
  }
}
