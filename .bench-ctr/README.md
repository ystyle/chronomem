# bench 独立实例

漂移研究用的**隔离**实例：与生产同一 Dockerfile 构建，但容器名、端口、数据卷
全部独立，**绝不读写** `~/docker/chronomem/data`。

| 项 | 生产 | 本实例 |
|---|---|---|
| 容器名 | `chronomem` | `chronomem-bench` |
| 端口 | 8900 | **18900** |
| 数据卷 | `~/docker/chronomem/data` | `.bench-ctr/data` |
| 镜像 | `chronomem:latest` | `chronomem:bench` |
| 默认 worklog 播种 | 开 | 关（`CHRONOLOG_SEED_WORKLOG=false`） |

## 启动

```bash
cp ~/docker/chronomem/.env .bench-ctr/.env     # LLM 凭据（漂移研究需要真实总结）
chmod 600 .bench-ctr/.env
cd .bench-ctr && docker compose up -d --build
```

`.env` 与 `data/` 均在 `.gitignore` 中——**不要提交**（含真实 API key）。

## 用途

```bash
cd ../bench
python3 gen_drift.py --hours 36 --seed 5 --out .work/d36.json
python3 drift_eval.py --trace .work/d36.json \
  --url http://127.0.0.1:18900/mcp --json-out .work/d36-result.json
```

实验会在实例内建 `bench/drift` 类型（`levels: 1h→day→week`），跑完自行
truncate + type_delete。**不要**把它指向生产端口 8900。

## 注意

- trace 短于 1 周时 **week 窗口不会闭合**，week 层会报 `missing` 而非 0 分——
  这是数据缺失，不是漂移，别当成结论。
- `.work/` 下的中间产物已忽略，可再生。
