# PixelDrop 项目交接与技术架构全景指南 (Next Agent Handover)

> **致下一位接手的 AI 助手 / 研发人员：**
> 本文档旨在为您提供关于 **PixelDrop** 项目从业务背景、技术架构、历史踩坑、核心代码规范到当前研发状态的完整全景视图，请在开展任何后续工作前仔细通读。

---

## 📌 一、 项目基本信息

* **项目名称**：PixelDrop (文件像素视频化传输与无损还原系统)
* **GitHub 私有仓库**：`https://github.com/AMM2034567/file-to-video`
* **主开发分支**：`main`
* **最新发布版本**：**`v1.0.5`** (Git Tag: `v1.0.5`, Commit: `60b57de`)
* **移动端包名**：`com.antigravity.pixeldrop`
* **技术选型**：Flutter 3.24.3 + Dart + 原生 Android Kotlin (Foreground Service) + FFmpeg (`ffmpeg_kit_flutter_full_gpl`) + Python 原型基准测试脚本。

---

## ⚠️ 二、 极其关键的研发铁律与运行约束（必读！）

> [!CAUTION]
> **严禁在本地 Termux / 本机开发环境直接运行 `flutter build`、`flutter test` 或任何 Android 编译命令！**
> 本机环境为轻量级终端/容器（Termux），CPU 与内存资源极度有限，在本地直接编译会导致终端 OOM、挂死或环境崩溃。

### 持续集成与发布规范（CI/CD）：
1. **所有编译、打包和 Release 发布必须全权托付给 GitHub Actions**。
2. 远程仓库已配置自动化工作流 [`.github/workflows/build.yml`](../.github/workflows/build.yml)。
3. 当且仅当在 GitHub Actions 云端 Ubuntu Runner 上，会自动完成：
   * 设置 Java 17 与 Flutter 3.24.3 环境；
   * 安装依赖并执行分架构独立打包：`flutter build apk --release --split-per-abi`；
   * 自动生成 GitHub Release 并上传 `app-arm64-v8a-release.apk` (推荐主力包，~60MB) 与 `app-armeabi-v7a-release.apk`；
4. 提交普通文档或聊天记录等非代码变更时，请在 commit message 中添加 `[skip ci]`，或依赖 `paths-ignore` 避免无意义的云端 Runner 消耗。

---

## 💡 三、 项目背景与解决的核心问题

用户希望实现：**将任意格式、任意大小的文件转换为 MP4 视频，视频画面为高密度像素矩阵点阵（类似 ISG - Infinite Storage Glitch 原理）。他人拿到该视频后，无需网络即可通过应用直接逐帧解析像素，原封不动地 100% 还原出原文件，SHA-256 比特级无差错。**

### 技术路径选型历程：
1. **动态二维码方案 (QR Code)**：虽然摄像头识别兼容性好，但元数据膨胀高达 9.6 倍，编码/解码耗时极长。
2. **纯像素点阵方案 (Pure Pixel Block - 本项目采用方案)**：
   * 膨胀率从 960% 断崖式下降到仅 **123%**；
   * 编码速度提速 **20 倍**，解码速度提速 **25 倍**；
   * 在 Python 基准测试和 Flutter 实机运行中，均达到 **100% SHA-256 位精确校验无损还原**。

---

## 📐 四、 核心协议规范 (Pixel Protocol Specification)

本协议完全自主设计，具备跨平台二进制通用性（任意语言均可解析）：

### 1. 画面与网格参数
* **分辨率**：标准 1080P (`1920 x 1080`)
* **点阵块大小 (Block Size)**：`8 x 8` 物理像素
* **点阵行列**：横向 $1920 / 8 = 240$ 列，纵向 $1080 / 8 = 135$ 行
* **单帧物理容量**：$240 \times 135 = 32,400$ bits = **4,050 字节**
* **黑白二值化阈值**：中心采样点灰度值 $\ge 128$ 为二进制 `1`（白块），$< 128$ 为二进制 `0`（黑块）。对压缩噪声具备极高抗干扰容限。

### 2. 帧数据包结构 (`PixelPacket`)

| 字节偏移 (Offset) | 字段名 (Field) | 类型 / 长度 | 说明 |
| :--- | :--- | :--- | :--- |
| `0x00 - 0x03` | `magic` | 4 字节 ASCII | 固定为 **`PD01`**（ASCII: `0x50, 0x44, 0x30, 0x31`） |
| `0x04` | `version` | 1 字节 uint8 | 协议版本，当前为 `0x01` |
| `0x05` | `flags` | 1 字节 uint8 | 标志位，默认 `0x00` |
| `0x06 - 0x07` | `reserved` | 2 字节 | 保留预留位，全 `0x00` |
| `0x08 - 0x0F` | `fileSize` | 8 字节 uint64 BE | 整个原始文件的实际总字节数 |
| `0x10 - 0x13` | `chunkIndex`| 4 字节 uint32 BE | 当前分块序号（从 0 开始计数） |
| `0x14 - 0x17` | `totalChunks`| 4 字节 uint32 BE | 该文件切分后的总分块数 |
| `0x18 - 0x1B` | `payloadLen` | 4 字节 uint32 BE | 本帧包含的有效载荷字节数 ($N$) |
| `0x1C - (0x1C+N-1)` | `payload` | $N$ 字节 | 分块载荷数据（详见下方分块定义） |
| 载荷末尾 4 字节 | `crc32` | 4 字节 uint32 BE | 从帧起始到载荷结束的完整 CRC32 校验和 |

