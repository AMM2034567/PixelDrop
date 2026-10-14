import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:share_plus/share_plus.dart';
import 'package:open_filex/open_filex.dart';
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
      _statusText = '准备快速解流...';
      _result = null;
    });

    await WakelockHelper.enable();

    try {
      final res = await PixelDecoderService.decodeVideoToFile(
        videoFile: _selectedVideo!,
        blockSize: _blockSize,
        onProgress: (p, status) {
          setState(() {
            _progress = p;
            _statusText = status;
          });
        },
      );

      setState(() {
        _result = res;
        _isDecoding = false;
        _statusText = '还原成功！';
      });

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('🎉 文件还原并校验成功！已存入 Download/PixelDrop/Restored')),
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
          title: const Row(
            children: [
              Icon(Icons.error_outline, color: Colors.red),
              SizedBox(width: 8),
              Text('还原失败'),
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
          // 1. Pick Video Card
          Card(
            elevation: 2,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: InkWell(
              onTap: _isDecoding ? null : _pickVideo,
              borderRadius: BorderRadius.circular(16),
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  children: [
                    Icon(
                      _selectedVideo == null ? Icons.video_file_outlined : Icons.videocam,
                      size: 54,
                      color: Theme.of(context).colorScheme.secondary,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      _selectedVideo == null
                          ? '点击选择待还原的 MP4 视频'
                          : Uri.decodeComponent(_selectedVideo!.uri.pathSegments.last),
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      textAlign: TextAlign.center,
                    ),
                    if (_selectedVideo != null) ...[
                      const SizedBox(height: 6),
                      Text(
                        '大小: ${_formatBytes(_selectedVideo!.lengthSync())}',
                        style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),

          // 2. Block size selector
          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('解析采样规格', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  RadioListTile<int>(
                    value: 4,
                    groupValue: _blockSize,
                    title: const Text('4x4 采样（默认）'),
                    subtitle: const Text('匹配 4x4 极速高密模式制作的视频'),
                    onChanged: _isDecoding ? null : (v) => setState(() => _blockSize = v!),
                  ),
                  RadioListTile<int>(
                    value: 8,
                    groupValue: _blockSize,
                    title: const Text('8x8 采样'),
                    subtitle: const Text('匹配 8x8 社交抗压模式制作的视频'),
                    onChanged: _isDecoding ? null : (v) => setState(() => _blockSize = v!),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),

          // 3. Action button
          FilledButton.icon(
            onPressed: (_selectedVideo != null && !_isDecoding) ? _startDecoding : null,
            icon: _isDecoding
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : const Icon(Icons.restore_page_outlined),
            label: Text(_isDecoding ? '正在毫秒级逆向解析 (支持切后台)...' : '开始从视频还原文件'),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
          const SizedBox(height: 16),

          // 4. Progress
          if (_isDecoding || _statusText.isNotEmpty) ...[
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

          // 5. Result
          if (_result != null) ...[
            Card(
              color: _result!.isSha256Matched ? Colors.green.shade50 : Colors.red.shade50,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(
                  color: _result!.isSha256Matched ? Colors.green.shade400 : Colors.red.shade400,
                  width: 1.5,
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          _result!.isSha256Matched ? Icons.verified : Icons.error,
                          color: _result!.isSha256Matched ? Colors.green.shade700 : Colors.red,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _result!.isSha256Matched
                              ? '文件还原成功 (SHA-256 100% 吻合)'
                              : '警告：SHA-256 校验不匹配！',
                          style: TextStyle(
                            color: _result!.isSha256Matched
                                ? Colors.green.shade900
                                : Colors.red.shade900,
                            fontWeight: FontWeight.bold,
                            fontSize: 15,
                          ),
                        ),
                      ],
                    ),
                    const Divider(height: 20),
                    Text('文件名: ${_result!.filename}', style: const TextStyle(fontWeight: FontWeight.bold)),
                    Text('大小: ${_formatBytes(_result!.fileSize)}'),
                    const SizedBox(height: 4),
                    Text(
                      '保存位置: ${_result!.restoredFile.path}',
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                    ),
                    const SizedBox(height: 8),
                    // SHA-256 with copy button
                    Row(
                      children: [
                        const Text(
                          'SHA-256 校验指纹:',
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
                    // Action Buttons: Open File, Locate Folder, Share
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: () => OpenFilex.open(_result!.restoredFile.path),
                            icon: const Icon(Icons.file_open_outlined),
                            label: const Text('打开文件'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () async {
                              final dir = await StorageHelper.getRestoredDir();
                              await StorageHelper.openDirectory(dir);
                            },
                            icon: const Icon(Icons.folder_open),
                            label: const Text('定位保存目录'),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    FilledButton.icon(
                      onPressed: () => Share.shareXFiles([XFile(_result!.restoredFile.path)]),
                      icon: const Icon(Icons.share),
                      label: const Text('导出 / 分享文件'),
                      style: FilledButton.styleFrom(
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
