# Contributing to PixelDrop

感谢你关注并参与 **PixelDrop** 的开发与建设！

PixelDrop 致力于为全平台用户提供最可靠、抗压缩、高性能的文件 ⇄ 像素视频互转与光学传输体验。

---

## 🛠️ 本地开发准备

### 环境要求
- **Flutter SDK**：`>= 3.24.0` (推荐当前最新 stable 通道)
- **Dart SDK**：`>= 3.5.0`
- **FFmpeg**：本地系统安装有支持 x264 编码的 FFmpeg 工具链

### 快速拉取与依赖安装
```bash
git clone https://github.com/AMM2034567/PixelDrop.git
cd PixelDrop
flutter pub get
```

---

## 🧪 自动化测试与代码规范

在提交 Pull Request 之前，请务必保证项目本地静态分析与全部测试通过：

```bash
# 1. 运行静态代码分析（必须 0 告警 0 错误）
flutter analyze

# 2. 运行完整单元测试与集成测试套件
flutter test
```

---

## 📐 提交规范 (Git Commit)

推荐遵循 [Conventional Commits](https://www.conventionalcommits.org/) 规范撰写提交信息：
* `feat:` 全新特性
* `fix:` 缺陷修复
* `perf:` 性能与算法优化
* `docs:` 文档与说明变更
* `test:` 补充或重构自动化测试
* `ci:` CI/CD 流水线与构建脚本调整

---

## 💡 核心原则与设计约束

1. **项目本位**：PixelDrop 定位于高可靠的光学像素视频文件编解码与抗噪容错引擎。**本项目不是、也绝不做文件加密工具**（用户可自行在上游使用 7z/ZIP 加密后交由 PixelDrop 封包）。
2. **比特级精确无损**：任何合法的还原流程必须通过 SHA-256 全量一致性比对。
3. **保持跨平台整洁性**：移动端与桌面端保持 Material 3 自适应规范，避免平台特定硬编码。
