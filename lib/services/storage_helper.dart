import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:open_filex/open_filex.dart';

class StorageHelper {
  static const String baseFolderName = 'PixelDrop';
  static const String videosSubfolder = 'Videos';
  static const String restoredSubfolder = 'Restored';

  /// Returns the base directory in user's public Download folder if possible,
  /// with automatic fallback to app documents directory.
  static Future<Directory> _getBasePixelDropDir() async {
    Directory? downloadDir;

    // Try standard Android public Download directory
    if (Platform.isAndroid) {
      final standardDownload = Directory('/storage/emulated/0/Download');
      if (await standardDownload.exists()) {
        downloadDir = standardDownload;
      }
    } else if (Platform.isWindows) {
      final userProfile = Platform.environment['USERPROFILE'];
      if (userProfile != null && userProfile.isNotEmpty) {
        final winDownload = Directory('$userProfile\\Downloads');
        if (await winDownload.exists()) {
          downloadDir = winDownload;
        }
      }
    }

    // Fallback to getDownloadsDirectory or getApplicationDocumentsDirectory
    if (downloadDir == null) {
      try {
        downloadDir = await getDownloadsDirectory();
      } catch (_) {}
    }

    if (downloadDir == null) {
      try {
        downloadDir = await getApplicationDocumentsDirectory();
      } catch (_) {}
    }

    downloadDir ??= Directory.systemTemp;

    final pixelDropDir = Directory('${downloadDir.path}/$baseFolderName');
    if (!await pixelDropDir.exists()) {
      await pixelDropDir.create(recursive: true);
    }
    return pixelDropDir;
  }

  /// Target directory for generated MP4 transmission videos: Download/PixelDrop/Videos
  static Future<Directory> getVideosDir() async {
    final base = await _getBasePixelDropDir();
    final dir = Directory('${base.path}/$videosSubfolder');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// Target directory for restored files: Download/PixelDrop/Restored
  static Future<Directory> getRestoredDir() async {
    final base = await _getBasePixelDropDir();
    final dir = Directory('${base.path}/$restoredSubfolder');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// Opens the directory in the system file manager (Windows Explorer or platform file manager).
  static Future<OpenResult> openDirectory(Directory dir) async {
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    if (Platform.isWindows) {
      try {
        final normPath = dir.path.replaceAll('/', '\\');
        await Process.run('explorer.exe', [normPath]);
        return OpenResult(type: ResultType.done, message: 'Done');
      } catch (_) {}
    }
    return await OpenFilex.open(dir.path);
  }

  /// Locates and selects the specific file inside Windows Explorer.
  static Future<OpenResult> showInExplorer(File file) async {
    if (Platform.isWindows && await file.exists()) {
      try {
        final normPath = file.path.replaceAll('/', '\\');
        await Process.run('explorer.exe', ['/select,', normPath]);
        return OpenResult(type: ResultType.done, message: 'Done');
      } catch (_) {}
    }
    return await openDirectory(file.parent);
  }

  /// Opens a specific file with system default handler.
  static Future<OpenResult> openFile(File file) async {
    if (Platform.isWindows && await file.exists()) {
      try {
        final normPath = file.path.replaceAll('/', '\\');
        final res = await Process.run('cmd.exe', ['/c', 'start', '""', normPath]);
        if (res.exitCode == 0) {
          return OpenResult(type: ResultType.done, message: 'Done');
        }
      } catch (_) {}
    }
    return await OpenFilex.open(file.path);
  }
}
