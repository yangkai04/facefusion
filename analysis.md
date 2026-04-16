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

---

## 人脸从识别到替换的完整处理链路

### 完整数据流概览

```
原始图像
  │
  ├─ [源人脸] 提取 embedding
  └─ [目标图像] 检测 → 筛选 → 替换 → 贴回
```

---

### 第一阶段：人脸检测

**`face_detector.py` → `detect_faces()`**

1. 将图像 resize + padding 到模型输入尺寸（如 640×640）
2. 归一化像素值（RetinaFace 归一到 `[-1,1]`，YOLO 归一到 `[0,1]`）
3. ONNX 推理，输出 3 个 feature map（scores、boxes、landmarks）
4. 基于锚点（anchor）解码为真实坐标
5. NMS 去除重叠框

**输出**：`BoundingBox [x1,y1,x2,y2]` + `Score` + `FaceLandmark5`（5个关键点）

---

### 第二阶段：关键点精化

**`face_landmarker.py` → `detect_face_landmark()`**

- 从 5 点估计 68 点（`estimate_face_landmark_68_5()`）
- 或用 2DFan4 模型精确提取 68 点
- 68 点覆盖：眼睛(12点)、眉毛(10点)、鼻子(9点)、嘴唇(20点)、轮廓(17点)

**输出**：`FaceLandmark68`

---

### 第三阶段：人脸识别（提取 Embedding）

**`face_recognizer.py` → `calculate_face_embedding()`**

1. 用 5 个关键点计算仿射变换矩阵（`cv2.estimateAffinePartial2D`）
2. `cv2.warpAffine` 将人脸对齐到 112×112 标准位置（ArcFace 模板）
3. ArcFace 模型推理 → 512 维特征向量
4. L2 归一化 → `embedding_norm`

**输出**：`embedding (512,)` + `embedding_norm (512,)`

---

### 第四阶段：人脸分类

**`face_classifier.py` → `classify_face()`**

- FairFace 模型，输入 224×224
- 输出：性别 / 年龄段 / 种族

---

### 第五阶段：人脸筛选与匹配

**`face_selector.py` → `select_faces()`**

| 模式 | 说明 |
|------|------|
| `many` | 替换所有检测到的人脸 |
| `one` | 只替换最大的人脸 |
| `reference` | 余弦距离 `1 - dot(norm_emb1, norm_emb2)` 匹配最相似的人脸 |

---

### 第六阶段：人脸对齐提取（Warp）

**`face_helper.py` → `warp_face_by_face_landmark_5()`**

用目标人脸的 5 个关键点计算仿射矩阵，将人脸 warp 到模型标准空间（如 256×256）：

```
原图中的歪脸 → 正面对齐的 crop_frame (256×256)
```

---

### 第七阶段：掩码生成

**`face_masker.py`**，多种掩码取最小值合并：

| 掩码类型 | 方法 | 作用 |
|---------|------|------|
| `box` | 高斯模糊矩形框 | 基础边界 |
| `occlusion` | xseg 模型（3个投票） | 检测遮挡区域（眼镜、手等） |
| `area` | 68点凸包 + fillConvexPoly | 精确人脸轮廓 |
| `region` | BiSeNet 语义分割 | 按区域（皮肤/眉毛/眼睛等）精细控制 |

---

### 第八阶段：人脸替换（核心）

**`face_swapper/core.py` → `forward_swap_face()`**

```python
# 输入 1：source embedding 转换
source_emb = prepare_source_embedding(source_face)
source_emb = balance_source_embedding(source_emb, target_emb, weight)
# weight 参数控制融合比例：0=完全替换，1=保留目标特征

# 输入 2：对齐后的 target crop_frame (1, 3, 256, 256)
crop_frame = prepare_crop_frame(crop_vision_frame)

# ONNX 推理
swapped_frame = model.run(['output'], {'source': emb, 'target': crop_frame})

# 后处理：反归一化
swapped_frame = normalize_crop_frame(swapped_frame)
```

支持的模型：inswapper_128、hyperswap_256、ghost_256、simswap_256、hififace_256 等，各自有不同的 embedding 转换方式。

**Pixel Boost**：可选 2x/4x 超分处理，将 crop 分块处理后重组，提升细节。

---

### 第九阶段：贴回原图（Paste Back）

**`face_helper.py` → `paste_back()`**

1. 计算仿射矩阵的**逆变换**（`cv2.invertAffineTransform`）
2. 将 swapped crop_frame 和 crop_mask 逆变换回原图坐标
3. Alpha 混合融合：

```python
output[y1:y2, x1:x2] = original * (1 - mask) + swapped * mask
```

---

### 完整链路图

```
原始图像
  │
  ├─ detect_faces()             → BoundingBox + 5点关键点
  ├─ detect_face_landmark()     → 68点关键点
  ├─ calculate_face_embedding() → 512维 embedding
  ├─ classify_face()            → 性别/年龄/种族
  ├─ select_faces()             → 筛选目标人脸（余弦距离匹配）
  │
  └─ swap_face() [循环每张目标人脸]
       │
       ├─ warp_face_by_landmark5() → 对齐到 256×256
       ├─ create_*_mask()          → 多类型掩码合并
       ├─ forward_swap_face()      → ONNX 推理替换
       └─ paste_back()             → 逆仿射变换 + Alpha 混合
            │
            └─ 输出图像
```

**核心数学操作**：仿射变换（对齐/贴回）+ 余弦相似度（人脸匹配）+ Alpha 混合（融合）+ L2 归一化（embedding 计算）。
