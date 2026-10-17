import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixel_drop/main.dart';
import 'package:pixel_drop/widgets/dot_matrix_logo.dart';
import 'package:pixel_drop/screens/encode_screen.dart';
import 'package:pixel_drop/screens/decode_screen.dart';

void main() {
  testWidgets('PixelDropApp renders correctly with MD3 theme and navigation', (tester) async {
    await tester.pumpWidget(const PixelDropApp());
    await tester.pumpAndSettle();

    // Verify App Bar
    expect(find.text('PixelDrop'), findsOneWidget);
    expect(find.byType(DotMatrixLogo), findsOneWidget);
    expect(find.byIcon(Icons.info_outline_rounded), findsOneWidget);

    // Verify Navigation Bar items
    expect(find.text('文件转视频'), findsOneWidget);
    expect(find.text('视频转文件'), findsOneWidget);

    // Verify EncodeScreen initial state
    expect(find.byType(EncodeScreen), findsOneWidget);
    expect(find.text('选择待转换文件'), findsOneWidget);
    expect(find.text('编码规格'), findsOneWidget);
    expect(find.text('4x4 像素（高密）'), findsOneWidget);
    expect(find.text('8x8 像素（抗噪）'), findsOneWidget);
    expect(find.text('开始生成视频'), findsOneWidget);

    // Test SegmentedButton toggle in EncodeScreen
    await tester.tap(find.text('8x8 像素（抗噪）'));
    await tester.pumpAndSettle();
    expect(find.textContaining('8x8 模式：色块更大容错率高'), findsOneWidget);

    // Switch to DecodeScreen
    await tester.tap(find.text('视频转文件'));
    await tester.pumpAndSettle();

    // Verify DecodeScreen initial state
    expect(find.byType(DecodeScreen), findsOneWidget);
    expect(find.text('选择待还原视频'), findsOneWidget);
    expect(find.text('解析采样规格'), findsOneWidget);
    expect(find.text('4x4 采样（默认）'), findsOneWidget);
    expect(find.text('8x8 采样'), findsOneWidget);
    expect(find.text('开始还原文件'), findsOneWidget);

    // Test SegmentedButton toggle in DecodeScreen
    await tester.tap(find.text('8x8 采样'));
    await tester.pumpAndSettle();
    expect(find.textContaining('对应 8x8 抗噪模式制作的视频进行容错解码'), findsOneWidget);

    // Open Info Sheet
    await tester.tap(find.byIcon(Icons.info_outline_rounded));
    await tester.pumpAndSettle();

    // Verify Info Sheet Content
    expect(find.text('离线点阵视频文件传输 · v1.0.6'), findsOneWidget);
    expect(find.text('工作原理'), findsOneWidget);
    expect(find.text('规格选择'), findsOneWidget);
    expect(find.text('数据完整性'), findsOneWidget);
    expect(find.text('存储位置'), findsOneWidget);
    expect(find.text('我知道了'), findsOneWidget);

    // Dismiss Info Sheet
    await tester.tap(find.text('我知道了'));
    await tester.pumpAndSettle();
    expect(find.text('我知道了'), findsNothing);
  });

  testWidgets('DotMatrixLogo scales gracefully across different sizes', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              DotMatrixLogo(size: 16),
              DotMatrixLogo(size: 24),
              DotMatrixLogo(size: 48),
              DotMatrixLogo(size: 120),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(DotMatrixLogo), findsNWidgets(4));
  });

  testWidgets('Action buttons remain disabled when no file/video is chosen', (tester) async {
    await tester.pumpWidget(const PixelDropApp());
    await tester.pumpAndSettle();

    // In Encode screen, action button is disabled (onPressed is null)
    final encodeButtonFinder = find.widgetWithText(FilledButton, '开始生成视频');
    expect(encodeButtonFinder, findsOneWidget);
    final FilledButton encodeButton = tester.widget(encodeButtonFinder);
    expect(encodeButton.onPressed, isNull);

    // Switch to Decode screen
    await tester.tap(find.text('视频转文件'));
    await tester.pumpAndSettle();

    // In Decode screen, action button is disabled (onPressed is null)
    final decodeButtonFinder = find.widgetWithText(FilledButton, '开始还原文件');
    expect(decodeButtonFinder, findsOneWidget);
    final FilledButton decodeButton = tester.widget(decodeButtonFinder);
    expect(decodeButton.onPressed, isNull);
  });

  testWidgets('App renders without overflow on narrow 320dp screen and large font scaling', (tester) async {
    tester.view.physicalSize = const Size(320 * 2, 640 * 2);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const MediaQuery(
        data: MediaQueryData(
          textScaler: TextScaler.linear(1.4),
          size: Size(320, 640),
        ),
        child: PixelDropApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('PixelDrop'), findsOneWidget);
    expect(find.text('文件转视频'), findsOneWidget);
    expect(find.text('视频转文件'), findsOneWidget);

    // Switch to Decode screen
    await tester.tap(find.text('视频转文件'));
    await tester.pumpAndSettle();
    expect(find.text('选择待还原视频'), findsOneWidget);
  });

  testWidgets('DotMatrixLogo paints correctly in non-square aspect ratio', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 100,
              height: 40,
              child: DotMatrixLogo(size: 40),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(DotMatrixLogo), findsOneWidget);
  });

  testWidgets('PixelDropApp renders cleanly in dark theme mode', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(platformBrightness: Brightness.dark),
          child: PixelDropApp(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('PixelDrop'), findsOneWidget);
    expect(find.text('文件转视频'), findsOneWidget);
    expect(find.text('视频转文件'), findsOneWidget);
  });
}
