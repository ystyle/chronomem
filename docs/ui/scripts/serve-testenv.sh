#!/bin/bash
# 本地隔离测试实例：独立数据目录 + 独立端口（18901），**绝不**读写生产 8900 / ~/docker/chronomem。
#
# 用法（在 chronomem 仓根目录执行）：
#   ./docs/ui/scripts/serve-testenv.sh              # 绑 127.0.0.1，仅本机可访问
#   CHRONOLOG_ADDR=0.0.0.0 ./docs/ui/scripts/serve-testenv.sh   # 绑所有网卡，局域网可访问
#
# 灌测试数据（另开一个终端）：
#   python3 docs/ui/scripts/seed_testdata.py        # 默认打到 127.0.0.1:18901
#
# 需要 LLM 凭据（语义总结/自动摘要）时，从 .bench-ctr/.env 读；
# 没有该文件也能跑（只是总结功能不可用，其余 UI 全部可验证）。
set -u

REPO_ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
cd "$REPO_ROOT"

# LLM 凭据：优先 .bench-ctr/.env（已 gitignore），缺失不影响非 LLM 功能
BENCH_ENV="$REPO_ROOT/.bench-ctr/.env"
if [ -f "$BENCH_ENV" ]; then
  set -a; . "$BENCH_ENV"; set +a
fi

DATA_DIR=${CHRONOLOG_TEST_DIR:-$REPO_ROOT/.testdata-ui}
mkdir -p "$DATA_DIR"

export CHRONOLOG_DIR="$DATA_DIR"
export CHRONOLOG_ADDR=${CHRONOLOG_ADDR:-127.0.0.1}
export CHRONOLOG_PORT=${CHRONOLOG_TEST_PORT:-18901}
export CHRONOLOG_TIMEZONE=${CHRONOLOG_TIMEZONE:-Asia/Shanghai}
export CHRONOLOG_SEED_WORKLOG=true

BIN="$REPO_ROOT/target/release/bin/chronomem.cli"
if [ ! -x "$BIN" ]; then
  echo "未找到 $BIN，请先构建：eval \"\$(cjvs env bash)\" && cjpm build -j 16" >&2
  exit 1
fi

echo "忆时塔测试实例（隔离）"
echo "  监听   http://${CHRONOLOG_ADDR}:${CHRONOLOG_PORT}"
echo "  数据   ${CHRONOLOG_DIR}"
echo "  生产   http://127.0.0.1:8900 （本脚本不会触碰）"
exec "$BIN" serve
