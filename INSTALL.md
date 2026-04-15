# FaceFusion 环境搭建说明

## 前置条件

- Anaconda 已安装
- NVIDIA 显卡 + CUDA 12.x 驱动

---

## 1. 创建 conda 环境

```bash
conda create -n facefusion python=3.11 -y
conda activate facefusion
```

---

## 2. 安装 Python 依赖

```bash
cd /path/to/facefusion
pip install -r requirements.txt
```

---

## 3. 安装 ffmpeg 和 curl

```bash
conda install -c conda-forge ffmpeg curl -y
```

> 必须安装在 conda 环境内，避免激活环境后系统 `/usr/bin/curl` 因 `libffi` 版本冲突崩溃。

---

## 4. 安装 GPU 支持（可选，推荐）

默认安装的 `onnxruntime` 为 CPU 版，替换为 GPU 版：

```bash
pip uninstall onnxruntime -y
pip install onnxruntime-gpu==1.24.3
```

---

## 5. 下载模型

```bash
python facefusion.py force-download
```

---

## 6. 验证环境

```bash
python -c "
import onnxruntime
print('Providers:', onnxruntime.get_available_providers())
"
# GPU 版应输出包含 CUDAExecutionProvider
```

---

## 7. 运行

```bash
# Web UI
python facefusion.py run

# 命令行无界面（GPU）
python facefusion.py headless-run \
  --execution-providers cpu \
  --source-paths source.jpg \
  --target-path target.jpg \
  --output-path output/output.jpg
```
