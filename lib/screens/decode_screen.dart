import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:share_plus/share_plus.dart';
import 'package:open_filex/open_filex.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:path/path.dart' as p;
import '../services/foreground_service.dart';
import '../services/wakelock_helper.dart';
import '../services/pixel_decoder.dart';
import '../services/storage_helper.dart';
import '../models/history_record.dart';
import '../services/history_service.dart';
import '../services/archive_service.dart';

class DecodeScreen extends StatefulWidget {
  final DecodeResult? initialResult;
  final File? initialVideoFile;
  const DecodeScreen({super.key, this.initialResult, this.initialVideoFile});

  @override
  State<DecodeScreen> createState() => DecodeScreenState();
}

class DecodeScreenState extends State<DecodeScreen> {
  File? _selectedVideo;
  int _blockSize = 0; // 0 = 自动识别, 2, 4, or 8
  bool _isDecoding = false;
  bool _isDragging = false;
  bool _isExtracting = false;
  double _extractProgress = 0.0;
  String _extractStatus = '';
  String? _extractedDirPath;
  double _progress = 0.0;
  String _statusText = '';
  DecodeResult? _result;

  bool get _isZipArchive =>
      _result != null &&
      (_result!.filename.toLowerCase().endsWith('.zip') ||
          _result!.restoredFile.path.toLowerCase().endsWith('.zip'));

  @override
  void initState() {
    super.initState();
    if (widget.initialResult != null) {
      _result = widget.initialResult;
    } else if (widget.initialVideoFile != null) {
      _selectedVideo = widget.initialVideoFile;
    }
  }

