import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixel_drop/services/archive_service.dart';
import 'package:path/path.dart' as p;

void main() {
  group('ArchiveService Unit & Integration Tests', () {
    late Directory tempRoot;

    setUp(() {
      tempRoot = Directory.systemTemp.createTempSync('pixeldrop_archive_test_');
    });

    tearDown(() {
      if (tempRoot.existsSync()) {
        try {
          tempRoot.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    test('scanInputPaths for a single file identifies singleFile and does not need archive', () async {
      final sampleFile = File(p.join(tempRoot.path, 'document.txt'))..writeAsStringSync('Hello PixelDrop');
      final input = await ArchiveService.scanInputPaths([sampleFile.path]);

      expect(input.type, equals(SelectedInputType.singleFile));
      expect(input.needsArchive, isFalse);
      expect(input.fileCount, equals(1));
      expect(input.totalSize, equals(sampleFile.lengthSync()));
      expect(input.displayName, equals('document.txt'));
      expect(input.suggestedArchiveName, equals('document.zip'));
      expect(input.singleFile?.path, equals(sampleFile.path));
    });

    test('scanInputPaths for a single directory collects nested files and marks needsArchive', () async {
      final projectDir = Directory(p.join(tempRoot.path, 'MyProject'))..createSync();
      File(p.join(projectDir.path, 'readme.md')).writeAsStringSync('PixelDrop readme');
      final subDir = Directory(p.join(projectDir.path, 'src'))..createSync();
      File(p.join(subDir.path, 'main.rs')).writeAsStringSync('fn main() {}');

      final input = await ArchiveService.scanInputPaths([projectDir.path]);

      expect(input.type, equals(SelectedInputType.directory));
      expect(input.needsArchive, isTrue);
      expect(input.displayName, equals('MyProject'));
      expect(input.suggestedArchiveName, equals('MyProject.zip'));
      expect(input.fileCount, equals(2));
      expect(input.entries.length, equals(2));

      final relPaths = input.entries.map((e) => e.relativeZipPath).toSet();
      expect(relPaths, contains('MyProject/readme.md'));
      expect(relPaths, contains('MyProject/src/main.rs'));
    });

    test('scanInputPaths for multiple files creates multipleItems bundle', () async {
      final f1 = File(p.join(tempRoot.path, 'fileA.txt'))..writeAsStringSync('AAA');
      final f2 = File(p.join(tempRoot.path, 'fileB.txt'))..writeAsStringSync('BBBBBB');

      final input = await ArchiveService.scanInputPaths([f1.path, f2.path]);

      expect(input.type, equals(SelectedInputType.multipleItems));
      expect(input.needsArchive, isTrue);
      expect(input.fileCount, equals(2));
      expect(input.totalSize, equals(9));
      expect(input.displayName, equals('已选 2 个项目'));
      expect(input.suggestedArchiveName, equals('fileA_bundle.zip'));
    });

    test('scanInputPaths for mixed files and folders', () async {
      final f1 = File(p.join(tempRoot.path, 'root.txt'))..writeAsStringSync('Root File');
      final folder = Directory(p.join(tempRoot.path, 'assets'))..createSync();
      File(p.join(folder.path, 'icon.png')).writeAsStringSync('PNG_DATA');
      File(p.join(folder.path, 'font.ttf')).writeAsStringSync('TTF_DATA');

      final input = await ArchiveService.scanInputPaths([f1.path, folder.path]);

      expect(input.type, equals(SelectedInputType.multipleItems));
      expect(input.needsArchive, isTrue);
      expect(input.fileCount, equals(3));
      expect(input.entries.length, equals(3));

      final relPaths = input.entries.map((e) => e.relativeZipPath).toSet();
      expect(relPaths, contains('root.txt'));
      expect(relPaths, contains('assets/icon.png'));
      expect(relPaths, contains('assets/font.ttf'));
    });

    test('scanInputPaths throws ArgumentError or FileSystemException on empty/invalid paths', () async {
      expect(() => ArchiveService.scanInputPaths([]), throwsArgumentError);
      expect(() => ArchiveService.scanInputPaths(['', '   ']), throwsArgumentError);
      expect(
        () => ArchiveService.scanInputPaths([p.join(tempRoot.path, 'non_existent_12345.xyz')]),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('createZipArchive and extractZipArchive roundtrip bit-exact verification', () async {
      final sourceDir = Directory(p.join(tempRoot.path, 'SourceFolder'))..createSync();
      File(p.join(sourceDir.path, 'notes.txt')).writeAsStringSync('Important Meeting Notes 2026');
      final nestedDir = Directory(p.join(sourceDir.path, 'nested', 'deep'))..createSync(recursive: true);
      File(p.join(nestedDir.path, 'binary.bin')).writeAsBytesSync([10, 20, 30, 40, 50, 60, 70, 80]);

      // 2. Scan
      final input = await ArchiveService.scanInputPaths([sourceDir.path]);
      expect(input.fileCount, equals(2));

      // 3. Package
      final zipPath = p.join(tempRoot.path, 'bundled_output.zip');
      final progressList = <double>[];
      final statusList = <String>[];

      final zipFile = await ArchiveService.createZipArchive(
        entries: input.entries,
        outputZipPath: zipPath,
        onProgress: (p, status) {
          progressList.add(p);
          statusList.add(status);
        },
      );

      expect(zipFile.existsSync(), isTrue);
      expect(zipFile.lengthSync(), greaterThan(0));
      expect(progressList.isNotEmpty, isTrue);
      expect(progressList.last, equals(1.0));
      expect(statusList.last, equals('打包完成'));

      // 4. Extract
      final extractTarget = Directory(p.join(tempRoot.path, 'ExtractedResult'));
      final extractProgressList = <double>[];
      final extractedDir = await ArchiveService.extractZipArchive(
        zipFile: zipFile,
        targetDir: extractTarget,
        onProgress: (p, status) {
          extractProgressList.add(p);
        },
      );

      expect(extractedDir.existsSync(), isTrue);
      expect(extractProgressList.isNotEmpty, isTrue);
      expect(extractProgressList.last, equals(1.0));

      // Verify files
      final extractedNotes = File(p.join(extractTarget.path, 'SourceFolder', 'notes.txt'));
      expect(extractedNotes.existsSync(), isTrue);
      expect(extractedNotes.readAsStringSync(), equals('Important Meeting Notes 2026'));

      final extractedBin = File(p.join(extractTarget.path, 'SourceFolder', 'nested', 'deep', 'binary.bin'));
      expect(extractedBin.existsSync(), isTrue);
      expect(extractedBin.readAsBytesSync(), equals([10, 20, 30, 40, 50, 60, 70, 80]));
    });

    test('safeSafePathCheck prevents zip-slip path traversal', () {
      expect(ArchiveService.safeSafePathCheck('../../etc/passwd'), isTrue);
      expect(ArchiveService.safeSafePathCheck('folder/../../../malicious.sh'), isTrue);
      expect(ArchiveService.safeSafePathCheck(r'folder\..\..\..\malicious.bat'), isTrue);
      expect(ArchiveService.safeSafePathCheck('safe_folder/sub/file.txt'), isFalse);
    });

    test('sanitizeEntryPath cleans leading slashes and drive letters', () {
      expect(ArchiveService.sanitizeEntryPath('/etc/passwd'), equals(p.normalize('etc/passwd')));
      expect(ArchiveService.sanitizeEntryPath(r'\Windows\System32\cmd.exe'), equals(p.normalize('Windows/System32/cmd.exe')));
      expect(ArchiveService.sanitizeEntryPath(r'C:\Windows\System32\calc.exe'), equals(p.normalize('Windows/System32/calc.exe')));
    });

    test('scanInputPaths normalizes paths with trailing slashes', () async {
      final sampleDir = Directory(p.join(tempRoot.path, 'TrailingDir'))..createSync();
      File(p.join(sampleDir.path, 'data.txt')).writeAsStringSync('sample data');

      final input = await ArchiveService.scanInputPaths(['${sampleDir.path}/', '${sampleDir.path}\\']);
      expect(input.displayName, equals('已选 2 个项目'));
      expect(input.fileCount, equals(2));
    });

    test('scanInputPaths handles empty directory gracefully', () async {
      final emptyDir = Directory(p.join(tempRoot.path, 'EmptyFolder'))..createSync();
      final input = await ArchiveService.scanInputPaths([emptyDir.path]);

      expect(input.type, equals(SelectedInputType.directory));
      expect(input.fileCount, equals(0));
      expect(input.totalSize, equals(0));
      expect(input.entries, isEmpty);
      expect(input.suggestedArchiveName, equals('EmptyFolder.zip'));
    });

    test('scanInputPaths deduplicates conflicting folder names in multi-item input', () async {
      final dir1 = Directory(p.join(tempRoot.path, 'workspace1', 'assets'))..createSync(recursive: true);
      File(p.join(dir1.path, 'logo.png')).writeAsStringSync('logo 1');

      final dir2 = Directory(p.join(tempRoot.path, 'workspace2', 'assets'))..createSync(recursive: true);
      File(p.join(dir2.path, 'logo.png')).writeAsStringSync('logo 2');

      final input = await ArchiveService.scanInputPaths([dir1.path, dir2.path]);
      expect(input.type, equals(SelectedInputType.multipleItems));
      expect(input.fileCount, equals(2));

      final relPaths = input.entries.map((e) => e.relativeZipPath).toSet();
      expect(relPaths, contains('assets/logo.png'));
      expect(relPaths, contains('assets_1/logo.png'));
    });

    test('extractZipArchive skips malicious Zip Slip entries that escape output directory', () async {
      // Create a zip with a simulated malicious traversal file
      final zipPath = p.join(tempRoot.path, 'slip_attack.zip');
      final normalFile = File(p.join(tempRoot.path, 'normal.txt'))..writeAsStringSync('legit file');

      final zipFile = await ArchiveService.createZipArchive(
        entries: [
          ArchiveFileEntry(file: normalFile, relativeZipPath: 'safe.txt'),
          ArchiveFileEntry(file: normalFile, relativeZipPath: '../../outside_escape.txt'),
        ],
        outputZipPath: zipPath,
      );

      final outDir = Directory(p.join(tempRoot.path, 'safe_extracted'))..createSync();
      final extracted = await ArchiveService.extractZipArchive(
        zipFile: zipFile,
        targetDir: outDir,
      );

      expect(extracted.existsSync(), isTrue);
      expect(File(p.join(outDir.path, 'safe.txt')).existsSync(), isTrue);
      // Malicious escaped file must NOT exist outside target directory
      expect(File(p.join(tempRoot.path, 'outside_escape.txt')).existsSync(), isFalse);
    });
  });
}
