#!/bin/bash
#
# Charon Proxy 反向代理 - 一键安装与 Socket Activation 配置脚本
# 适用系统: Ubuntu 22.04 / 24.04 LTS
#
# 注意: 服务名和容器名统一使用 charon-proxy，避免与 strongSwan 的 charon 守护进程冲突
#

set -euo pipefail

# ==============================================================================
# 🎯 配置区域
# ==============================================================================

CHARON_BASE_DIR="/opt/podman/charon-proxy"
CHARON_ENV_FILE="$CHARON_BASE_DIR/charon-proxy.env"
CHARON_SERVICE_NAME="charon-proxy"
TIMEZONE="Asia/Shanghai"
CHARON_IMAGE="docker.io/wikid82/charon:latest"

CURRENT_USER="$(whoami)"
USER_UID="$(id -u)"

REGISTRY_MIRRORS=(
  "docker.xuanyuan.me"
  "docker.m.daocloud.io"
  "docker.1ms.run"
)

# ==============================================================================
# 🚀 脚本主体
# ==============================================================================

echo "🔧 开始配置 Charon Proxy 反向代理..."
echo "   用户: $CURRENT_USER (UID: $USER_UID)"
echo "   集中目录: $CHARON_BASE_DIR"
echo "   服务名: $CHARON_SERVICE_NAME"
echo ""

# ==============================================================================
# ⚠️  root 用户检测
# ==============================================================================

if [[ "$CURRENT_USER" == "root" ]]; then
    echo "⚠️  警告: 检测到您正在以 root 用户身份运行此脚本。"
    echo "   本脚本专为 Rootless Podman 设计，建议使用普通用户执行。"
    echo "   以 root 运行可能导致权限配置异常。"
    echo ""
    echo "   是否仍要继续？(y/N) [10秒后自动选择 N]"
    read -t 10 -r response || true
    case "$response" in
        [yY][eE][sS]|[yY])
            echo "   已确认，将继续执行..."
            ;;
        *)
            echo "   ❌ 安装已取消。请切换到普通用户后重新运行。"
            exit 0
            ;;
    esac
fi

# ==============================================================================
# 🔍 询问是否启用本地容器发现
# ==============================================================================

echo ""
echo "🔍 是否启用本地容器自动发现？"
echo "   此功能允许 Charon Proxy 自动检测本机上的容器并为其创建代理规则。"
echo "   如果你只代理远程主机（如内网服务器）上的服务，无需启用。"
echo ""
read -t 15 -r -p "   启用容器自动发现？(y/N) [15秒后默认 N]: " ENABLE_DISCOVERY || true
case "${ENABLE_DISCOVERY:-}" in
    [yY][eE][sS]|[yY])
        ENABLE_DISCOVERY=true
        echo "   ✅ 将启用容器自动发现"
        ;;
    *)
        ENABLE_DISCOVERY=false
        echo "   ℹ️  跳过容器自动发现（跨主机场景下的推荐配置）"
        ;;
esac

# ------------------------------------------------------------------------------
# 1. 安装 Podman 与 podman-compose
# ------------------------------------------------------------------------------
echo ""
echo "📦 [1/8] 检查并安装 Podman 与 podman-compose..."

if ! command -v podman &> /dev/null; then
    sudo apt update -qq
    sudo apt install -y podman
else
    echo "   ✅ Podman 已安装: $(podman --version)"
fi

if ! command -v podman-compose &> /dev/null; then
    sudo apt install -y podman-compose
else
    echo "   ✅ podman-compose 已安装"
fi

if ! command -v docker &> /dev/null; then
    sudo apt install -y podman-docker
fi

# ------------------------------------------------------------------------------
# 2. 配置 Rootless 权限
# ------------------------------------------------------------------------------
echo ""
echo "🔐 [2/8] 配置 Rootless 权限..."

if ! grep -q "^$CURRENT_USER:" /etc/subuid 2>/dev/null; then
    sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "$CURRENT_USER"
else
    echo "   ✅ subuid/subgid 映射已存在"
fi

for binary in /usr/bin/newuidmap /usr/bin/newgidmap; do
    if [[ ! -f "$binary" ]]; then
        echo "   ❌ 错误: $binary 不存在，请先安装 uidmap"
        exit 1
    fi
    [[ -u "$binary" ]] || sudo chmod u+s "$binary"
done
echo "   ✅ newuidmap/newgidmap SUID 权限正常"

sudo loginctl enable-linger "$CURRENT_USER"
echo "   ✅ Lingering 已启用"

# ------------------------------------------------------------------------------
# 3. 配置国内镜像加速器
# ------------------------------------------------------------------------------
echo ""
echo "🌐 [3/8] 配置 Podman 国内镜像加速器..."

sudo mkdir -p /etc/containers
{
  echo 'unqualified-search-registries = ["docker.io"]'
  echo ''
  echo '[[registry]]'
  echo 'prefix = "docker.io"'
  echo 'location = "docker.io"'
  echo ''
  for mirror in "${REGISTRY_MIRRORS[@]}"; do
    echo '[[registry.mirror]]'
    echo "location = \"$mirror\""
    echo ''
  done
} | sudo tee /etc/containers/registries.conf > /dev/null

