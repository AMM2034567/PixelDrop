import 'dart:io';
import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

enum SelectedInputType {
  singleFile,
  directory,
  multipleItems,
}

class ArchiveFileEntry {
  final File file;
  final String relativeZipPath;

  const ArchiveFileEntry({
    required this.file,
    required this.relativeZipPath,
  });

  @override
  String toString() => 'ArchiveFileEntry($relativeZipPath, ${file.path})';
}

class SelectedInput {
  final SelectedInputType type;
  final List<String> paths;
  final String displayName;
  final int totalSize;
  final int fileCount;
  final File? singleFile;
  final String suggestedArchiveName;
  final List<ArchiveFileEntry> entries;

  const SelectedInput({
    required this.type,
    required this.paths,
    required this.displayName,
    required this.totalSize,
    required this.fileCount,
    this.singleFile,
    required this.suggestedArchiveName,
    this.entries = const [],
  });

  bool get needsArchive => type != SelectedInputType.singleFile;
}

class ArchiveService {
  /// Scans one or more paths (files and/or directories) and returns a [SelectedInput].
  static Future<SelectedInput> scanInputPaths(List<String> rawPaths) async {
    final validPaths = rawPaths
        .map((path) => path.trim())
        .where((path) => path.isNotEmpty)
        .map((path) => p.normalize(path))
        .toList();
    if (validPaths.isEmpty) {
      throw ArgumentError('未提供任何有效的文件或目录路径');
    }

    // Check existence
    final existingPaths = validPaths.where((path) {
      final t = FileSystemEntity.typeSync(path);
      return t != FileSystemEntityType.notFound;
    }).toList();

    if (existingPaths.isEmpty) {
      throw FileSystemException('所选文件或目录不存在', validPaths.first);
    }

    // Single entity check
    if (existingPaths.length == 1) {
      final singlePath = existingPaths.first;
      final type = FileSystemEntity.typeSync(singlePath);

      if (type == FileSystemEntityType.file) {
        final file = File(singlePath);
        final fileName = p.basename(singlePath);
        final size = file.lengthSync();
        var stem = p.basenameWithoutExtension(fileName);
        if (stem.isEmpty) stem = 'file';
        return SelectedInput(
          type: SelectedInputType.singleFile,
          paths: [singlePath],
          displayName: fileName,
          totalSize: size,
          fileCount: 1,
          singleFile: file,
          suggestedArchiveName: '$stem.zip',
          entries: [
            ArchiveFileEntry(file: file, relativeZipPath: fileName),
          ],
        );
      } else if (type == FileSystemEntityType.directory) {
        final dir = Directory(singlePath);
        var folderName = p.basename(singlePath);
        if (folderName.isEmpty) folderName = 'folder';
        final entries = <ArchiveFileEntry>[];
        int totalBytes = 0;

        final parentDir = p.dirname(singlePath);
        try {
          for (final entity in dir.listSync(recursive: true, followLinks: false)) {
            if (entity is File) {
              final rel = p.relative(entity.path, from: parentDir);
              final zipRelPath = rel.replaceAll(r'\', '/');
              entries.add(ArchiveFileEntry(file: entity, relativeZipPath: zipRelPath));
              try {
                totalBytes += entity.lengthSync();
              } catch (_) {}
            }
          }
        } catch (_) {}

        return SelectedInput(
          type: SelectedInputType.directory,
          paths: [singlePath],
          displayName: folderName,
          totalSize: totalBytes,
          fileCount: entries.length,
          suggestedArchiveName: '$folderName.zip',
          entries: entries,
        );
      }
    }

    // Multiple entities (files and/or folders)
    final entries = <ArchiveFileEntry>[];
    int totalBytes = 0;
    final distinctZipPaths = <String>{};
    final distinctFolderNames = <String>{};

    for (final itemPath in existingPaths) {
      final entityType = FileSystemEntity.typeSync(itemPath);

      if (entityType == FileSystemEntityType.file) {
        final file = File(itemPath);
        final baseName = p.basename(itemPath);
        var zipRelPath = baseName.replaceAll(r'\', '/');
        int dupCount = 1;
        while (distinctZipPaths.contains(zipRelPath)) {
          final ext = p.extension(baseName);
          final stem = p.basenameWithoutExtension(baseName);
          zipRelPath = '${stem}_$dupCount$ext'.replaceAll(r'\', '/');
          dupCount++;
        }
        distinctZipPaths.add(zipRelPath);
        entries.add(ArchiveFileEntry(
          file: file,
          relativeZipPath: zipRelPath,
        ));
        try {
          totalBytes += file.lengthSync();
        } catch (_) {}
      } else if (entityType == FileSystemEntityType.directory) {
        final dir = Directory(itemPath);
        var baseDirName = p.basename(itemPath);
        if (baseDirName.isEmpty) baseDirName = 'folder';
        var folderPrefix = baseDirName;
        int dupFolderCount = 1;
        while (distinctFolderNames.contains(folderPrefix)) {
          folderPrefix = '${baseDirName}_$dupFolderCount';
          dupFolderCount++;
        }
        distinctFolderNames.add(folderPrefix);

        try {
          for (final entity in dir.listSync(recursive: true, followLinks: false)) {
            if (entity is File) {
              final relInside = p.relative(entity.path, from: itemPath);
              final zipRelPath = '$folderPrefix/${relInside.replaceAll(r'\', '/')}';
              distinctZipPaths.add(zipRelPath);
              entries.add(ArchiveFileEntry(file: entity, relativeZipPath: zipRelPath));
              try {
                totalBytes += entity.lengthSync();
              } catch (_) {}
            }
          }
        } catch (_) {}
      }
    }

    final firstItem = existingPaths.first;
    var firstStem = p.basenameWithoutExtension(firstItem);
    if (firstStem.isEmpty) firstStem = 'bundle';
    final suggestedName = '${firstStem}_bundle.zip';

    return SelectedInput(
      type: SelectedInputType.multipleItems,
      paths: existingPaths,
      displayName: '已选 ${existingPaths.length} 个项目',
      totalSize: totalBytes,
      fileCount: entries.length,
      suggestedArchiveName: suggestedName,
      entries: entries,
    );
  }

  /// Packages the given [entries] into a ZIP archive at [outputZipPath].
  static Future<File> createZipArchive({
    required List<ArchiveFileEntry> entries,
    required String outputZipPath,
    void Function(double progress, String status)? onProgress,
  }) async {
    if (entries.isEmpty) {
      throw ArgumentError('所选项目为空，没有可打包的文件');
    }

    final outputFile = File(outputZipPath);
    outputFile.parent.createSync(recursive: true);
    if (outputFile.existsSync()) {
      outputFile.deleteSync();
    }

    final encoder = ZipFileEncoder();
    encoder.create(outputZipPath);

    try {
      final total = entries.length;
      for (int i = 0; i < total; i++) {
        final entry = entries[i];
        final currentNum = i + 1;
        final fileName = p.basename(entry.file.path);
        onProgress?.call(
          i / total,
          '正在打包: $fileName ($currentNum/$total)',
        );
        final fileStream = InputFileStream(entry.file.path);
        final archiveFile = ArchiveFile.stream(
          entry.relativeZipPath,
          entry.file.lengthSync(),
          fileStream,
        );
        try {
          archiveFile.lastModTime =
              entry.file.lastModifiedSync().millisecondsSinceEpoch ~/ 1000;
          archiveFile.mode = entry.file.statSync().mode;
        } catch (_) {}
        encoder.addArchiveFile(archiveFile);
        fileStream.closeSync();
        // Yield to event loop so Flutter UI frames can render smoothly
        await Future<void>.value();
      }
      encoder.closeSync();
      onProgress?.call(1.0, '打包完成');
      return outputFile;
    } catch (e) {
      try {
        encoder.closeSync();
      } catch (_) {}
      if (outputFile.existsSync()) {
        try {
          outputFile.deleteSync();
        } catch (_) {}
      }
      rethrow;
    }
  }

  /// Inspects archive files to check if all entries share a single common top-level directory.
  static String? findCommonRootDirectory(Archive archive) {
    String? commonRoot;
    for (final file in archive.files) {
      var name = file.name.replaceAll(r'\', '/');
      while (name.startsWith('/')) {
        name = name.substring(1);
      }
      if (name.isEmpty) continue;
      final segments = name.split('/').where((s) => s.isNotEmpty).toList();
      if (segments.isEmpty) continue;

      // If an entry at the top level is a file (e.g. "readme.txt"), there is no single enclosing directory
      if (segments.length == 1 && file.isFile) {
        return null;
      }
      final rootSegment = segments.first;
      if (commonRoot == null) {
        commonRoot = rootSegment;
      } else if (commonRoot != rootSegment) {
        return null;
      }
    }
    return commonRoot;
  }

  /// Sanitizes an archive entry path to prevent Zip Slip directory traversal vulnerabilities.
  static String sanitizeEntryPath(String entryName) {
    var cleaned = entryName.replaceAll(r'\', '/');
    while (cleaned.startsWith('/')) {
      cleaned = cleaned.substring(1);
    }
    if (RegExp(r'^[a-zA-Z]:').hasMatch(cleaned)) {
      cleaned = cleaned.substring(2);
      while (cleaned.startsWith('/')) {
        cleaned = cleaned.substring(1);
      }
    }
    return p.normalize(cleaned);
  }

  /// Unzips [zipFile] into [targetDir] (or an automatically resolved directory alongside the zip).
  static Future<Directory> extractZipArchive({
    required File zipFile,
    Directory? targetDir,
    void Function(double progress, String status)? onProgress,
  }) async {
    if (!zipFile.existsSync()) {
      throw FileSystemException('压缩包文件不存在', zipFile.path);
    }

    final inputStream = InputFileStream(zipFile.path);
    final archive = ZipDecoder().decodeBuffer(inputStream);

    try {
      final commonRoot = findCommonRootDirectory(archive);
      final zipStem = p.basenameWithoutExtension(zipFile.path);

      final Directory destDir;
      final String baseExtractDir;

      if (targetDir != null) {
        destDir = targetDir;
        baseExtractDir = destDir.path;
      } else if (commonRoot != null && commonRoot.toLowerCase() == zipStem.toLowerCase()) {
        destDir = Directory(p.join(zipFile.parent.path, commonRoot));
        baseExtractDir = zipFile.parent.path;
      } else {
        destDir = Directory(p.join(zipFile.parent.path, zipStem));
        baseExtractDir = destDir.path;
      }

      destDir.createSync(recursive: true);

      final total = archive.files.length;
      int processed = 0;

      for (final file in archive.files) {
        processed++;
        final safeName = sanitizeEntryPath(file.name);
        if (safeSafePathCheck(safeName)) {
          continue;
        }

        final outPath = p.normalize(p.join(baseExtractDir, safeName));

        // Strict Zip Slip defense: outPath must be within baseExtractDir or match it
        final canonicalBase = p.canonicalize(baseExtractDir);
        final canonicalOut = p.canonicalize(outPath);
        if (!p.isWithin(canonicalBase, canonicalOut) && canonicalBase != canonicalOut) {
          continue;
        }

        if (file.isFile) {
          final outFile = File(outPath);
          outFile.parent.createSync(recursive: true);
          final data = file.content;
          if (data is List<int>) {
            outFile.writeAsBytesSync(data, flush: true);
          } else if (data is InputStreamBase) {
            outFile.writeAsBytesSync(data.toUint8List(), flush: true);
          }
          file.clear();
        } else {
          Directory(outPath).createSync(recursive: true);
        }

        onProgress?.call(
          processed / (total == 0 ? 1 : total),
          '正在解压: ${p.basename(file.name)} ($processed/$total)',
        );
        // Yield to event loop so Flutter UI frames can render smoothly
        await Future<void>.value();
      }

      onProgress?.call(1.0, '解压完成');
      return destDir;
    } finally {
      inputStream.closeSync();
      archive.clear();
    }
  }

  /// Helper to verify safe path segment and detect Zip Slip traversal.
  static bool safeSafePathCheck(String name) {
    final cleaned = name.replaceAll(r'\', '/');
    final normalized = p.normalize(cleaned);
    if (normalized.startsWith('..')) return true;
    final segments = p.split(normalized);
    return segments.contains('..');
  }
}
