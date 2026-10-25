import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:share_plus/share_plus.dart';
import 'package:open_filex/open_filex.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import '../services/foreground_service.dart';
import '../services/wakelock_helper.dart';
import '../services/pixel_encoder.dart';
import '../services/storage_helper.dart';
import '../models/history_record.dart';
import '../services/history_service.dart';
import '../services/archive_service.dart';

class EncodeScreen extends StatefulWidget {
  const EncodeScreen({super.key});

  @override
  State<EncodeScreen> createState() => _EncodeScreenState();
}

class _EncodeScreenState extends State<EncodeScreen> {
  SelectedInput? _selectedInput;
  int _blockSize = 4; // 2, 4, or 8
  int _resolution = 1080; // 1080 or 720
  int _holdFrames = 1; // 1 (default fast transfer) or 2 (noise tolerant)
  int _workerThreads = 0; // 0 = 自动 (平台自适应)
  bool _isEncoding = false;
  bool _isDragging = false;
  double _progress = 0.0;
  String _statusText = '';
  EncodeResult? _result;

  bool get _isDesktop => Platform.isWindows || Platform.isLinux || Platform.isMacOS;
  int get _cpuCount => Platform.numberOfProcessors;
  int get _optimalWorkers => PixelEncoderService.getOptimalWorkerCount();
  int get _activeWorkers => _workerThreads > 0 ? _workerThreads : _optimalWorkers;

