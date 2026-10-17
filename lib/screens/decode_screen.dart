import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:share_plus/share_plus.dart';
import 'package:open_filex/open_filex.dart';
import '../services/foreground_service.dart';
import '../services/wakelock_helper.dart';
import '../services/pixel_decoder.dart';
import '../services/storage_helper.dart';

class DecodeScreen extends StatefulWidget {
  const DecodeScreen({super.key});

  @override
  State<DecodeScreen> createState() => _DecodeScreenState();
}

class _DecodeScreenState extends State<DecodeScreen> {
  File? _selectedVideo;
  int _blockSize = 4;
  bool _isDecoding = false;
  double _progress = 0.0;
  String _statusText = '';
  DecodeResult? _result;

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
      });
    }
  }

  void _startDecoding() async {
    if (_selectedVideo == null || _isDecoding) return;

    setState(() {
      _isDecoding = true;
      _progress = 0.0;
      _statusText = '准备解析视频...';
      _result = null;
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
        blockSize: _blockSize,
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

    return SingleChildScrollView(
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
                  '支持由 PixelDrop 生成的 MP4、MKV 视频',
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

    final filename = Uri.decodeComponent(_selectedVideo!.uri.pathSegments.last);
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
                    value: 4,
                    icon: Icon(Icons.grid_4x4_rounded),
                    label: Text('4x4 采样（默认）'),
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
              _blockSize == 4
                  ? '对应 4x4 高密模式制作的视频进行高精解码'
                  : '对应 8x8 抗噪模式制作的视频进行容错解码',
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
            if (_isDecoding) ...[
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
                      '前台守护服务运行中，切至后台不会中断',
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
            const SizedBox(height: 14),
            const Divider(height: 1),
            const SizedBox(height: 14),
            _buildDetailRow(context, '文件名', _result!.filename),
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

            // Actions
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () async {
                      final openRes = await OpenFilex.open(_result!.restoredFile.path);
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
                    onPressed: () => Share.shareXFiles([XFile(_result!.restoredFile.path)]),
                    icon: const Icon(Icons.share_rounded, size: 18),
                    label: const FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text('分享文件'),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () async {
                final dir = await StorageHelper.getRestoredDir();
                final openRes = await StorageHelper.openDirectory(dir);
                if (openRes.type != ResultType.done && context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('无法打开保存目录: ${openRes.message}')),
                  );
                }
              },
              icon: const Icon(Icons.folder_open_rounded, size: 18),
              label: const FittedBox(
                fit: BoxFit.scaleDown,
                child: Text('打开保存目录'),
              ),
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
