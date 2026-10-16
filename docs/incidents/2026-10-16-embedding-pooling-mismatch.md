# embedding 端点区分度崩塌：`pooling` 覆盖了模型自带声明 — 2026-10-16

## 现象

用 `qwen3-embed`（Qwen3-Embedding-0.6B）算句向量时，**整个语义谱系压缩成一条窄带**：

| 探针 | 余弦相似度 |
|---|---|
| 完全相同 | 1.0000 |
| 语义相近 | 0.9772 |
| 主题相关 | 0.9901 |
| **完全无关**（「时序数据库存储带时间戳的数据」对「午饭吃了西红柿炒蛋」） | **0.9758** |

无关文本 0.9758、相近文本 0.9772 —— **跨度只有 0.0242**（同一性是 1.0）。这个 embedding
无法区分无关与相关文本，任何基于它的 margin 都是噪声。

## 根因

服务由 systemd 用户单元启动：

```
~/.config/systemd/user/llama-server.service
  ExecStart=llama-server --models-preset %h/.config/llama.cpp/models.ini ...
```

模型 preset 里写了：

```ini
[qwen3-embed]
model = /home/ystyle/.cache/llama.cpp/Qwen3-Embedding-0.6B-Q8_0.gguf
alias = Qwen3-Embedding-0.6B
embedding = true
pooling = cls        ← 这一行
c = 8192
```

而该模型的 GGUF 元数据里**明文声明**：

```
qwen3.pooling_type = 3        # NONE=0, MEAN=1, CLS=2, LAST=3
```

`--pooling cls` **覆盖了模型作者指定的 LAST**——而那才是 Qwen3-Embedding 训练时用的池化。

> 排查顺序上的教训：一开始去 llama-swap 的配置文件里找，找不到；真正的来源是 systemd
> 单元 + `--models-preset`。**「配置文件在哪」要靠进程怎么启动来定位，不能靠猜文件名。**

## 修复

**删掉 `pooling = cls` 那一行**，而不是硬写 `pooling = last`：

```ini
[qwen3-embed]
model = /home/ystyle/.cache/llama.cpp/Qwen3-Embedding-0.6B-Q8_0.gguf
alias = Qwen3-Embedding-0.6B
embedding = true
# pooling 刻意不设：GGUF 声明的 qwen3.pooling_type = 3 (LAST) 才是该模型训练时的池化
c = 8192
```

理由：硬写 `last` 能解决当下，但**下次换模型会重新错配**；留空则跟随模型自身的声明。

改后需**重启服务**（preset 只在启动时读取，改文件不重启则旧参数仍生效）：

```shell
systemctl --user restart llama-server.service
```

## 效果

| 探针 | `pooling = cls` | 模型默认（LAST） |
|---|---|---|
| 完全相同 | 1.0000 | 1.0000 |
| 语义相近 | 0.9772 | **0.8065** |
| 主题相关 | 0.9901 | 0.6553 |
| 完全无关 | 0.9758 | **0.2572** |
| 中英对照 | — | 0.8825 |
| **跨度** | **0.0242** | **0.7428** |

**区分度恢复约 30 倍**，无关文本从 0.9758 降到 0.2572。

## 防复发

`bench/semantic_survival.py` 增加了**可分离性自检**：完全相同 ≫ 换述 ≫ 无关，
且跨度 > 0.3，才继续测量；否则以非零退出码**响亮失败**，并提示「端点的 pooling 可能与
模型不匹配，下面的 margin 什么都测不出」。

这样配置错误的端点不再静默产出看起来正常的相似度数字。

## 备份

改动前的 `models.ini` 留在 `bench/.work/models.ini.bak`（该目录被 gitignore）。