  void _pickFiles() async {
    try {
      final result = await FilePicker.platform.pickFiles(allowMultiple: true);
      if (result != null && result.paths.isNotEmpty) {
        final validPaths = result.paths.whereType<String>().toList();
        if (validPaths.isNotEmpty) {
          await _processSelectedPaths(validPaths);
        }
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('选择文件出错: $e')),
      );
    }
  }

  void _pickDirectory() async {
    try {
      final dirPath = await FilePicker.platform.getDirectoryPath();
      if (dirPath != null && dirPath.isNotEmpty) {
        await _processSelectedPaths([dirPath]);
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('选择文件夹出错: $e')),
      );
    }
  }

  Future<void> _processSelectedPaths(List<String> paths) async {
    try {
      final input = await ArchiveService.scanInputPaths(paths);
      setState(() {
        _selectedInput = input;
        _result = null;
        _progress = 0.0;
        _statusText = '';
      });
      if (!mounted) return;
      if (input.type == SelectedInputType.directory) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已导入文件夹: ${input.displayName} (包含 ${input.fileCount} 个文件)')),
        );
      } else if (input.type == SelectedInputType.multipleItems) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已导入 ${input.paths.length} 个项目 (包含 ${input.fileCount} 个文件)')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导入失败: $e')),
      );
    }
  }

  void _startEncoding() async {
    final input = _selectedInput;
    if (input == null || _isEncoding) return;

    if (input.fileCount == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(input.type == SelectedInputType.directory
              ? '所选文件夹为空，没有可打包的文件'
              : '所选项目为空，没有可打包的文件'),
        ),
      );
      return;
    }

    setState(() {
      _isEncoding = true;
      _progress = 0.0;
      _statusText = input.needsArchive ? '准备打包归档文件...' : '准备编码数据...';
      _result = null;
    });

    await WakelockHelper.enable();
    await ForegroundServiceHelper.start(
      title: 'PixelDrop 正在生成视频',
      content: input.needsArchive ? '正在打包归档文件...' : '正在准备像素点阵...',
      progress: 0,
    );

    File? tempArchiveFile;
    Directory? tempArchiveDir;

    try {
      File fileToEncode;

      if (input.needsArchive) {
        // 1. Packaging Archive Phase
        final tempDir = await getTemporaryDirectory();
        final timestamp = DateTime.now().millisecondsSinceEpoch;
        tempArchiveDir = Directory(p.join(tempDir.path, 'pixeldrop_archives', '$timestamp'))
          ..createSync(recursive: true);
        final outZipPath = p.join(tempArchiveDir.path, input.suggestedArchiveName);

        tempArchiveFile = await ArchiveService.createZipArchive(
          entries: input.entries,
          outputZipPath: outZipPath,
          onProgress: (ratio, status) {
            setState(() {
              _progress = ratio;
              _statusText = status;
            });
            ForegroundServiceHelper.update(
              title: 'PixelDrop 正在打包归档',
              content: status,
              progress: (ratio * 100).toInt(),
            );
          },
        );

        fileToEncode = tempArchiveFile;
      } else {
        // Single file directly
        fileToEncode = input.singleFile!;
      }

      // 2. Video Encoding Phase
      setState(() {
        _progress = 0.0;
        _statusText = '准备编码数据...';
      });

      final res = await PixelEncoderService.encodeFileToVideo(
        inputFile: fileToEncode,
        blockSize: _blockSize,
        width: _resolution == 1080 ? 1920 : 1280,
        height: _resolution == 1080 ? 1080 : 720,
        fps: 30,
        holdFrames: _holdFrames,
        crf: PixelEncoderService.defaultCrf,
        workerCount: _workerThreads > 0 ? _workerThreads : null,
        onProgress: (p, status) {
          setState(() {
            _progress = p;
            _statusText = status;
          });
          ForegroundServiceHelper.update(
            title: 'PixelDrop 正在生成视频',
            content: status,
            progress: (p * 100).toInt(),
          );
        },
      );

      setState(() {
        _result = res;
        _isEncoding = false;
        _statusText = '视频制作完成';
      });

      // Save to local history
      HistoryService.addRecord(
        type: HistoryType.encode,
        fileName: res.filename,
        targetPath: res.videoFile.path,
        originalSize: res.originalSize,
        outputSize: res.videoSize,
        sha256: res.sha256,
        blockSize: _blockSize,
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('视频已保存至 Download/PixelDrop/Videos')),
      );
    } catch (e) {
      setState(() {
        _isEncoding = false;
        _statusText = '生成失败: $e';
      });
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('生成失败'),
          content: SingleChildScrollView(
            child: SelectableText(e.toString()),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
    } finally {
      if (tempArchiveDir != null && tempArchiveDir.existsSync()) {
        try {
          tempArchiveDir.deleteSync(recursive: true);
        } catch (_) {}
      }
      await ForegroundServiceHelper.stop();
      await WakelockHelper.disable();
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return DropTarget(
      onDragEntered: (details) {
        if (!_isEncoding) setState(() => _isDragging = true);
      },
      onDragExited: (details) {
        setState(() => _isDragging = false);
      },
      onDragDone: (details) async {
        setState(() => _isDragging = false);
        if (!_isEncoding && details.files.isNotEmpty) {
          final paths = details.files.map((f) => f.path).toList();
          await _processSelectedPaths(paths);
        }
      },
      child: Stack(
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 820),
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // 1. File Picker / Selected File Card
                    _buildFileSection(context),
                    const SizedBox(height: 16),

                    // 2. Preset Specification
                    _buildPresetSection(context),
                    const SizedBox(height: 20),

                    // 3. Action Button
                    FilledButton.icon(
                      onPressed: (_selectedInput != null && !_isEncoding) ? _startEncoding : null,
                      icon: _isEncoding
                          ? SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: colorScheme.onPrimary,
                              ),
                            )
                          : const Icon(Icons.movie_creation_outlined),
                      label: Text(_isEncoding
                          ? (_selectedInput?.needsArchive == true && _statusText.contains('打包')
                              ? '正在打包归档...'
                              : '正在生成视频...')
                          : (_selectedInput?.needsArchive == true ? '打包并生成视频' : '开始生成视频')),
                    ),
                    const SizedBox(height: 16),

                    // 4. Progress Area
                    if (_isEncoding || (_statusText.isNotEmpty && _result == null)) ...[
                      _buildProgressCard(context),
                      const SizedBox(height: 16),
                    ],

                    // 5. Result Card
                    if (_result != null) ...[
                      _buildResultCard(context),
                    ],
                  ],
                ),
              ),
            ),
          ),
          if (_isDragging)
            Positioned.fill(
              child: Container(
                color: colorScheme.surface.withOpacity(0.85),
                child: Center(
                  child: Container(
                    margin: const EdgeInsets.all(24),
                    padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 32),
                    decoration: BoxDecoration(
                      color: colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(color: colorScheme.primary, width: 2),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.drive_folder_upload_rounded,
                          size: 56,
                          color: colorScheme.onPrimaryContainer,
                        ),
                        const SizedBox(height: 14),
                        Text(
                          '松开鼠标以导入文件或文件夹',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: colorScheme.onPrimaryContainer,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildFileSection(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    if (_selectedInput == null) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 20),
          child: Column(
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHighest,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.drive_folder_upload_rounded,
                  size: 28,
                  color: colorScheme.primary,
                ),
              ),
              const SizedBox(height: 14),
              Text(
                '选择待转换文件',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                Platform.isWindows
                    ? '支持单文件、多文件拖拽或整个文件夹一键打包'
                    : '支持单文件、多文件或整个文件夹一键打包',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 12,
                runSpacing: 8,
                children: [
                  FilledButton.tonalIcon(
                    onPressed: _isEncoding ? null : _pickFiles,
                    icon: const Icon(Icons.file_open_outlined, size: 18),
                    label: const Text('选择文件 (支持多选)'),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: _isEncoding ? null : _pickDirectory,
                    icon: const Icon(Icons.folder_open_rounded, size: 18),
                    label: const Text('选择文件夹'),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }

    final input = _selectedInput!;
    final IconData typeIcon;
    final String typeSubtitle;

    switch (input.type) {
      case SelectedInputType.singleFile:
        typeIcon = Icons.insert_drive_file_rounded;
        typeSubtitle = '大小: ${_formatBytes(input.totalSize)}';
        break;
      case SelectedInputType.directory:
        typeIcon = Icons.folder_rounded;
        typeSubtitle = '文件夹 · 包含 ${input.fileCount} 个文件，共 ${_formatBytes(input.totalSize)}';
        break;
      case SelectedInputType.multipleItems:
        typeIcon = Icons.inventory_2_rounded;
        typeSubtitle = '包含 ${input.fileCount} 个文件，共 ${_formatBytes(input.totalSize)}';
        break;
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    typeIcon,
                    color: colorScheme.onPrimaryContainer,
                    size: 24,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        input.displayName,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        typeSubtitle,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                if (!_isEncoding) ...[
                  IconButton(
                    onPressed: () {
                      setState(() {
                        _selectedInput = null;
                        _result = null;
                        _progress = 0.0;
                        _statusText = '';
                      });
                    },
                    tooltip: '清除选择',
                    icon: const Icon(Icons.close_rounded, size: 20),
                  ),
                  PopupMenuButton<String>(
                    tooltip: '更换选择',
                    icon: const Icon(Icons.swap_horiz_rounded, size: 20),
                    onSelected: (val) {
                      if (val == 'files') {
                        _pickFiles();
                      } else if (val == 'folder') {
                        _pickDirectory();
                      }
                    },
                    itemBuilder: (ctx) => [
                      const PopupMenuItem(
                        value: 'files',
                        child: Row(
                          children: [
                            Icon(Icons.file_open_outlined, size: 18),
                            SizedBox(width: 8),
                            Text('更换文件 (多选)'),
                          ],
                        ),
                      ),
                      const PopupMenuItem(
                        value: 'folder',
                        child: Row(
                          children: [
                            Icon(Icons.folder_open_rounded, size: 18),
                            SizedBox(width: 8),
                            Text('更换文件夹'),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
            if (input.needsArchive) ...[
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHighest.withOpacity(0.5),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.archive_outlined,
                      size: 15,
                      color: colorScheme.primary,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '自动打包归档为: ${input.suggestedArchiveName}',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildPresetSection(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '编码规格',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: SegmentedButton<int>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment<int>(
                    value: 2,
                    icon: Icon(Icons.flash_on_rounded),
                    label: Text('2x2 像素'),
                  ),
                  ButtonSegment<int>(
                    value: 4,
                    icon: Icon(Icons.grid_4x4_rounded),
                    label: Text('4x4 像素'),
                  ),
                  ButtonSegment<int>(
                    value: 8,
                    icon: Icon(Icons.grid_view_rounded),
                    label: Text('8x8 像素'),
                  ),
                ],
                selected: {_blockSize},
                onSelectionChanged: _isEncoding
                    ? null
                    : (selection) => setState(() => _blockSize = selection.first),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              _blockSize == 2
                  ? '2x2 规格（极速高密）：单帧约 ${_resolution == 1080 ? '194' : '86'} KB，视频体积减少 ~60%，耗时骤降'
                  : _blockSize == 4
                      ? '4x4 规格（标准均衡）：单帧约 ${_resolution == 1080 ? '47' : '21'} KB，默认推荐，传输效率与容错兼备'
                      : '8x8 规格（高容错）：色块更大容错率更高，抗画面压缩与噪点（单帧约 ${_resolution == 1080 ? '12' : '5.4'} KB）',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 14),
            Text(
              '视频分辨率',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: SegmentedButton<int>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment<int>(
                    value: 1080,
                    icon: Icon(Icons.hd_rounded),
                    label: Text('1080p 全高清'),
                  ),
                  ButtonSegment<int>(
                    value: 720,
                    icon: Icon(Icons.sd_rounded),
                    label: Text('720p 高清'),
                  ),
                ],
                selected: {_resolution},
                onSelectionChanged: _isEncoding
                    ? null
                    : (selection) => setState(() => _resolution = selection.first),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              _resolution == 1080
                  ? '1080p (1920x1080)：全高清画质，单帧容量 ${_blockSize == 2 ? '约 194 KB' : _blockSize == 4 ? '约 47 KB' : '约 12 KB'}'
                  : '720p (1280x720)：高清画质，单帧容量 ${_blockSize == 2 ? '约 86 KB' : _blockSize == 4 ? '约 21 KB' : '约 5.4 KB'}，兼容老旧设备',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 14),
            Text(
              '帧留存率 (Hold Frames)',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: SegmentedButton<int>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment<int>(
                    value: 1,
                    icon: Icon(Icons.flash_on_rounded),
                    label: Text('1 帧 (极速)'),
                  ),
                  ButtonSegment<int>(
                    value: 2,
                    icon: Icon(Icons.shield_outlined),
                    label: Text('2 帧 (容错)'),
                  ),
                ],
                selected: {_holdFrames},
                onSelectionChanged: _isEncoding
                    ? null
                    : (selection) => setState(() => _holdFrames = selection.first),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              _holdFrames == 1
                  ? '1 帧：点阵单帧传输，体积最小速度最快（推荐直接传文件）'
                  : '2 帧：每块持续 2 帧，抗屏幕翻拍抖动与二重压缩丢帧',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 14),
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 6,
              children: [
                Text(
                  '多核并行加速',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text.rich(
                    TextSpan(
                      children: [
                        WidgetSpan(
                          alignment: PlaceholderAlignment.middle,
                          child: Padding(
                            padding: const EdgeInsets.only(right: 4),
                            child: Icon(
                              Icons.bolt_rounded,
                              size: 14,
                              color: colorScheme.onPrimaryContainer,
                            ),
                          ),
                        ),
                        TextSpan(
                          text: PixelEncoderService.getAcceleratorStatus(_activeWorkers),
                        ),
                      ],
                    ),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: colorScheme.onPrimaryContainer,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ChoiceChip(
                  avatar: const Icon(Icons.auto_mode_rounded, size: 16),
                  label: Text('自动 ($_optimalWorkers 线程)'),
                  selected: _workerThreads == 0,
                  onSelected: _isEncoding ? null : (_) => setState(() => _workerThreads = 0),
                ),
                ChoiceChip(
                  avatar: const Icon(Icons.eco_outlined, size: 16),
                  label: const Text('单线程 (节能)'),
                  selected: _workerThreads == 1,
                  onSelected: _isEncoding ? null : (_) => setState(() => _workerThreads = 1),
                ),
                if (_isDesktop && _cpuCount >= 4)
                  ChoiceChip(
                    avatar: const Icon(Icons.speed_rounded, size: 16),
                    label: const Text('4 线程'),
                    selected: _workerThreads == 4,
                    onSelected: _isEncoding ? null : (_) => setState(() => _workerThreads = 4),
                  ),
                if (_isDesktop && _cpuCount >= 8)
                  ChoiceChip(
                    avatar: const Icon(Icons.rocket_launch_outlined, size: 16),
                    label: const Text('8 线程'),
                    selected: _workerThreads == 8,
                    onSelected: _isEncoding ? null : (_) => setState(() => _workerThreads = 8),
                  ),
                if (_isDesktop && _cpuCount > 8)
                  ChoiceChip(
                    avatar: const Icon(Icons.flash_on_rounded, size: 16),
                    label: Text('全核心 ($_cpuCount 线程)'),
                    selected: _workerThreads == _cpuCount,
                    onSelected: _isEncoding ? null : (_) => setState(() => _workerThreads = _cpuCount),
                  ),
                if (!_isDesktop && _cpuCount >= 4)
                  ChoiceChip(
                    avatar: const Icon(Icons.balance_rounded, size: 16),
                    label: const Text('双线程 (均衡)'),
                    selected: _workerThreads == 2,
                    onSelected: _isEncoding ? null : (_) => setState(() => _workerThreads = 2),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              _isDesktop
                  ? 'PC 平台专属调优：当前设备共有 $_cpuCount 个 CPU 逻辑核心，已分配 $_activeWorkers 个 Isolate 线程并行渲染点阵帧，充分释放硬件多核性能。'
                  : '移动端设备专属调优：采用 $_activeWorkers 线程保守并发，平衡点阵帧渲染性能与发热功耗，防止触发低内存清理 (LMK)。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProgressCard(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Card(
      color: colorScheme.surfaceContainer,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    _statusText,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  '${(_progress * 100).toInt()}%',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: colorScheme.primary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: _progress > 0 ? _progress : null,
                minHeight: 6,
              ),
            ),
            if (_isEncoding) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(
                    Icons.bolt_rounded,
                    size: 14,
                    color: colorScheme.primary,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _isDesktop
                          ? '多核并行加速生效中：$_activeWorkers 线程并行渲染点阵帧'
                          : '移动端温控模式生效中：$_activeWorkers 线程并发',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ],
            if (Platform.isAndroid && _isEncoding) ...[
              const SizedBox(height: 6),
              Row(
                children: [
                  Icon(
                    Icons.info_outline_rounded,
                    size: 14,
                    color: colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '已开启后台保活，切换应用不影响生成',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildResultCard(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Card(
      color: colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: colorScheme.primary.withOpacity(0.3)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(18.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.check_circle_rounded,
                  color: colorScheme.primary,
                  size: 22,
                ),
                const SizedBox(width: 8),
                Text(
                  '视频已生成',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            _buildDetailRow(context, '源文件名', _result!.filename),
            _buildDetailRow(context, '源文件大小', _formatBytes(_result!.originalSize)),
            _buildDetailRow(context, '视频大小', _formatBytes(_result!.videoSize)),
            _buildDetailRow(context, '保存路径', _result!.videoFile.path, isMuted: true),
            const SizedBox(height: 14),
            const Divider(height: 1),
            const SizedBox(height: 14),

            // SHA-256 Checksum block
            Row(
              children: [
                Text(
                  'SHA-256 校验和',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: _result!.sha256));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('SHA-256 校验和已复制')),
                    );
                  },
                  icon: const Icon(Icons.copy_rounded, size: 15),
                  label: const Text('复制', style: TextStyle(fontSize: 12)),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest.withOpacity(0.5),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: colorScheme.outlineVariant.withOpacity(0.4)),
              ),
              child: SelectableText(
                _result!.sha256,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                  fontSize: 11.5,
                  letterSpacing: 0.2,
                ),
              ),
            ),
            const SizedBox(height: 18),

            // Actions
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () async {
                      final openRes = await StorageHelper.openFile(_result!.videoFile);
                      if (openRes.type != ResultType.done && context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('无法直接播放: ${openRes.message}')),
                        );
                      }
                    },
                    icon: const Icon(Icons.play_circle_filled_rounded, size: 18),
                    label: const FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text('播放视频'),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      final openRes = await StorageHelper.showInExplorer(_result!.videoFile);
                      if (openRes.type != ResultType.done && context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('无法定位目录: ${openRes.message}')),
                        );
                      }
                    },
                    icon: const Icon(Icons.folder_open_rounded, size: 18),
                    label: const FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text('定位目录'),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: _result!.videoFile.path));
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('已复制视频完整路径: ${_result!.videoFile.path}')),
                        );
                      }
                    },
                    icon: const Icon(Icons.copy_rounded, size: 18),
                    label: const FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text('复制路径'),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      try {
                        await Share.shareXFiles([XFile(_result!.videoFile.path)]);
                      } catch (e) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('分享提示: $e')),
                          );
                        }
                      }
                    },
                    icon: const Icon(Icons.share_rounded, size: 18),
                    label: const FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text('分享视频'),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDetailRow(
    BuildContext context,
    String label,
    String value, {
    bool isMuted = false,
  }) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: isMuted ? FontWeight.normal : FontWeight.w600,
                color: isMuted ? colorScheme.onSurfaceVariant : colorScheme.onSurface,
              ),
              overflow: isMuted ? TextOverflow.ellipsis : TextOverflow.clip,
            ),
          ),
        ],
      ),
    );
  }
}
