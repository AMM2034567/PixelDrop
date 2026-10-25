# PixelDrop - 跨平台文件像素视频化存储与光学容错传输系统

<p align="center">
  <img src="android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png" alt="PixelDrop Logo" width="128" height="128" />
  <br>
  <b>将任意文件编码为高密度纯像素点阵 MP4 视频，并 100% 比特级无损还原</b>
  <br>
  <i>Convert any file into high-density MP4 pixel videos and restore it with 100% bit-exact SHA-256 integrity.</i>
</p>

<p align="center">
  <a href="https://github.com/AMM2034567/PixelDrop/releases/latest">
    <img src="https://img.shields.io/badge/Release-v0.6.0--beta-blue.svg?style=flat-square" alt="Latest Release" />
  </a>
  <a href="https://github.com/AMM2034567/PixelDrop/actions/workflows/build.yml">
    <img src="https://img.shields.io/github/actions/workflow/status/AMM2034567/PixelDrop/build.yml?branch=main&style=flat-square&label=CI%20Build" alt="CI Status" />
  </a>
  <a href="LICENSE">
    <img src="https://img.shields.io/badge/License-MIT-green.svg?style=flat-square" alt="MIT License" />
  </a>
  <a href="https://flutter.dev">
    <img src="https://img.shields.io/badge/Flutter-%3E%3D3.24.0-02569B?style=flat-square&logo=flutter" alt="Flutter" />
  </a>
  <a href="#-客户端下载-releases">
    <img src="https://img.shields.io/badge/Platforms-Windows%20%7C%20Android%20%7C%20Linux-orange.svg?style=flat-square" alt="Platforms" />
  </a>
</p>

---

## 📖 项目简介 (Overview)

**PixelDrop** 是一款基于 Flutter 与现代流式音视频引擎构建的高性能跨平台数据视频化传输工具。它可以将电脑或手机上的**任意文件、多个文件或整个文件夹**切片并编码为由微小离散像素矩阵组成的 1080P/720P MP4 视频。

接收方只需使用 PixelDrop 载入该视频，系统即可在数秒内通过原生像素管道快速提取，并通过内置的 **Cauchy Reed-Solomon 纠删码** 与 **SHA-256 比特级校验**，100% 原样无损恢复原始数据。

> 💡 **核心价值场景**：
> * **离线光学跨屏互传**：无需数据线、无需配对局域网、跨系统物理隔离安全传递；
> * **云盘与图床格式绕行**：将任意二进制数据包装为标准合法合规的 MP4 流媒体格式；
> * **社交平台免压传输**：通过帧级冗余与静音轨注入，抵抗平台的二转重压缩与偶发丢帧。

---

## ✨ 核心特性 (Key Features)

### 💎 1. 比特级无损与 SHA-256 完整性
* 每一帧数据均携带独立的 Magic 协议头、分块索引、总帧数及 **CRC32** 校验；
* 全局元数据记录原始文件 SHA-256 指纹与体积，还原完成后进行全文哈希比对，确保无一比特损坏。

### 🎨 2. RGB 8 色高密编码与黑白双协议
* **RGB 8 色协议 (`PD02`)**：单像素点携带 3 个比特数据（8 种离散基色），相比传统黑白单色点阵，视频体积大幅减小 **~60%**，生成速度翻倍；
* **经典黑白协议 (`PXL1`)**：1 比特/像素，极端翻拍环境下的高稳健性回退支持。

### 🛡️ 3. 抗掉帧容灾（时间冗余 / 帧级 FEC 纠删码）
* 采用基于伽罗瓦域 $GF(2^8)$ 的 **Cauchy Reed-Solomon 纠删码算法**；
* 支持可配置的帧级冗余度（10% ~ 30%）；
* 视频即使被播放器截断首尾，或在网络传输中被平台随机丢弃关键帧，**只要有效帧数达标，即可 100% 逆向重构缺失画面并精确还原**。

### 📁 4. 多文件拖拽与文件夹一键归档
* **流式打包**：直接将多个散落文件或多层嵌套文件夹拖入应用窗口，后台基于微任务自动切片压缩为 ZIP 视频流，界面毫无卡顿；
* **智能解压**：还原后支持一键解压，自动识别并去除冗余多层同名父目录；
* **安全防护**：内置严格的 **Zip-Slip 目录穿越防御**，杜绝恶意相对路径注入攻击。

### 📱 5. 移动端系统级极速交互 (Android)
* 深度集成 Android 原生 **`ACTION_SEND` / `ACTION_SEND_MULTIPLE`**：在手机文件管理器或相册中长按文件/视频，点击「分享到 PixelDrop」即可直接唤起并自动装配任务；
* 原生前台服务（Foreground Service）配合 **`PARTIAL_WAKE_LOCK`**，切后台、刷其他软件或锁屏息屏状态下 CPU 满速稳定运行，拒绝系统杀进程。

### 🪟 6. 精致桌面端体验 (Windows / Linux)
* 遵循 Material Design 3 现代深板岩灰蓝质感与黄金比例紧凑窗口（860 × 620）；
* 全局支持系统资源管理器直接**拖拽放置（Drag & Drop）**；
* 完成后提供一键【在资源管理器中显示】并自动高亮选中目标文件。

