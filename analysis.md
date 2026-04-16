# FaceFusion 架构分析

## FaceFusion 架构概览

FaceFusion 是一个模块化的人脸替换/融合平台，支持图片和视频处理。

---

## 核心架构

### 1. 入口与命令路由

```
python facefusion.py [command]
```

| 命令 | 说明 |
|------|------|
| `run` | 启动 Gradio Web UI |
| `headless-run` | CLI 单次处理 |
| `batch-run` | 批量处理 |
| `job-*` | 任务队列管理 |

入口流程：`facefusion.py` → `core.cli()` → 路由到对应处理器

---

### 2. 处理流水线（核心）

**图片处理流程：**
```
源图片 → 人脸检测 → 关键点提取 → 人脸识别/嵌入
    ↓
目标图片 → 人脸检测 → 筛选目标人脸
    ↓
Processor 链式处理（face_swapper → face_enhancer → ...）
    ↓
输出图片
```

**视频处理流程：**
```
FFmpeg 提取帧 → 并行处理每帧（ThreadPoolExecutor）→ FFmpeg 合并帧 → 恢复音频
```

---

### 3. 人脸分析模块

| 模块 | 功能 |
|------|------|
| `face_detector.py` | ONNX 推理检测人脸（retinaface/yolo 等） |
| `face_landmarker.py` | 提取 5/68 点关键点 |
| `face_recognizer.py` | 计算人脸嵌入向量 |
| `face_classifier.py` | 分类年龄/性别/种族 |
| `face_masker.py` | 生成分割掩码 |
| `face_selector.py` | 按条件筛选目标人脸 |

---

### 4. 处理器插件系统（12个模块）

每个 Processor 位于 `facefusion/processors/modules/{name}/`，实现统一接口：

```python
process_frame(inputs) → (modified_frame, mask)
```

主要处理器：
- `face_swapper` — 人脸替换（核心）
- `face_enhancer` — 超分辨率/修复（CodeFormer/GFPGAN）
- `lip_syncer` — 唇形同步
- `age_modifier` — 年龄修改
- `frame_enhancer` — 全帧超分
- `live_portrait` — 人脸动画

处理器可**链式组合**，前一个的输出作为下一个的输入。

---

### 5. 关键架构模式

| 模式 | 说明 |
|------|------|
| **插件化处理器** | 处理器动态加载，互相独立，易于扩展 |
| **集中状态管理** | `state_manager.py` 统一管理所有配置（CLI/UI 双上下文） |
| **推理池（Inference Pool）** | ONNX 会话懒加载+复用，节省 GPU 显存 |
| **Job 队列** | 异步任务系统，状态持久化到 `.jobs/` JSON 文件 |
| **并行帧处理** | 视频帧用 ThreadPoolExecutor 并发处理 |

---

### 6. 技术依赖

- **ONNX Runtime** — 所有 AI 模型的推理引擎（支持 CUDA/DirectML/ROCm/CPU）
- **FFmpeg** — 视频帧提取与合并、音频处理
- **OpenCV** — 图像 I/O 和基础操作
- **Gradio** — Web UI 框架

---

## 总结

FaceFusion 的设计核心是**"处理器插件链 + 集中状态管理 + ONNX 推理池"**。用户选择处理器组合，系统自动串联执行，每帧图像依次经过人脸检测、特征提取、AI 变换、掩码融合，最终输出结果。视频则通过 FFmpeg 拆帧/合帧 + 多线程并行处理来保证效率。

---

## NSFW 内容检测（黄色内容过滤）

### 核心文件

**`facefusion/content_analyser.py`**

---

### 检测机制

采用**3个模型投票**，至少2个模型同时判定为NSFW才会触发：

| 模型 | 来源 | 阈值 |
|------|------|------|
| `nsfw_1` | EraX (Apache-2.0) | 0.2 |
| `nsfw_2` | Marqo (Apache-2.0) | 0.25 |
| `nsfw_3` | Freepik (MIT) | 10.5 |

---

### 关键函数

| 函数 | 作用 |
|------|------|
| `detect_nsfw()` | 主检测入口，投票判定 |
| `analyse_image()` | 检测图片 |
| `analyse_video()` | 检测视频（>10% 的帧为 NSFW 则触发） |
| `analyse_stream()` | 检测流（每秒采样一帧） |
| `analyse_frame()` | 检测单帧 |

---

### 触发后的行为

检测到 NSFW 内容时返回**错误码 3**，中止处理流程。集成在以下位置：

- `workflows/image_to_image.py` — 图片处理前检查
- `workflows/image_to_video.py` — 视频处理前检查
- `uis/components/preview.py` — 预览时实时检测
- `core.py` — 全局预检查
