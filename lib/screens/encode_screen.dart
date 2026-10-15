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
      _statusText = '准备中...';
      _result = null;
    });

    await WakelockHelper.enable();
    await ForegroundServiceHelper.start(
      title: 'PixelDrop 正在制作视频',
      content: '正在准备视频点阵...',
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
            title: 'PixelDrop 正在制作视频',
            content: status,
            progress: (p * 100).toInt(),
          );
        },
      );

      setState(() {
        _result = res;
        _isEncoding = false;
        _statusText = '视频制作完成！';
      });

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('🎉 纯像素点阵 MP4 视频生成成功！已存入 Download/PixelDrop/Videos')),
      );
    } catch (e) {
      setState(() {
        _isEncoding = false;
        _statusText = '制作失败: $e';
      });
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.error_outline, color: Colors.red),
              SizedBox(width: 8),
              Text('制作失败'),
            ],
          ),
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
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 1. Pick File Card
          Card(
            elevation: 2,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: InkWell(
              onTap: _isEncoding ? null : _pickFile,
              borderRadius: BorderRadius.circular(16),
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  children: [
                    Icon(
                      _selectedFile == null ? Icons.upload_file : Icons.insert_drive_file,
                      size: 54,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      _selectedFile == null
                          ? '点击选择任意待传输文件'
                          : Uri.decodeComponent(_selectedFile!.uri.pathSegments.last),
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      textAlign: TextAlign.center,
                    ),
                    if (_selectedFile != null) ...[
                      const SizedBox(height: 6),
                      Text(
                        '大小: ${_formatBytes(_selectedFile!.lengthSync())}',
                        style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),

          // 2. Preset Selection
          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '编码规格预设',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  RadioListTile<int>(
                    value: 4,
                    groupValue: _blockSize,
                    title: const Text('4x4 极速高密档（推荐）'),
                    subtitle: const Text('单帧 7.2KB 容量，适合原画、网盘、邮件，速度极快'),
                    onChanged: _isEncoding ? null : (v) => setState(() => _blockSize = v!),
                  ),
                  RadioListTile<int>(
                    value: 8,
                    groupValue: _blockSize,
                    title: const Text('8x8 社交抗压档'),
                    subtitle: const Text('单帧 1.8KB 容量，方块更大，抗微信/QQ二次转码压缩'),
                    onChanged: _isEncoding ? null : (v) => setState(() => _blockSize = v!),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),

          // 3. Action Button
          ElevatedButton.icon(
            onPressed: (_selectedFile != null && !_isEncoding) ? _startEncoding : null,
            icon: _isEncoding
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : const Icon(Icons.movie_creation_outlined),
            label: Text(_isEncoding ? '正在制作中 (支持切后台)...' : '开始生成 MP4 传输视频'),
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
          const SizedBox(height: 16),

          // 4. Progress Area
          if (_isEncoding || _statusText.isNotEmpty) ...[
            Card(
              color: Colors.grey.shade50,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
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
                            style: const TextStyle(fontWeight: FontWeight.w500),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Text('${(_progress * 100).toInt()}%'),
                      ],
                    ),
                    const SizedBox(height: 8),
                    LinearProgressIndicator(value: _progress, minHeight: 6),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
          ],

          // 5. Result Card with SHA-256 and Locate Folder
          if (_result != null) ...[
            Card(
              color: Colors.green.shade50,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(color: Colors.green.shade300),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.check_circle, color: Colors.green.shade700),
                        const SizedBox(width: 8),
                        Text(
                          '传输视频已生成！',
                          style: TextStyle(
                            color: Colors.green.shade900,
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Text('原文件名: ${_result!.filename}', style: const TextStyle(fontWeight: FontWeight.bold)),
                    Text('原文件大小: ${_formatBytes(_result!.originalSize)}'),
                    Text('生成视频大小: ${_formatBytes(_result!.videoSize)}'),
                    const SizedBox(height: 4),
                    Text(
                      '保存路径: ${_result!.videoFile.path}',
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                    ),
                    const Divider(height: 20),
                    // SHA-256 Display & Copy
                    Row(
                      children: [
                        const Text(
                          'SHA-256 全局指纹:',
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                        ),
                        const Spacer(),
                        TextButton.icon(
                          onPressed: () {
                            Clipboard.setData(ClipboardData(text: _result!.sha256));
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('📋 SHA-256 指纹已复制到剪贴板！')),
                            );
                          },
                          icon: const Icon(Icons.copy, size: 16),
                          label: const Text('复制', style: TextStyle(fontSize: 12)),
                        ),
                      ],
                    ),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.green.shade200),
                      ),
                      child: SelectableText(
                        _result!.sha256,
                        style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
                      ),
                    ),
                    const SizedBox(height: 16),
                    // Action Buttons: Open Folder, Share, Preview
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: () async {
                              final dir = await StorageHelper.getVideosDir();
                              await StorageHelper.openDirectory(dir);
                            },
                            icon: const Icon(Icons.folder_open),
                            label: const Text('定位保存目录'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: () => Share.shareXFiles([XFile(_result!.videoFile.path)]),
                            icon: const Icon(Icons.share),
                            label: const Text('分享视频'),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: () => OpenFilex.open(_result!.videoFile.path),
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('直接播放视频'),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(42),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
