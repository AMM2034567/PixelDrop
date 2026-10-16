# PixelDrop - 文件像素视频化存储与传输系统 (File-to-Video)

<p align="center">
  <img src="android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png" alt="PixelDrop Logo" width="128" height="128" />
  <br>
  <b>将任意文件编码为高密度纯像素点阵 MP4 视频，并 100% 比特级无损还原</b>
  <br>
  <i>Any File &rarr; Pixel Blocks MP4 &rarr; 100% Exact Restored File (Bit-exact SHA-256 Verified)</i>
</p>

<p align="center">
  <a href="https://github.com/AMM2034567/file-to-video/releases/tag/v1.0.4">
    <img src="https://img.shields.io/badge/Release-v1.0.4-blue.svg?style=flat-square" alt="Release v1.0.4" />
  </a>
  <a href="https://flutter.dev">
    <img src="https://img.shields.io/badge/Flutter-3.24.3-02569B?style=flat-square&logo=flutter" alt="Flutter" />
  </a>
  <a href="https://www.android.com">
    <img src="https://img.shields.io/badge/Platform-Android-3DDC84?style=flat-square&logo=android" alt="Android" />
  </a>
  <a href="docs/HANDOVER.md">
    <img src="https://img.shields.io/badge/Docs-Handover%20Guide-orange.svg?style=flat-square" alt="Handover Docs" />
  </a>
</p>

---

## 📖 简介 (Overview)

**PixelDrop** 是一款基于 Flutter 与 Android 原生前台保活服务的高性能离线数据视频化系统。它可以将电脑或手机上的**任意文件**（音乐、视频、文档、代码压缩包、安装包等）切片并编码为由微小黑白像素点阵组成的 1080P MP4 视频。

接收方只需通过 PixelDrop 导入该视频，系统即可在数秒内以原生 Raw 视频流灰度直读解码，并基于 CRC32 和 SHA-256 校验和**无损完整地恢复原文件**。

> 💡 **核心应用场景**：跨设备无网光学传输、网盘/社交平台格式白名单绕行、免连接线冷数据备份归档。

---

## ⚡ 核心特性 (Key Features)

* **💎 100% 比特级精确还原**：
  采用强隔离深拷贝多分块归集机制，无论是单帧小文件（如几 KB 抓包文件），还是中大型多帧文件（如十几兆的 MP3、视频、可执行文件），均通过 SHA-256 严密比对，无一比特差错。
* **🚀 毫秒级像素流直读解码**：
  放弃低效的逐帧图片解码器，采用底层 Raw 灰度管道直接输出，搭配 $O(1)$ 网格中心采样，数千帧超长视频仅需 2~3 秒即可解析完毕。
* **🛡️ 安卓原生前台保活 (Keep-Alive)**：
  内置 Android 原生前台服务 (`PixelDropService`)，持有系统级 `PowerManager.PARTIAL_WAKE_LOCK`。无论是退回手机桌面、刷其他软件还是锁屏黑屏，后台编码/还原进程均满速运转，绝不被系统杀后台。
* **📊 实时状态与通知栏联动**：
  任务进度毫秒级同步，通知栏常驻卡片显示实时百分比，支持点击通知直接唤回应用。
* **📁 自动归档与一键定位**：
  输出文件自动规范存储在手机公共目录：
  * 生成的视频：`Download/PixelDrop/Videos/`
  * 还原的文件：`Download/PixelDrop/Restored/`
  界面提供【定位视频目录】与【定位还原目录】按钮，一键调起系统文件管理器。
* **📋 SHA-256 校验码展示与一键复制**：
  编码完成即刻展示原始文件哈希值，方便随时比对与记录。

---

## 📊 基准测试：纯像素块 vs 动态二维码

对同一份 50 KB 真实数据进行基准测试对比：

| 评估指标 | 方案一：动态二维码视频 (`QR Code`) | 方案二：PixelDrop 纯像素块点阵 (`ISG`) | 性能倍数 |
| :--- | :--- | :--- | :--- |
| **视频文件体积** | 481 KB (膨胀 9.61 倍) | **61 KB (仅膨胀 1.23 倍)** | **体积缩小 87%** |
| **编码耗时** | 15.03 秒 | **0.75 秒** | **提速 20 倍** |
| **解码耗时** | 12.32 秒 | **0.49 秒** | **提速 25 倍** |
| **全流程总耗时** | 27.35 秒 | **1.24 秒** | **整体提速 22 倍** |
| **数据完整性校验** | **100% SHA-256 吻合** | **100% SHA-256 吻合** | 均为比特级无损 |

---

## 📥 最新版本下载 (Releases)

直接前往 GitHub Release 下载预编译好的 Android APK：

👉 **[PixelDrop v1.0.4 正式发布页面](https://github.com/AMM2034567/file-to-video/releases/tag/v1.0.4)**

* **[app-arm64-v8a-release.apk](https://github.com/AMM2034567/file-to-video/releases/download/v1.0.4/app-arm64-v8a-release.apk)**（~60 MB，**强烈推荐**，适配绝大多数现代 Android 手机）
* **[app-armeabi-v7a-release.apk](https://github.com/AMM2034567/file-to-video/releases/download/v1.0.4/app-armeabi-v7a-release.apk)**（适配老旧 32 位 Android 机型）

---

## 🛠️ 研发与构建指南 (For Developers)

> [!WARNING]
> **切勿在本地 Termux 环境中直接执行 `flutter build`！**
> 本项目所有 Android APK 构建与 Release 发布均通过 **GitHub Actions** 自动化完成。修改代码后推送到 GitHub，云端 Runner 会自动完成多架构打包与发布。

### 核心目录结构
* [`lib/models/pixel_packet.dart`](lib/models/pixel_packet.dart)：二进制协议规范（`PD01` 幻数、分块、CRC32）。
* [`lib/services/pixel_encoder.dart`](lib/services/pixel_encoder.dart)：编码器，文件切片与视频合成。
* [`lib/services/pixel_decoder.dart`](lib/services/pixel_decoder.dart)：解码器，Raw 灰度流中心点采样与文件重组。
* [`android/app/src/main/kotlin/com/antigravity/pixeldrop/PixelDropService.kt`](android/app/src/main/kotlin/com/antigravity/pixeldrop/PixelDropService.kt)：原生前台常驻与 WakeLock 保活服务。
* [`.github/workflows/build.yml`](.github/workflows/build.yml)：云端 CI/CD 构建配置。

---

## 📑 助手交接与历史对话记录

* 📘 **给下一位助手的交接全景文档**：[docs/HANDOVER.md](docs/HANDOVER.md)
* 📜 **完整历史对话纪要 (可直接阅读)**：[docs/chat_history/CONVERSATION_HISTORY.md](docs/chat_history/CONVERSATION_HISTORY.md)
* 💾 **原始 JSONL 对话记录与调试截图**：[docs/chat_history/](docs/chat_history/)
