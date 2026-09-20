#!/bin/bash
#
# Charon Proxy 反向代理 - 一键安装脚本（Rootful Podman 版）
# 适用系统: Ubuntu 22.04 / 24.04 LTS
#
# 设计目标:
#   - 一个脚本装完即用，Web 界面配置反向代理
#   - 以 rootful podman + host network 运行，root 直接绑 80/443，无需 socket activation
#   - 迁移只需带走: charon-proxy.env  和  charon-data/  两样东西
#
# 用法（以普通用户 ubuntu 运行，脚本内部按需 sudo）:
#   chmod +x install-podman-charon.sh
#   ./install-podman-charon.sh
#
set -euo pipefail

# ==============================================================================
# 🎯 配置区域
# ==============================================================================
CHARON_BASE_DIR="/opt/podman/charon-proxy"
CHARON_ENV_FILE="$CHARON_BASE_DIR/charon-proxy.env"
CHARON_SERVICE_NAME="charon-proxy"
TIMEZONE="Asia/Shanghai"
# 生产建议锁定具体版本（如 :0.40.7）而不是 :latest，避免自动升级引入回归
CHARON_IMAGE="docker.io/wikid82/charon:latest"

REGISTRY_MIRRORS=(
    "docker.xuanyuan.me"
    "docker.m.daocloud.io"
    "docker.1ms.run"
)

# ==============================================================================
echo "🔧 开始配置 Charon Proxy 反向代理（Rootful 模式）..."
echo "   集中目录: $CHARON_BASE_DIR"
echo "   服务名:   $CHARON_SERVICE_NAME"
echo ""

# ==============================================================================
# 🔍 是否启用本地容器自动发现（rootful podman socket）
# ==============================================================================
echo "🔍 是否启用本地容器自动发现？"
echo "   仅当你要代理【本机上的其他容器】时才需要；只代理远程/内网主机则无需启用。"
read -t 15 -r -p "   启用容器自动发现？(y/N) [15秒后默认 N]: " ENABLE_DISCOVERY || true
case "${ENABLE_DISCOVERY:-}" in
    [yY][eE][sS]|[yY]) ENABLE_DISCOVERY=true;  echo "   ✅ 将启用容器自动发现" ;;
    *)                 ENABLE_DISCOVERY=false; echo "   ℹ️ 跳过容器自动发现" ;;
esac

# ------------------------------------------------------------------------------
# 1. 安装 Podman
# ------------------------------------------------------------------------------
echo ""
echo "📦 [1/6] 检查并安装 Podman..."
if ! command -v podman &> /dev/null; then
    sudo apt update -qq
    sudo apt install -y podman
else
    echo "   ✅ Podman 已安装: $(podman --version)"
fi

# ------------------------------------------------------------------------------
# 2. 配置国内镜像加速器（写入 conf.d，不覆盖系统原文件）
# ------------------------------------------------------------------------------
echo ""
echo "🌐 [2/6] 配置 Podman 国内镜像加速器..."
sudo mkdir -p /etc/containers/registries.conf.d
{
    echo '# 由 install-podman-charon.sh 生成'
    echo 'unqualified-search-registries = ["docker.io"]'
    echo ''
    echo '[[registry]]'
    echo 'prefix = "docker.io"'
    echo 'location = "docker.io"'
    for mirror in "${REGISTRY_MIRRORS[@]}"; do
        echo ''
        echo '[[registry.mirror]]'
        echo "location = \"$mirror\""
    done
} | sudo tee /etc/containers/registries.conf.d/99-charon-mirrors.conf > /dev/null
echo "   ✅ 已写入 /etc/containers/registries.conf.d/99-charon-mirrors.conf"

# ------------------------------------------------------------------------------
# 3. （可选）启用系统级 Podman socket，供容器发现使用
# ------------------------------------------------------------------------------
echo ""
echo "🔌 [3/6] 配置 Podman socket..."
if [[ "$ENABLE_DISCOVERY" == "true" ]]; then
    sudo systemctl enable --now podman.socket
    PODMAN_SOCK_PATH="/run/podman/podman.sock"
    [[ -S "$PODMAN_SOCK_PATH" ]] || { echo "   ❌ socket 不存在: $PODMAN_SOCK_PATH"; exit 1; }
    echo "   ✅ Podman socket 就绪: $PODMAN_SOCK_PATH"
else
    PODMAN_SOCK_PATH=""
    echo "   ℹ️ 已跳过"
fi

# ------------------------------------------------------------------------------
# 4. 创建目录 + 管理密钥文件(.env)
# ------------------------------------------------------------------------------
echo ""
echo "🔑 [4/6] 创建目录并管理密钥文件..."
sudo mkdir -p "$CHARON_BASE_DIR/charon-data"