### 3. 首块（Chunk 0）与后续块（Chunk 1..N-1）的组织
* **Chunk 0（元数据分块）**：
  * 首 4 字节：`metadata_len` (uint32 BE)
  * 接下来的字节：UTF-8 编码的 JSON 字符串（包含 `{"name": "文件名.ext", "sha256": "...", "size": 12345}`）
  * 剩余字节：原始文件的第 1 片数据。
* **Chunk 1..N-1（纯数据分块）**：
  * 纯粹填充原始文件的后续连续切片数据。

---

## 🏗️ 五、 项目代码架构与关键文件

```text
file-to-qrcode/
├── .github/workflows/
│   └── build.yml               # GitHub Actions 自动化编译打包与 Release 部署
├── android/
│   ├── app/src/main/
│   │   ├── AndroidManifest.xml # 注册前台服务权限、数据同步类型权限
│   │   └── kotlin/com/antigravity/pixeldrop/
│   │       ├── MainActivity.kt        # 建立 Flutter 与 Native 通信的 MethodChannel
│   │       └── PixelDropService.kt    # 原生前台服务 + PARTIAL_WAKE_LOCK 保活核心实现
│   └── build.gradle            # 配置 desugar_jdk_libs:2.0.4 (脱糖支持)
├── lib/
│   ├── main.dart               # 应用入口、主题样式、导航路由
│   ├── models/
│   │   └── pixel_packet.dart   # 帧协议序列化/反序列化、CRC32 校验、二进制打包
│   ├── screens/
│   │   ├── encode_screen.dart  # 制作视频界面（进度回调、前台服务联动、SHA-256展示与复制）
│   │   └── decode_screen.dart  # 还原文件界面（视频流解码、进度展示、一键定位目录）
│   └── services/
│       ├── foreground_service.dart # 前台服务 Dart 封装层 (start / update / stop)
│       ├── pixel_encoder.dart      # 编码核心：分块切片、位拼装、FFmpeg 无损管道直推
│       └── pixel_decoder.dart      # 解码核心：FFmpeg Raw 灰度管道、中心点采样、深拷贝重组
├── python_prototype/           # Python 双方案对比参考实现 (供算法推导与验证)
├── docs/
│   ├── HANDOVER.md             # 本交接文档
│   └── chat_history/           # 历史全量对话日志与媒体文件
└── pubspec.yaml                # 版本号配置 (当前为 1.0.4+4) 与依赖库声明
```

---

## 🛠️ 六、 历经攻坚的关键 Bug 与技术方案总结

接手者若需要修改解码或视频管道代码，请**务必注意以下已解决的坑点**：

### 1. 多分块大文件还原失败（88% 处报 `FormatException: Invalid UTF-8 byte`）
* **深层根因**：
  在 `pixel_decoder.dart` 中，提取单帧 raw 灰度流时使用了一个复用的字节数组 `packed`。而在 `pixel_packet.dart` 的 `PixelProtocol.parseFrame` 中，返回的 payload 使用了 `Uint8List.sublistView(frameRaw, ...)`（这只是一个内存视图，底层指针仍指向 `packed`）。
  当多帧依次流过时，先前已经存入分块列表的 `Chunk 0` 内存数据被最后一帧强行覆盖，导致首分块内的 UTF-8 文件名元数据 JSON 损坏，解码器在解析 JSON 时抛出 `FormatException`。
* **彻底根治方案**：
  在 `PixelProtocol.parseFrame` 与分块收集点强制执行内存深拷贝：`payload: Uint8List.fromList(payload)`。
  **修改后，无论是单帧还是数百帧、数千帧（如 10MB+ MP3、视频），均 100% SHA-256 无损精确还原！**

### 2. 切后台或锁屏被 Android 系统杀后台 / 冻结
* **深层根因**：
  单纯依靠 Flutter 插件的屏幕常亮（`FLAG_KEEP_SCREEN_ON`）仅在前台有效。一旦用户返回桌面或锁屏，Android 系统的 Doze 模式与 LMK 机制会直接挂起进程或杀死后台线程。
