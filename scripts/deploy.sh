#!/usr/bin/env bash
# 忆时塔部署：本地编译 → 校验二进制版本 → 重建镜像 → 重启容器 → 校验镜像内二进制与本地一致。
#
# 为什么要有这个脚本（2026-11-13 实测踩过）：
#   `cjpm test` 全绿 **不代表** `target/release/bin/chronomem.cli` 是新编的——
#   测试编的是测试二进制，release 可执行文件只有 `cjpm build` 才刷新。
#   于是"改了版本号 → 测试绿 → docker compose build"会产出一个**旧二进制**的镜像，
#   而 compose 因为 tag 没变（永远是 :latest）也不会重建容器，
#   最后的现象是"部署完了，版本号还是上一版"，且每一步都不报错。
#
# 所以这里把两件事变成硬校验：
#   ① 部署前：本地二进制的启动版本 == cjpm.toml 的 version（不一致就是没 build）；
#   ② 部署后：容器内二进制 sha256 == 本地二进制 sha256（不一致就是镜像/容器没换）。
# 任一条不符即退出非零，不继续往下走。
set -euo pipefail

cd "$(dirname "$0")/.."
REPO="$(pwd)"
COMPOSE_DIR="${COMPOSE_DIR:-$HOME/docker/chronomem}"
CONTAINER="${CONTAINER:-chronomem}"
BIN="target/release/bin/chronomem.cli"

die() { printf '\033[31m[部署拦截]\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[36m[部署]\033[0m %s\n' "$*"; }

manifest_version() {
    grep -m1 '^version' cjpm.toml | sed 's/.*"\(.*\)".*/\1/'
}

# 跑一下二进制读它启动时打印的版本行。用独立端口 + 临时数据目录，
# 不碰生产数据（AGENTS.md：~/docker 下的数据测试一律不能用）。
binary_version() {
    local dir port out
    dir="$(mktemp -d)"
    port="${PROBE_PORT:-8963}"
    out="$(CHRONOLOG_DIR="$dir" CHRONOLOG_PORT="$port" CHRONOLOG_ADDR=127.0.0.1 \
        timeout 8 ./"$BIN" serve 2>&1 || true)"
    rm -rf "$dir"
    printf '%s\n' "$out" | sed -n 's/^chronomem \([0-9][0-9.]*\)$/\1/p' | head -1
}

mv="$(manifest_version)"
[ -n "$mv" ] || die "读不到 cjpm.toml 的 version"

info "1/5 cjpm build"
eval "$(cjvs env bash)" && eval "$(cjvs stdx-env bash)"
cjpm build -j 16 > /dev/null || die "cjpm build 失败"

info "2/5 校验本地二进制版本"
bv="$(binary_version)"
[ -n "$bv" ] || die "跑不出二进制版本号（$BIN 存在吗？）"
[ "$bv" = "$mv" ] || die "本地二进制是 $bv，cjpm.toml 是 $mv —— release 二进制没刷新（cjpm build 没跑完？）"
info "    本地二进制 = $bv ✓"

info "3/5 重建镜像"
(cd "$COMPOSE_DIR" && docker compose build > /dev/null) || die "镜像构建失败"

info "4/5 重启容器（--force-recreate：镜像 tag 恒为 latest，不强制就不会换）"
(cd "$COMPOSE_DIR" && docker compose up -d --force-recreate > /dev/null) || die "容器启动失败"

info "5/5 校验容器内二进制与本地逐字节一致"
# 容器刚起来时要等它 healthy，否则 exec 可能落到还没就绪的容器上
for _ in $(seq 1 30); do
    status="$(docker inspect -f '{{.State.Health.Status}}' "$CONTAINER" 2>/dev/null || echo none)"
    [ "$status" = "healthy" ] && break
    sleep 2
done
local_sha="$(sha256sum "$BIN" | awk '{print $1}')"
cont_sha="$(docker exec "$CONTAINER" sha256sum /app/chronomem.cli 2>/dev/null | awk '{print $1}')"
[ -n "$cont_sha" ] || die "读不到容器内二进制 sha（容器起了吗？）"
[ "$local_sha" = "$cont_sha" ] || die "容器内二进制与本地不一致：local=$local_sha container=$cont_sha"

cv="$(docker logs "$CONTAINER" 2>&1 | grep -E '^chronomem [0-9]' | tail -1 | sed 's/^chronomem //')"
info "    容器内版本 = $cv ✓  sha256 = ${cont_sha:0:12}…"
[ "$cv" = "$mv" ] || die "容器报的版本是 $cv，cjpm.toml 是 $mv —— 部署没生效"

printf '\033[32m[部署完成]\033[0m chronomem %s 已上线（%s）\n' "$mv" "$CONTAINER"
