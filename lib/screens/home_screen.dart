import 'package:flutter/material.dart';
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

  void _showInfoDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.auto_awesome, color: Colors.indigo),
            SizedBox(width: 8),
            Text('关于 PixelDrop'),
          ],
        ),
        content: const SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'PixelDrop 是一款基于【纯像素块点阵编码（ISG架构）】的文件视频互转工具。',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              SizedBox(height: 10),
              Text('• 100% 满屏数据装载，比传统二维码容量大 15 倍。'),
              Text('• 视频体积仅为原文件的 1.2x，远超二维码视频。'),
              Text('• 内置自适应 Gzip 压缩与帧级 CRC32 容错。'),
              Text('• 还原全过程经过 SHA-256 全局哈希密码学校验，保证比特级无损。'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('我知道了'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.blur_on, size: 28),
            SizedBox(width: 8),
            Text('PixelDrop', style: TextStyle(fontWeight: FontWeight.bold)),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.info_outline),
            tooltip: '原理说明',
            onPressed: _showInfoDialog,
          ),
        ],
      ),
      body: IndexedStack(
        index: _currentIndex,
        children: _screens,
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (idx) => setState(() => _currentIndex = idx),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.video_call_outlined),
            selectedIcon: Icon(Icons.video_call),
            label: '制作传输视频',
          ),
          NavigationDestination(
            icon: Icon(Icons.restore_page_outlined),
            selectedIcon: Icon(Icons.restore_page),
            label: '还原视频文件',
          ),
        ],
      ),
    );
  }
}
