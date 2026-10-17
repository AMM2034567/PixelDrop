import 'package:flutter/material.dart';
import '../widgets/dot_matrix_logo.dart';
import 'encode_screen.dart';
import 'decode_screen.dart';

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
                          '离线点阵视频文件传输 · v1.0.5',
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
                      'PixelDrop 将任意二进制文件按字节映射为彩色像素点阵生成 MP4 视频。接收方只需播放或导入视频即可逆向提取文件，无需数据线与局域网。',
                ),
                const SizedBox(height: 16),
                _buildInfoSection(
                  context,
                  title: '规格选择',
                  content:
                      '• 4x4 像素（高密）：单帧容量大，适合原画保存、网盘中转与邮件发送。\n• 8x8 像素（抗噪）：像素方块更大，耐受社交软件二次压缩。',
                ),
                const SizedBox(height: 16),
                _buildInfoSection(
                  context,
                  title: '数据完整性',
                  content:
                      '内置帧级 CRC32 容错校验与全量 SHA-256 哈希校验。还原完成后自动对比指纹，确保与源文件比特级完全一致。',
                ),
                const SizedBox(height: 16),
                _buildInfoSection(
                  context,
                  title: '存储位置',
                  content:
                      '• 视频生成目录: Download/PixelDrop/Videos\n• 文件还原目录: Download/PixelDrop/Restored',
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
            ],
          );
        },
      ),
    );
  }
}