* **彻底根治方案**：
  在 Android 原生层实现了 [`PixelDropService.kt`](../android/app/src/main/kotlin/com/antigravity/pixeldrop/PixelDropService.kt)，持有系统级 `PowerManager.PARTIAL_WAKE_LOCK` 并调用 `startForeground` 挂载常驻通知栏。锁屏或切换应用时 CPU 始终全速运行，任务结束后在 `finally` 块中立即释放锁并安全停用服务。

### 3. 解码性能瓶颈
* **深层根因**：
  若使用传统图片解码库（逐帧解码 PNG/JPG 再通过 `getPixel` 读色），数千帧视频需要几十分钟。
* **彻底根治方案**：
  让 FFmpeg 直接输出原始未压缩灰度流：`-f rawvideo -pix_fmt gray pipe:1`。Dart 端按字节直接以 $O(1)$ 偏移量索引网格中心像素，数千帧在 2~3 秒内即可全部解析完毕。

### 4. 导出文件路径与系统权限
* 默认自动归档至手机系统公共下载区：
  * 编码导出的视频：`/storage/emulated/0/Download/PixelDrop/Videos/`
  * 还原提取的文件：`/storage/emulated/0/Download/PixelDrop/Restored/`
* 应用内置了【定位保存目录】按钮，调用系统文件管理器直接高亮展示生成的文件。

---

## 🚀 七、 当前进度与下一步工作规划

### 1. 刚刚聊到哪里？
* 用户测试了 **`v1.0.4`** 安装包，并在实机上验证了中大型多帧文件还原成功、后台保活正常，随后探讨了跨平台可行性。
* 换入 Windows 工作区后，用户要求**全面重构手机端 UI 消除“AI味”、严格 1:1 复刻左上角点阵图案为应用图标，并完成新版编译**。
* **`v1.0.5` 重大成果**：
  1. **1:1 严格复刻 24 像素同心矩阵点阵图标**：按用户上传图片几何特征生成全套 `ic_launcher`、`ic_launcher_round`、通知栏专用的纯白透底 `@drawable/ic_notification.png`（根治 Android 8+ 状态栏实心白块隐患）以及矢量组件 `DotMatrixLogo`；
  2. **深度消除“AI味”**：摒弃泛滥的高饱和紫粉渐变，改用克制优雅的 Slate Charcoal（深板岩灰蓝）MD3 质感主题；文案全面工程规范化；
  3. **交互体验打磨**：支持文件卡片【清除选择】（`✕`）、移除 `SegmentedButton` 冗余打勾图标、解决 320dp 窄屏与大字体无障碍缩放下的布局溢出问题；
* **Windows 桌面端原生落地重大成果**：
  1. **支持 Windows 原生编译运行**：生成完整 CMake / Win32 工程配置，支持 125%/150%/200% High-DPI 自适应缩放与最小窗口保护；
  2. **文件拖拽（Drag & Drop）**：支持直接从资源管理器拖入文件/视频快速编解码，内置文件夹类型拦截与安全提示；
  3. **响应式宽屏布局**：桌面端自动启用 `NavigationRail` 侧边导航与优雅居中卡片；
  4. **原生 Explorer 联动**：支持一键在资源管理器中定位高亮生成文件，支持路径一键复制；
  5. **极速编解码**：打包内置 Windows 原生高性能 FFmpeg 动态库，端到端测试 100% SHA-256 位无损通过；本地 Release 包位于 `build/windows/x64/runner/Release/pixel_drop.exe`。

### 2. 建议下一位助手可继续探索的方向：
1. **多平台与多端形态扩展**：
   * 开发配套的单文件 `pixeldrop-cli` 极简命令行工具（Rust 或 Python 编写），方便在 PC 终端、NAS 或无图形界面的 Linux 服务器中一键调用；
   * 纯前端 Web 网页端（WebAssembly + WebCodecs）免安装拖拽还原；
2. **安全加密传输（AES-256-GCM）**：
   * 编码转视频前支持设置密码加密，还原时输入密码，防止敏感文件在公共平台被他人随意提取；
3. **多位色彩密度升级（3-bit RGB 8 色）**：
   * 在保持抗噪容错的前提下，探索单帧容量翻 3~4 倍（视频时长直接缩短 70%）；
4. **前向纠错码（FEC / 喷泉码）**：
   * 引入 RaptorQ / Luby Transform，应对恶劣社交软件二压或丢帧。

---

## 📚 八、 历史对话与追溯资料索引

* **人类可读完整对话纪要**：[docs/chat_history/CONVERSATION_HISTORY.md](./chat_history/CONVERSATION_HISTORY.md)
* **原始紧凑 JSONL 对话日志**：[docs/chat_history/transcript.jsonl](./chat_history/transcript.jsonl)
* **原始完整 JSONL 对话日志**：[docs/chat_history/transcript_full.jsonl](./chat_history/transcript_full.jsonl)
* **用户在对话过程中上传的报错日志与界面截图**：[docs/chat_history/media/](./chat_history/media/)