if [[ -f "$CHARON_ENV_FILE" ]]; then
    echo "   ⏳ 检测到已存在密钥文件: $CHARON_ENV_FILE"
    if sudo grep -q '^CHARON_JWT_SECRET=.\+' "$CHARON_ENV_FILE" && \
       sudo grep -q '^CHARON_ENCRYPTION_KEY=.\+' "$CHARON_ENV_FILE"; then
        echo "   ✅ 密钥文件格式正确，沿用现有密钥（迁移场景）。"
    else
        echo "   ❌ 密钥文件存在但格式不符（必须含非空的 CHARON_JWT_SECRET 与 CHARON_ENCRYPTION_KEY）。"
        echo "      为避免破坏数据，脚本退出。如确需重建密钥（会导致已有加密数据无法解密）："
        echo "      sudo mv $CHARON_ENV_FILE ${CHARON_ENV_FILE}.bak"
        exit 1
    fi
else
    echo "   ⏳ 未检测到密钥文件，正在生成..."
    NEW_JWT_SECRET="$(openssl rand -hex 32)"
    NEW_ENCRYPTION_KEY="$(openssl rand -base64 32)"
    sudo tee "$CHARON_ENV_FILE" > /dev/null <<EOF
# Charon Proxy 密钥文件 - 请妥善备份，勿泄露
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')
CHARON_JWT_SECRET=$NEW_JWT_SECRET
CHARON_ENCRYPTION_KEY=$NEW_ENCRYPTION_KEY
EOF
    echo "   ✅ 已生成新密钥: $CHARON_ENV_FILE"
    echo "   🔐 请务必备份！丢失 CHARON_ENCRYPTION_KEY 将无法解密已有数据。"
fi
sudo chmod 600 "$CHARON_ENV_FILE"

# ------------------------------------------------------------------------------
# 5. 预拉取镜像
# ------------------------------------------------------------------------------
echo ""
echo "📥 [5/6] 预拉取 Charon 镜像..."
if sudo podman image exists "$CHARON_IMAGE" 2>/dev/null; then
    echo "   ✅ 镜像已存在"
else
    sudo podman pull "$CHARON_IMAGE" || { echo "   ❌ 镜像拉取失败"; exit 1; }
    echo "   ✅ 镜像拉取成功"
fi

# ------------------------------------------------------------------------------
# 6. 生成 systemd 系统服务并启动
# ------------------------------------------------------------------------------
echo ""
echo "⚙️ [6/6] 生成 systemd 单元并启动..."

# 可选：挂载 podman socket 用于容器发现
if [[ "$ENABLE_DISCOVERY" == "true" ]]; then
    DISCOVERY_LINE="  -v $PODMAN_SOCK_PATH:/var/run/docker.sock:ro \\"
else
    DISCOVERY_LINE=""
fi

sudo tee "/etc/systemd/system/$CHARON_SERVICE_NAME.service" > /dev/null <<EOF
[Unit]
Description=Charon Proxy Reverse Proxy (Rootful Podman, host network)
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
NotifyAccess=all
Environment=PODMAN_SYSTEMD_UNIT=%n
Restart=on-failure
RestartSec=5
TimeoutStartSec=300
ExecStart=/usr/bin/podman run --rm --replace --name $CHARON_SERVICE_NAME \\
  --network=host \\
  --sdnotify=conmon \\
  --env-file $CHARON_ENV_FILE \\
$DISCOVERY_LINE
  -v $CHARON_BASE_DIR/charon-data:/app/data:U \\
  -e TZ=$TIMEZONE \\
  $CHARON_IMAGE
ExecStop=/usr/bin/podman stop -t 10 $CHARON_SERVICE_NAME

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl reset-failed "$CHARON_SERVICE_NAME.service" 2>/dev/null || true
sudo systemctl enable --now "$CHARON_SERVICE_NAME.service"

sleep 3
if sudo systemctl is-active "$CHARON_SERVICE_NAME.service" &>/dev/null; then
    echo "   ✅ 服务已启动"
else
    echo "   ❌ 服务未能启动，最近日志："
    sudo journalctl -u "$CHARON_SERVICE_NAME.service" -n 30 --no-pager
    exit 1
fi

echo ""
echo "=========================================="
echo "✅ Charon Proxy 配置完成！"
echo "=========================================="
echo "📌 管理界面: http://你的服务器IP:8080"
echo "📌 密钥文件: $CHARON_ENV_FILE"
echo "📌 数据目录: $CHARON_BASE_DIR/charon-data"
echo ""
echo "💡 迁移到新机：复制 $CHARON_ENV_FILE 和 $CHARON_BASE_DIR/charon-data/ 到相同路径，再运行本脚本。"
echo ""
echo "🔍 常用命令："
echo "   状态: sudo systemctl status $CHARON_SERVICE_NAME.service"
echo "   日志: sudo journalctl -u $CHARON_SERVICE_NAME.service -f"
echo "   容器: sudo podman ps -a --filter name=$CHARON_SERVICE_NAME"