echo "   ✅ 已配置镜像加速器"

# ------------------------------------------------------------------------------
# 4. 启用 Podman Socket (仅在启用容器发现时)
# ------------------------------------------------------------------------------
echo ""
echo "🔌 [4/8] 配置 Podman Socket..."

if [[ "$ENABLE_DISCOVERY" == "true" ]]; then
    if [[ "$CURRENT_USER" == "root" ]]; then
        echo "   ⚠️ root 用户，使用系统级 Podman socket"
        systemctl enable --now podman.socket 2>/dev/null || true
        if ! systemctl is-active podman.socket &>/dev/null; then
            echo "   ❌ 系统级 Podman socket 未正常运行"
            exit 1
        fi
        PODMAN_SOCK_PATH="/run/podman/podman.sock"
    else
        systemctl --user enable --now podman.socket 2>/dev/null || true
        if ! systemctl --user is-active podman.socket &>/dev/null; then
            echo "   ❌ 用户级 Podman socket 未正常运行"
            exit 1
        fi
        PODMAN_SOCK_PATH="/run/user/$USER_UID/podman/podman.sock"
    fi

    [[ -S "$PODMAN_SOCK_PATH" ]] || { echo "   ❌ socket 文件不存在: $PODMAN_SOCK_PATH"; exit 1; }
    echo "   ✅ Podman socket 就绪: $PODMAN_SOCK_PATH"
else
    PODMAN_SOCK_PATH=""
    echo "   ℹ️  已跳过（未启用容器自动发现）"
fi

# ------------------------------------------------------------------------------
# 5. 创建集中管理目录
# ------------------------------------------------------------------------------
echo ""
echo "📁 [5/8] 创建集中管理目录..."

sudo mkdir -p "$CHARON_BASE_DIR"
sudo chown -R "$CURRENT_USER:$CURRENT_USER" "$CHARON_BASE_DIR"
mkdir -p "$CHARON_BASE_DIR/charon-data"

echo "   ✅ 目录已创建: $CHARON_BASE_DIR"

# ------------------------------------------------------------------------------
# 6. 管理密钥文件 (.env)
# ------------------------------------------------------------------------------
echo ""
echo "🔑 [6/8] 管理密钥文件..."

if [[ -f "$CHARON_ENV_FILE" ]]; then
    echo "   ⏳ 检测到已存在的密钥文件: $CHARON_ENV_FILE"

    if grep -q '^CHARON_JWT_SECRET=.\+' "$CHARON_ENV_FILE" && \
       grep -q '^CHARON_ENCRYPTION_KEY=.\+' "$CHARON_ENV_FILE"; then
        echo "   ✅ 密钥文件格式正确，将直接使用现有密钥。"
        echo "   ℹ️  迁移时请确保此文件与 charon-data 目录一同复制。"
    else
        echo ""
        echo "   ❌ 错误: 密钥文件存在，但格式不符合要求。"
        echo "      文件必须包含以下两行（值不能为空）："
        echo "        CHARON_JWT_SECRET=<密钥>"
        echo "        CHARON_ENCRYPTION_KEY=<密钥>"
        echo ""
        echo "      为避免破坏现有数据，脚本将退出。"
        echo "      如果你确认要重新生成密钥（会导致现有加密数据无法解密），"
        echo "      请手动删除或重命名该文件后重新运行脚本："
        echo "        mv $CHARON_ENV_FILE ${CHARON_ENV_FILE}.bak"
        exit 1
    fi
else
    echo "   ⏳ 未检测到密钥文件，正在生成新密钥..."

    NEW_JWT_SECRET="$(openssl rand -hex 32)"
    NEW_ENCRYPTION_KEY="$(openssl rand -base64 32)"

    cat > "$CHARON_ENV_FILE" <<EOF
# Charon Proxy 密钥文件 - 请妥善备份，勿泄露
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')
CHARON_JWT_SECRET=$NEW_JWT_SECRET
CHARON_ENCRYPTION_KEY=$NEW_ENCRYPTION_KEY
EOF

    chmod 600 "$CHARON_ENV_FILE"

    echo "   ✅ 已生成新密钥并保存至: $CHARON_ENV_FILE"
    echo "   🔐 请务必备份此文件！丢失 CHARON_ENCRYPTION_KEY 将无法解密已有数据。"
fi

if [[ ! -r "$CHARON_ENV_FILE" ]]; then
    echo "   ❌ 错误: 密钥文件不可读，请检查权限。"
    exit 1
fi

# ------------------------------------------------------------------------------
# 7. 预先拉取 Charon 镜像
# ------------------------------------------------------------------------------
echo ""
echo "📥 [7/8] 预先拉取 Charon 镜像..."

if podman image exists "$CHARON_IMAGE" 2>/dev/null; then
    echo "   ✅ 镜像已存在"
