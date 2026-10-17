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
    }

    // Fallback to getDownloadsDirectory or getApplicationDocumentsDirectory
    if (downloadDir == null) {
      try {
        downloadDir = await getDownloadsDirectory();
      } catch (_) {}
    }

    downloadDir ??= await getApplicationDocumentsDirectory();

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

  /// Opens the directory in the system file manager.
  static Future<OpenResult> openDirectory(Directory dir) async {
    return await OpenFilex.open(dir.path);
  }

  /// Opens a specific file with system default handler.
  static Future<OpenResult> openFile(File file) async {
    return await OpenFilex.open(file.path);
  }
}