### 🌐 7. 社交与短视频平台免压兼容
* **轻量静音音轨注入**：针对微信视频号、抖音、B站等对纯无声 MP4 的上传拦截或暴力重采样问题，自动注入一条 32kbps AAC 无损静音流（1分钟视频仅增约 3~4 KB）；
* **Web 快速启动 (`+faststart`)**：自动将 `moov atom` 元数据挪至 MP4 最前部，支持网盘与网页端秒开预览与流式秒读。

---

## 🏗️ 架构与数据流 (Architecture)

```mermaid
flowchart LR
    subgraph 编码流水线 (Encode Pipeline)
        A["输入：文件 / 文件夹 / 多文件"] --> B["扫描归集 & 流式 ZIP 封包"]
        B --> C["注入元数据头 (文件名、SHA256、GZip)"]
        C --> D["Cauchy RS FEC 冗余编码 (时间纠删码)"]
        D --> E["多核 Isolate 并行渲染点阵帧 (PNG)"]
        E --> F["FFmpeg 合成 (RGB24 ➔ YUV420p + AAC 静音轨 + faststart)"]
        F --> G["输出：PixelDrop MP4 视频"]
    end

    subgraph 解码流水线 (Decode Pipeline)
        G --> H["载入 MP4 视频"]
        H --> I["FFmpeg Raw 视频流灰度直读 (跳过音频轨)"]
        I --> J["网格自适应采样 & CRC32 快速过滤"]
        J --> K{"是否发生掉帧?"}
        K -- "是" --> L["FEC 高斯-若尔当消元重建缺失帧"]
        K -- "否" --> M["拼装完整二进制载荷"]
        L --> M
        M --> N["SHA-256 完整性比对"]
        N --> O["智能解压 / 原文件保存"]
    end
```

---

## 📊 性能基准测试对比 (Benchmark)

对同一份标准 50 KB 真实数据进行多方案基准测试对比：

| 评估指标 | 方案一：动态二维码视频 (`QR Code`) | 方案二：PixelDrop 单色点阵 (`PXL1`) | 方案三：PixelDrop 彩色点阵 (`PD02`) | 提升效果 |
| :--- | :--- | :--- | :--- | :--- |
| **视频文件体积** | 481 KB (膨胀 9.61 倍) | 61 KB (膨胀 1.22 倍) | **仅 38 KB (膨胀 0.76 倍)** | **体积缩小 92%** |
| **编码压制耗时** | 15.03 秒 | 0.75 秒 | **0.42 秒** | **提速 35 倍** |
| **解码提取耗时** | 12.32 秒 | 0.49 秒 | **0.28 秒** | **提速 44 倍** |
| **全流程总耗时** | 27.35 秒 | 1.24 秒 | **0.70 秒** | **整体提速近 40 倍** |
| **数据校验** | 比特级无损 | 100% SHA-256 吻合 | **100% SHA-256 吻合** | 比特级无损 |

---

## 📥 客户端下载 (Releases)

欢迎前往 GitHub Releases 获取官方预编译安装包：

👉 **[前往 PixelDrop 最新版本下载页面](https://github.com/AMM2034567/PixelDrop/releases/latest)**

| 平台 / 系统 | 推荐下载文件 | 说明 |
| :--- | :--- | :--- |
| 🪟 **Windows (64位)** | **`PixelDrop-Windows-x64-v0.6.0-beta.zip`** | 绿色免安装版，内置极速 FFmpeg 视频引擎，解压即可运行 |
| 🤖 **Android (主流机型)** | **`app-arm64-v8a-release.apk`** | 适用于近几年发布的绝大多数 Android 智能手机 |
| 🤖 **Android (老旧机型)** | **`app-armeabi-v7a-release.apk`** | 适用于 32 位老旧 Android 移动设备 |
| 🐧 **Linux** | *规划待动工 (免安装 tar.gz 便携包)* | 详见 [docs/LINUX_TODO.md](docs/LINUX_TODO.md) |

---

## 🛠️ 源码构建与开发指南 (Developers)

### 环境要求
* [Flutter SDK](https://flutter.dev/docs/get-started/install) `>= 3.24.0`
* [Dart SDK](https://dart.dev/get-dart) `>= 3.5.0`
* 系统安装有支持 `libx264` 编码的 [FFmpeg](https://ffmpeg.org/)（Windows 免安装包已自带）

### 本地编译运行
```bash
# 1. 克隆代码库
git clone https://github.com/AMM2034567/PixelDrop.git
cd PixelDrop

# 2. 安装 Flutter 依赖包
flutter pub get

# 3. 运行静态代码分析（确保 0 告警）
flutter analyze

# 4. 执行全量单元测试与集成测试套件（86 项测试全部通过）
flutter test

# 5. 本地运行调试
flutter run -d windows    # Windows 桌面端
flutter run -d <device>   # Android 真机或模拟器
```

---

## 🤝 参与贡献 (Contributing)

欢迎任何形式的贡献！无论是发现 Bug、提出功能建议还是提交代码 PR：
1. 请阅读并遵循 [CONTRIBUTING.md](CONTRIBUTING.md)；
2. 欢迎通过 [GitHub Issues](https://github.com/AMM2034567/PixelDrop/issues) 提交反馈与讨论。

---

## 📜 开源许可证 (License)

本项目遵循 [MIT License](LICENSE) 开源协议。
任何人均可自由使用、复制、修改、合并、出版发行、散布、再授权及贩售软件及其副本。