else
    if ! podman pull "$CHARON_IMAGE"; then
        echo "   ❌ 镜像拉取失败"
        exit 1
    fi
    echo "   ✅ 镜像拉取成功"
fi

# ------------------------------------------------------------------------------
# 8. 生成 Systemd 单元文件并启用
# ------------------------------------------------------------------------------
echo ""
echo "⚙️  [8/8] 生成 Systemd 单元文件并启用..."

# --- 8a. Socket 单元文件 ---
cat > "$CHARON_BASE_DIR/$CHARON_SERVICE_NAME.socket" <<EOF
[Unit]
Description=Charon Proxy Reverse Proxy Socket

[Socket]
ListenStream=80
ListenStream=443
# ListenDatagram=443

[Install]
WantedBy=sockets.target
EOF

# --- 8b. 根据 ENABLE_DISCOVERY 决定是否挂载 Podman socket ---
if [[ "$ENABLE_DISCOVERY" == "true" ]]; then
    PODMAN_SOCK_LINE="  -e ALLOW_DOCKER_SOCK_GID_0=true \\\\\n  -v $PODMAN_SOCK_PATH:/var/run/docker.sock:ro \\\\"
else
    PODMAN_SOCK_LINE=""
fi

# --- 8c. Service 单元文件 ---
cat > "$CHARON_BASE_DIR/$CHARON_SERVICE_NAME.service" <<EOF
[Unit]
Description=Charon Proxy Reverse Proxy (Rootless Podman, Socket Activation)
After=network-online.target
Wants=network-online.target

Requires=$CHARON_SERVICE_NAME.socket
After=$CHARON_SERVICE_NAME.socket

[Service]
Type=notify
NotifyAccess=all
User=$CURRENT_USER
Group=$CURRENT_USER

CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE

ExecStart=/usr/bin/podman run --rm --name $CHARON_SERVICE_NAME --network=host --sdnotify=conmon --preserve-fds=1 --env-file $CHARON_ENV_FILE $PODMAN_SOCK_LINE -v $CHARON_BASE_DIR/charon-data:/app/data:U -e TZ=$TIMEZONE $CHARON_IMAGE

ExecStop=/usr/bin/podman stop -t 10 $CHARON_SERVICE_NAME
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF

echo "   ✅ 单元文件已生成"

# --- 8d. 安装为系统级服务 ---
sudo ln -sf "$CHARON_BASE_DIR/$CHARON_SERVICE_NAME.socket" "/etc/systemd/system/$CHARON_SERVICE_NAME.socket"
sudo ln -sf "$CHARON_BASE_DIR/$CHARON_SERVICE_NAME.service" "/etc/systemd/system/$CHARON_SERVICE_NAME.service"

sudo systemctl daemon-reload

echo "🧹 清理旧状态..."
sudo systemctl stop "$CHARON_SERVICE_NAME.socket" "$CHARON_SERVICE_NAME.service" 2>/dev/null || true
sudo systemctl reset-failed "$CHARON_SERVICE_NAME.socket" "$CHARON_SERVICE_NAME.service" 2>/dev/null || true

echo "🚀 启用并启动 Charon Proxy Socket..."
sudo systemctl enable --now "$CHARON_SERVICE_NAME.socket"

sleep 1
if ! sudo systemctl is-active "$CHARON_SERVICE_NAME.socket" &>/dev/null; then
    echo "   ❌ socket 未激活"
    sudo journalctl -u "$CHARON_SERVICE_NAME.socket" -n 20 --no-pager
    exit 1
fi

echo "   ✅ $CHARON_SERVICE_NAME.socket 已激活"
echo ""
echo "=========================================="
echo "✅ Charon Proxy 配置完成！"
echo "=========================================="
echo ""
echo "📌 管理界面:  http://你的服务器IP:8080"
echo "📌 服务名:    $CHARON_SERVICE_NAME"
echo "📌 密钥文件:  $CHARON_ENV_FILE"
echo "📌 数据目录:  $CHARON_BASE_DIR/charon-data"
if [[ "$ENABLE_DISCOVERY" == "true" ]]; then
    echo "📌 容器发现:  已启用（socket: $PODMAN_SOCK_PATH）"
else
    echo "📌 容器发现:  未启用（手动添加代理规则）"
fi
echo ""
echo "💡 迁移提示："
echo "   若要将 Charon Proxy 迁移到其他服务器，请完整复制以下内容："
echo "     - $CHARON_ENV_FILE"
echo "     - $CHARON_BASE_DIR/charon-data/"
echo "   然后在新服务器上运行本脚本即可。"
echo ""
echo "🔍 常用命令："
echo "   查看 socket 状态:  sudo systemctl status $CHARON_SERVICE_NAME.socket"
echo "   查看服务状态:      sudo systemctl status $CHARON_SERVICE_NAME.service"
echo "   查看容器状态:      podman ps -a --filter name=$CHARON_SERVICE_NAME"
echo "   查看日志:          sudo journalctl -u $CHARON_SERVICE_NAME.service -f"