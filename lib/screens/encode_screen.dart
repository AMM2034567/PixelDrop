import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:share_plus/share_plus.dart';
import 'package:open_filex/open_filex.dart';
import '../services/foreground_service.dart';
import '../services/wakelock_helper.dart';
import '../services/pixel_encoder.dart';
import '../services/storage_helper.dart';

class EncodeScreen extends StatefulWidget {
  const EncodeScreen({super.key});

  @override
  State<EncodeScreen> createState() => _EncodeScreenState();
}

class _EncodeScreenState extends State<EncodeScreen> {
  File? _selectedFile;
  int _blockSize = 4; // 4 or 8
  bool _isEncoding = false;
  double _progress = 0.0;
  String _statusText = '';
  EncodeResult? _result;

  void _pickFile() async {
    final result = await FilePicker.platform.pickFiles();
    if (result != null && result.files.single.path != null) {
      setState(() {
        _selectedFile = File(result.files.single.path!);
        _result = null;
        _progress = 0.0;
        _statusText = '';
      });
    }
  }

  void _startEncoding() async {
    if (_selectedFile == null || _isEncoding) return;

    setState(() {
      _isEncoding = true;
      _progress = 0.0;
      _statusText = '准备编码数据...';
      _result = null;
    });

    await WakelockHelper.enable();
    await ForegroundServiceHelper.start(
      title: 'PixelDrop 正在生成视频',
      content: '正在准备像素点阵...',
      progress: 0,
    );

    try {
      final res = await PixelEncoderService.encodeFileToVideo(
        inputFile: _selectedFile!,
        blockSize: _blockSize,
        fps: 10,
        holdFrames: 2,
        crf: 22,
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
          // 1. File Picker / Selected File Card
          _buildFileSection(context),
          const SizedBox(height: 16),

          // 2. Preset Specification
          _buildPresetSection(context),
          const SizedBox(height: 20),

          // 3. Action Button
          FilledButton.icon(
            onPressed: (_selectedFile != null && !_isEncoding) ? _startEncoding : null,
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
            label: Text(_isEncoding ? '正在生成视频...' : '开始生成视频'),
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
    );
  }

  Widget _buildFileSection(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    if (_selectedFile == null) {
      return Card(
        child: InkWell(
          onTap: _isEncoding ? null : _pickFile,
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
                    Icons.upload_file_rounded,
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
                  '支持任意类型文件（文档、压缩包、图片等）',
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

    final filename = Uri.decodeComponent(_selectedFile!.uri.pathSegments.last);
    final fileSize = _selectedFile!.existsSync() ? _formatBytes(_selectedFile!.lengthSync()) : '未知大小';

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                Icons.insert_drive_file_rounded,
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
            if (!_isEncoding) ...[
              IconButton(
                onPressed: () {
                  setState(() {
                    _selectedFile = null;
                    _result = null;
                    _progress = 0.0;
                    _statusText = '';
                  });
                },
                tooltip: '清除选择',
                icon: const Icon(Icons.close_rounded, size: 20),
              ),
              TextButton.icon(
                onPressed: _pickFile,
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
                    value: 4,
                    icon: Icon(Icons.grid_4x4_rounded),
                    label: Text('4x4 像素（高密）'),
                  ),
                  ButtonSegment<int>(
                    value: 8,
                    icon: Icon(Icons.grid_view_rounded),
                    label: Text('8x8 像素（抗噪）'),
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
              _blockSize == 4
                  ? '4x4 模式：单帧容量高，适合网盘中转、原画存储与邮件传输'
                  : '8x8 模式：色块更大容错率高，适合应对社交软件转发时的画面压缩',
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
                    onPressed: () => Share.shareXFiles([XFile(_result!.videoFile.path)]),
                    icon: const Icon(Icons.share_rounded, size: 18),
                    label: const FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text('分享视频'),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      final dir = await StorageHelper.getVideosDir();
                      final openRes = await StorageHelper.openDirectory(dir);
                      if (openRes.type != ResultType.done && context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('无法打开目录: ${openRes.message}')),
                        );
                      }
                    },
                    icon: const Icon(Icons.folder_open_rounded, size: 18),
                    label: const FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text('打开目录'),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () async {
                final openRes = await OpenFilex.open(_result!.videoFile.path);
                if (openRes.type != ResultType.done && context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('无法直接播放: ${openRes.message}')),
                  );
                }
              },
              icon: const Icon(Icons.play_circle_outline_rounded, size: 18),
              label: const FittedBox(
                fit: BoxFit.scaleDown,
                child: Text('播放视频'),
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
