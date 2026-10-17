import 'package:flutter/material.dart';
import '../widgets/dot_matrix_logo.dart';
import 'encode_screen.dart';
import 'decode_screen.dart';
import 'history_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _currentIndex = 0;

  final List<Widget> _screens = const [
    EncodeScreen(),
    DecodeScreen(),
    HistoryScreen(),
  ];

  void _showInfoSheet() {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: DotMatrixLogo(
                        size: 28,
                        color: colorScheme.primary,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'PixelDrop',
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          '离线点阵视频文件传输 · v0.6.0-beta',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                _buildInfoSection(
                  context,
                  title: '工作原理',
                  content:
                      'PixelDrop 将二进制文件字节映射为黑白像素点阵并生成 MP4 视频。接收端导入该视频即可逆向解析提取原文件，支持离线无网传输。',
                ),
                const SizedBox(height: 16),
                _buildInfoSection(
                  context,
                  title: '规格选择',
                  content:
                      '• 4x4 像素：单帧数据容量更大，生成视频更短，适合网盘中转与原画保存。\n• 8x8 像素：点阵方块更大，抗噪容错率更高，耐受社交软件二次画面压缩。',
                ),
                const SizedBox(height: 16),
                _buildInfoSection(
                  context,
                  title: '数据完整性',
                  content:
                      '内置帧级校验与 SHA-256 全量校验，文件还原后自动比对哈希值，确保文件完全一致。',
                ),
                const SizedBox(height: 16),
                _buildInfoSection(
                  context,
                  title: '存储位置',
                  content:
                      '• 视频目录: Downloads/PixelDrop/Videos\n• 还原目录: Downloads/PixelDrop/Restored',
                ),
                const SizedBox(height: 24),
                FilledButton.tonal(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('我知道了'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildInfoSection(
    BuildContext context, {
    required String title,
    required String content,
  }) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w600,
            color: colorScheme.primary,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          content,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: colorScheme.onSurfaceVariant,
            height: 1.45,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        title: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            DotMatrixLogo(size: 24),
            SizedBox(width: 10),
            Flexible(
              child: Text(
                'PixelDrop',
                style: TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.3,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.info_outline_rounded),
            tooltip: '使用说明',
            onPressed: _showInfoSheet,
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final isWide = constraints.maxWidth >= 640;
          if (isWide) {
            return Row(
              children: [
                NavigationRail(
                  selectedIndex: _currentIndex,
                  onDestinationSelected: (idx) => setState(() => _currentIndex = idx),
                  labelType: NavigationRailLabelType.all,
                  groupAlignment: -0.8,
                  destinations: const [
                    NavigationRailDestination(
                      icon: Icon(Icons.file_upload_outlined),
                      selectedIcon: Icon(Icons.file_upload_rounded),
                      label: Text('文件转视频'),
                    ),
                    NavigationRailDestination(
                      icon: Icon(Icons.video_file_outlined),
                      selectedIcon: Icon(Icons.video_file_rounded),
                      label: Text('视频转文件'),
                    ),
                    NavigationRailDestination(
                      icon: Icon(Icons.history_rounded),
                      selectedIcon: Icon(Icons.history_edu_rounded),
                      label: Text('传输历史'),
                    ),
                  ],
                ),
                const VerticalDivider(thickness: 1, width: 1),
                Expanded(
                  child: IndexedStack(
                    index: _currentIndex,
                    children: _screens,
                  ),
                ),
              ],
            );
          }
          return IndexedStack(
            index: _currentIndex,
            children: _screens,
          );
        },
      ),
      bottomNavigationBar: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth >= 640) {
            return const SizedBox.shrink();
          }
          return NavigationBar(
            selectedIndex: _currentIndex,
            onDestinationSelected: (idx) => setState(() => _currentIndex = idx),
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.file_upload_outlined),
                selectedIcon: Icon(Icons.file_upload_rounded),
                label: '文件转视频',
              ),
              NavigationDestination(
                icon: Icon(Icons.video_file_outlined),
                selectedIcon: Icon(Icons.video_file_rounded),
                label: '视频转文件',
              ),
              NavigationDestination(
                icon: Icon(Icons.history_rounded),
                selectedIcon: Icon(Icons.history_edu_rounded),
                label: '传输历史',
              ),
            ],
          );
        },
      ),
    );
  }
}