  /// Public handler to load a shared or selected video
  void handleImportVideo(File videoFile) {
    setState(() {
      _selectedVideo = videoFile;
      _result = null;
      _progress = 0.0;
      _statusText = '';
      _extractedDirPath = null;
    });
    if (mounted) {
      final fileName = videoFile.path.split(Platform.pathSeparator).last;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已载入待还原视频: $fileName')),
      );
    }
  }

  @override
  void didUpdateWidget(covariant DecodeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialResult != oldWidget.initialResult) {
      setState(() {
        _result = widget.initialResult;
        _extractedDirPath = null;
        _extractProgress = 0.0;
        _extractStatus = '';
      });
    }
  }

  void _pickVideo() async {
    final res = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['mp4', 'mkv', 'mov', 'avi'],
    );
    if (res != null && res.files.single.path != null) {
      setState(() {
        _selectedVideo = File(res.files.single.path!);
        _result = null;
        _progress = 0.0;
        _statusText = '';
        _extractedDirPath = null;
        _extractProgress = 0.0;
        _extractStatus = '';
      });
    }
  }

  void _extractArchive() async {
    if (_result == null || _isExtracting) return;

    setState(() {
      _isExtracting = true;
      _extractProgress = 0.0;
      _extractStatus = '准备解压归档包...';
    });

    try {
      final destDir = await ArchiveService.extractZipArchive(
        zipFile: _result!.restoredFile,
        onProgress: (p, status) {
          setState(() {
            _extractProgress = p;
            _extractStatus = status;
          });
        },
      );

      setState(() {
        _isExtracting = false;
        _extractedDirPath = destDir.path;
      });

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已成功解压至: ${destDir.path}'),
          action: SnackBarAction(
            label: '定位目录',
            onPressed: () {
              StorageHelper.showInExplorer(destDir);
            },
          ),
        ),
      );
    } catch (e) {
      setState(() {
        _isExtracting = false;
        _extractStatus = '解压失败: $e';
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('解压失败: $e')),
      );
    }
  }

  void _startDecoding() async {
    if (_selectedVideo == null || _isDecoding) return;

    setState(() {
      _isDecoding = true;
      _progress = 0.0;
      _statusText = '准备解析视频...';
      _result = null;
      _extractedDirPath = null;
    });

    await WakelockHelper.enable();
    await ForegroundServiceHelper.start(
      title: 'PixelDrop 正在还原文件',
      content: '正在解析像素点阵...',
      progress: 0,
    );

    try {
      final res = await PixelDecoderService.decodeVideoToFile(
        videoFile: _selectedVideo!,
        blockSize: _blockSize == 0 ? null : _blockSize,
        onProgress: (p, status) {
          setState(() {
            _progress = p;
            _statusText = status;
          });
          ForegroundServiceHelper.update(
            title: 'PixelDrop 正在还原文件',
            content: status,
            progress: (p * 100).toInt(),
          );
        },
      );

      setState(() {
        _result = res;
        _isDecoding = false;
        _statusText = '还原完成';
      });

      // Save to local history
      HistoryService.addRecord(
        type: HistoryType.decode,
        fileName: res.filename,
        targetPath: res.restoredFile.path,
        originalSize: res.fileSize,
        outputSize: res.fileSize,
        sha256: res.sha256,
        blockSize: res.detectedBlockSize,
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('文件已恢复至 Download/PixelDrop/Restored')),
      );
    } catch (e) {
      setState(() {
        _isDecoding = false;
        _statusText = '还原失败: $e';
      });
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('还原失败'),
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
        if (!_isDecoding) setState(() => _isDragging = true);
      },
      onDragExited: (details) {
        setState(() => _isDragging = false);
      },
      onDragDone: (details) {
        setState(() => _isDragging = false);
        if (!_isDecoding && details.files.isNotEmpty) {
          final dropped = details.files.first;
          final entityType = FileSystemEntity.typeSync(dropped.path);
          if (entityType == FileSystemEntityType.directory) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('请拖拽有效的视频文件，而非文件夹')),
            );
            return;
          }
          setState(() {
            _selectedVideo = File(dropped.path);
            _result = null;
            _progress = 0.0;
            _statusText = '';
          });
          if (details.files.length > 1) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('已导入第 1 个视频: ${details.files.first.name}')),
            );
          }
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
                    // 1. Pick Video Section
                    _buildVideoSection(context),
                    const SizedBox(height: 16),

                    // 2. Preset Selection
                    _buildPresetSection(context),
                    const SizedBox(height: 20),

                    // 3. Action button
                    FilledButton.icon(
                      onPressed: (_selectedVideo != null && !_isDecoding) ? _startDecoding : null,
                      icon: _isDecoding
                          ? SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: colorScheme.onPrimary,
                              ),
                            )
                          : const Icon(Icons.restore_page_outlined),
                      label: Text(_isDecoding ? '正在还原文件...' : '开始还原文件'),
                    ),
                    const SizedBox(height: 16),

                    // 4. Progress Area
                    if (_isDecoding || (_statusText.isNotEmpty && _result == null)) ...[
                      _buildProgressCard(context),
                      const SizedBox(height: 16),
                    ],

                    // 5. Result Area
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
                      color: colorScheme.secondaryContainer,
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(color: colorScheme.secondary, width: 2),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.video_file_rounded,
                          size: 56,
                          color: colorScheme.onSecondaryContainer,
                        ),
                        const SizedBox(height: 14),
                        Text(
                          '松开鼠标以导入待还原视频',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: colorScheme.onSecondaryContainer,
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

  Widget _buildVideoSection(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    if (_selectedVideo == null) {
      return Card(
        child: InkWell(
          onTap: _isDecoding ? null : _pickVideo,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 20),
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
                    Icons.video_file_outlined,
                    size: 28,
                    color: colorScheme.secondary,
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  '选择待还原视频',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  Platform.isWindows
                      ? '支持由 PixelDrop 生成的视频（点击选择或拖拽至窗口）'
                      : '支持由 PixelDrop 生成的 MP4、MKV 视频',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final filename = p.basename(_selectedVideo!.path);
    final fileSize = _selectedVideo!.existsSync() ? _formatBytes(_selectedVideo!.lengthSync()) : '未知大小';

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: colorScheme.secondaryContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                Icons.video_library_rounded,
                color: colorScheme.onSecondaryContainer,
                size: 24,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    filename,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '大小: $fileSize',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            if (!_isDecoding) ...[
              IconButton(
                onPressed: () {
                  setState(() {
                    _selectedVideo = null;
                    _result = null;
                    _progress = 0.0;
                    _statusText = '';
                    _extractedDirPath = null;
                  });
                },
                tooltip: '清除选择',
                icon: const Icon(Icons.close_rounded, size: 20),
              ),
              TextButton.icon(
                onPressed: _pickVideo,
                icon: const Icon(Icons.swap_horiz_rounded, size: 18),
                label: const Text('更换'),
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
              '解析采样规格',
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
                    value: 0,
                    icon: Icon(Icons.auto_awesome_rounded),
                    label: Text('自动识别'),
                  ),
                  ButtonSegment<int>(
                    value: 2,
                    icon: Icon(Icons.flash_on_rounded),
                    label: Text('2x2 采样'),
                  ),
                  ButtonSegment<int>(
                    value: 4,
                    icon: Icon(Icons.grid_4x4_rounded),
                    label: Text('4x4 采样'),
                  ),
                  ButtonSegment<int>(
                    value: 8,
                    icon: Icon(Icons.grid_view_rounded),
                    label: Text('8x8 采样'),
                  ),
                ],
                selected: {_blockSize},
                onSelectionChanged: _isDecoding
                    ? null
                    : (selection) => setState(() => _blockSize = selection.first),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              _blockSize == 0
                  ? '自动探测首帧魔数与校验和，自动适配 2x2、4x4 或 8x8 点阵规格（推荐）'
                  : _blockSize == 2
                      ? '解析 2x2 极速高密点阵视频（支持 1080p / 720p 分辨率自适应）'
                      : _blockSize == 4
                          ? '解析 4x4 规格制作的点阵视频（支持 1080p / 720p 分辨率自适应）'
                          : '解析 8x8 规格制作的点阵视频（支持 1080p / 720p 分辨率自适应）',
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
            if (Platform.isAndroid && _isDecoding) ...[
              const SizedBox(height: 10),
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
                      '已开启后台保活，切换应用不影响还原',
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
    final isMatched = _result!.isSha256Matched;

    return Card(
      color: colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: isMatched
              ? colorScheme.primary.withOpacity(0.3)
              : colorScheme.error.withOpacity(0.5),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(18.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  isMatched ? Icons.verified_rounded : Icons.warning_amber_rounded,
                  color: isMatched ? Colors.green.shade600 : colorScheme.error,
                  size: 22,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isMatched ? '文件还原成功' : '文件还原完成（校验不一致）',
                        style: theme.textTheme.titleMedium?.copyWith(
                           fontWeight: FontWeight.w700,
                          color: isMatched ? colorScheme.onSurface : colorScheme.error,
                        ),
                      ),
                      Text(
                        isMatched
                            ? 'SHA-256 校验通过，与源文件完全一致'
                            : '哈希指纹未完全匹配，视频可能经历了二次转码压缩',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: isMatched
                              ? colorScheme.onSurfaceVariant
                              : colorScheme.error.withOpacity(0.8),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (_result!.fecRecoveredCount > 0) ...[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.green.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.green.withOpacity(0.3)),
                ),
                child: Row(
                  children: [
                    Icon(Icons.health_and_safety_rounded, color: Colors.green.shade700, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '抗掉帧 FEC 纠删码生效：成功恢复 ${_result!.fecRecoveredCount} 个丢失帧并 100% 完整复原',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: Colors.green.shade800,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 14),
            const Divider(height: 1),
            const SizedBox(height: 14),
            _buildDetailRow(context, '文件名', _result!.filename),
            _buildDetailRow(context, '点阵规格', '${_result!.detectedBlockSize}x${_result!.detectedBlockSize} 像素'),
            if (_result!.fecRecoveredCount > 0)
              _buildDetailRow(context, '容灾修复', '已成功复原 ${_result!.fecRecoveredCount} 个丢帧 (FEC)'),
            _buildDetailRow(context, '文件大小', _formatBytes(_result!.fileSize)),
            _buildDetailRow(context, '保存路径', _result!.restoredFile.path, isMuted: true),
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

            // Zip Archive Extraction Section
            if (_isZipArchive) ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: colorScheme.secondaryContainer.withOpacity(0.4),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: colorScheme.secondary.withOpacity(0.3)),
                ),
                child: Row(
                  children: [
                    Icon(Icons.folder_zip_rounded, color: colorScheme.secondary, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _extractedDirPath != null
                            ? '已成功解压至: $_extractedDirPath'
                            : '检测到还原文件为 ZIP 归档包，支持一键解压到当前目录',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSecondaryContainer,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _isExtracting ? null : _extractArchive,
                  icon: _isExtracting
                      ? SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: colorScheme.onPrimary,
                          ),
                        )
                      : const Icon(Icons.unarchive_rounded, size: 18),
                  label: Text(_isExtracting
                      ? (_extractStatus.isNotEmpty ? _extractStatus : '正在解压中...')
                      : '一键解压 (解压到当前目录)'),
                ),
              ),
              if (_isExtracting && _extractProgress > 0) ...[
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: _extractProgress,
                    minHeight: 4,
                  ),
                ),
              ],
              const SizedBox(height: 12),
            ],

            // Actions
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () async {
                      final openRes = await StorageHelper.openFile(_result!.restoredFile);
                      if (openRes.type != ResultType.done && context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('无法打开文件: ${openRes.message}')),
                        );
                      }
                    },
                    icon: const Icon(Icons.file_open_outlined, size: 18),
                    label: const FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text('打开文件'),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      final targetDir = _extractedDirPath != null
                          ? Directory(_extractedDirPath!)
                          : _result!.restoredFile;
                      final openRes = await StorageHelper.showInExplorer(targetDir);
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
                      await Clipboard.setData(ClipboardData(text: _result!.restoredFile.path));
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('已复制还原文件路径: ${_result!.restoredFile.path}')),
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
                        await Share.shareXFiles([XFile(_result!.restoredFile.path)]);
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
                      child: Text('分享文件'),
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
