# chronomem — 生产镜像（产物打包）
# 构建策略：宿主工具链产出静态链接二进制（cjpm build，--static，无 libcangjie-runtime 依赖），
# 镜像内不重编译——chronomem.cli 依赖 ../mcp-cj 等 path 依赖，容器内自构建不现实。
# 基础镜像 archlinux：与宿主编译环境 glibc 一致，避免 GLIBC 符号缺失；
# badgercj 的 io_uring 动态依赖（liburing.so.2）+ 时区数据（自然窗口日历）+ CA 证书（LLM TLS）一并安装。
FROM archlinux:latest

# 非 root 运行（生产安全）：uid 1000 与宿主数据目录属主（ystyle）对齐，卷可写
RUN useradd -u 1000 -m app \
    && pacman -Sy --noconfirm liburing tzdata ca-certificates \
    && rm -rf /var/cache/pacman/pkg

WORKDIR /app

# 静态链接的 chronomem.cli（--static，无 libcangjie-runtime 依赖）
COPY target/release/bin/chronomem.cli /app/chronomem.cli

# Web 控制台静态资源（深色时间塔主题；serveStatic("/css", "public/css") 相对运行目录）
COPY public/css /app/public/css

# 数据目录（compose 挂载卷 $HOME/.chronolog：tsdb 时序库 + 类型注册表）
RUN mkdir -p /home/app/.chronolog && chown -R app:app /home/app/.chronolog /app

USER app
ENV HOME=/home/app

EXPOSE 8900 8901
CMD ["/app/chronomem.cli", "serve"]
