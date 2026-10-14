# File to Video Data Transfer System (文件视频化数据传输系统)

本项目包含两套完整的实验性原型系统，用于探索将**任意文件**转换为**视频**进行远距离存储、离线分发或无物理网络传输（Air-gap），并逆向无损还原。

---

## 🚀 两种技术方案实测同台竞技（50 KB 文件基准测试）

针对同一份 50 KB 真实数据，在相同环境下运行 `python3 pixel_demo.py` 的实测对比：

| 评估指标 | 方案一：动态二维码视频 (`QR Code`) | 方案二：纯像素块点阵视频 (`Pure Pixel Block - ISG`) | 性能倍数 |
| :--- | :--- | :--- | :--- |
| **视频文件体积** | 481 KB (膨胀 9.61 倍) | **61 KB (仅膨胀 1.23 倍)** | **体积缩小 87%** |
| **编码耗时** | 15.03 秒 | **0.75 秒** | **提速 20 倍** |
| **解码耗时** | 12.32 秒 | **0.49 秒** | **提速 25 倍** |
| **全流程总耗时** | 27.35 秒 | **1.24 秒** | **整体提速 22 倍** |
| **数据完整性校验** | **100% SHA-256 吻合** | **100% SHA-256 吻合** | 均为比特级无损 |

---

## 📂 核心代码清单

### 1. 纯像素块点阵方案（首选，速度极快，体积极小）
适合：**文件远距离视频传输、网盘/社交软件中转、无损视频归档**。
- [**`pixel_encoder.py`**](file:///root/projects/file-to-qrcode/pixel_encoder.py)：纯像素矩阵编码器。
- [**`pixel_decoder.py`**](file:///root/projects/file-to-qrcode/pixel_decoder.py)：纯像素矩阵解码器（基于 Numpy 毫秒级中心采样）。
- [**`pixel_demo.py`**](file:///root/projects/file-to-qrcode/pixel_demo.py)：双方案同台对比基准测试脚本。

### 2. 动态二维码方案（通用性强）
适合：**手机摄像头对着屏幕实时扫描识别**。
- [**`encoder.py`**](file:///root/projects/file-to-qrcode/encoder.py)：标准二维码视频生成器。
- [**`decoder.py`**](file:///root/projects/file-to-qrcode/decoder.py)：标准二维码视频解码器（基于 PyZBar / ML Kit 架构）。
- [**`demo.py`**](file:///root/projects/file-to-qrcode/demo.py)：二维码端到端自动化演示脚本。

---

## 🛠️ 使用指南

### 运行双方案基准对比
```bash
python3 pixel_demo.py
```

### 使用纯像素块模式转换你的文件
```bash
# 1. 编码任意文件为视频
python3 pixel_encoder.py <你的文件路径> -o my_pixel_video.mp4 --block-size 4 --fps 10 --crf 22

# 2. 从视频还原文件
python3 pixel_decoder.py my_pixel_video.mp4 -o ./restored_dir --block-size 4
```

### 使用二维码模式转换你的文件
```bash
# 1. 编码任意文件为二维码视频
python3 encoder.py <你的文件路径> -o my_qr_video.mp4 --fps 10 --chunk-size 500

# 2. 从二维码视频还原文件
python3 decoder.py my_qr_video.mp4 -o ./restored_dir
```
