#!/usr/bin/env bash
set -euo pipefail

# ================== 配置区 ==================
export INSTALL_DIR=${INSTALL_DIR:-'/opt/new-api'} 
export SERVICE_NAME=${SERVICE_NAME:-'new-api'} 
export SERVICE_PORT=${SERVICE_PORT:-'3000'} 
export RUN_USER=${RUN_USER:-'root'} 

GITHUB_REPO="QuantumNous/new-api"
RELEASE_API="https://api.github.com/repos/${GITHUB_REPO}/releases?per_page=1"
DOWNLOAD_BASE="https://github.com/${GITHUB_REPO}/releases/download"
# ============================================

usage() {
    cat <<EOF
用法: $0 [选项]
  (无参数)          下载二进制并部署/更新 new-api
  -u, --uninstall   停止服务并卸载 new-api
  -h, --help        显示本帮助
EOF
}

require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "[ERROR] 请使用 root 运行此脚本。"
        exit 1
    fi
}

### 获取公网 IPv4，失败时回退到本地 IP
get_public_ip() {
    local public_ip=""
    if command -v curl &>/dev/null; then
        public_ip=$(curl -fsS --max-time 5 https://ipv4.ip.sb 2>/dev/null || true)
    fi
    if [[ -z "$public_ip" ]]; then
        public_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi
    echo "$public_ip"
}

### 请求 GitHub Release API，返回 JSON
get_latest_release_json() {
    local json=""
    if command -v curl &>/dev/null; then
        local curl_args=(-fsSL --max-time 10 -H "Accept: application/vnd.github+json")
        [[ -n "${GITHUB_TOKEN:-}" ]] && curl_args+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
        json=$(curl "${curl_args[@]}" "$RELEASE_API" 2>/dev/null || true)
    elif command -v wget &>/dev/null; then
        local wget_args=(-qO- --timeout=10 --header="Accept: application/vnd.github+json")
        [[ -n "${GITHUB_TOKEN:-}" ]] && wget_args+=(--header="Authorization: Bearer ${GITHUB_TOKEN}")
        json=$(wget "${wget_args[@]}" "$RELEASE_API" 2>/dev/null || true)
    else
        echo "[ERROR] 系统未安装 curl 或 wget，无法获取版本信息。" >&2
        exit 1
    fi
    printf '%s' "$json"
}

### 从 API 返回的 JSON 中提取 tag_name（如 v1.0.0-rc.48）
extract_tag() {
    local json="$1" tag=""
    if command -v jq &>/dev/null; then
        tag=$(printf '%s' "$json" \
            | jq -r 'if type=="array" then (.[0].tag_name // empty) else (.tag_name // empty) end' \
            2>/dev/null || true)
    else
        tag=$(printf '%s' "$json" \
            | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' \
            | head -n1 \
            | sed 's/.*"\([^"]*\)"$/\1/' \
            2>/dev/null || true)
    fi
    printf '%s' "$tag"
}

### 安装 / 更新
install_new_api() {
    local arch
    arch=$(uname -m)
    local download_url

    echo "[INFO] 正在获取 new-api 最新版本..."
    local api_json version
    api_json=$(get_latest_release_json)
    version=$(extract_tag "$api_json")
    if [[ -z "$version" ]]; then
        echo "[ERROR] 获取最新版本失败，可能是网络问题或 GitHub API 限流。"
        echo "        可设置 GITHUB_TOKEN 环境变量后重试，例如:"
        echo "        export GITHUB_TOKEN=ghp_xxx && bash $0"
        exit 1
    fi
    echo "[INFO] 最新版本: $version"

    case "$arch" in
        x86_64) download_url="${DOWNLOAD_BASE}/${version}/new-api-${version}" ;;
        aarch64|arm64) download_url="${DOWNLOAD_BASE}/${version}/new-api-arm64-${version}" ;;
        *) echo "[ERROR] 不支持的架构: $arch（仅支持 x86_64 / aarch64）"; exit 1 ;;
    esac

    echo "[INFO] 系统架构: $arch"
    echo "[INFO] 下载地址: $download_url"

    mkdir -p "$INSTALL_DIR"/{data,logs}
    echo "[OK] 创建目录: $INSTALL_DIR/{data,logs}"

    echo "[INFO] 正在下载 new-api 二进制文件..."
    if command -v curl &>/dev/null; then
        curl -L --progress-bar "$download_url" -o "$INSTALL_DIR/new-api"
    elif command -v wget &>/dev/null; then
        wget -q --show-progress "$download_url" -O "$INSTALL_DIR/new-api"
    else
        echo "[ERROR] 系统未安装 curl 或 wget，无法下载。"
        exit 1
    fi

    chmod +x "$INSTALL_DIR/new-api"
    echo "[OK] 已授权: $INSTALL_DIR/new-api"

    local service_file="/etc/systemd/system/${SERVICE_NAME}.service"
    cat > "$service_file" <<EOF
[Unit]
Description=New API Service
After=network.target

[Service]
User=${RUN_USER}
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/new-api --port ${SERVICE_PORT} --log-dir ${INSTALL_DIR}/logs
Restart=always
RestartSec=5
Environment="TZ=Asia/Shanghai"
Environment="SQLITE_PATH=${INSTALL_DIR}/data/one-api.db"
# Environment="SQL_DSN=root:password@tcp(127.0.0.1:3306)/new-api"
# Environment="REDIS_CONN_STRING=redis://127.0.0.1:6379"

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME"
    systemctl restart "$SERVICE_NAME"
    echo "[OK] systemd 服务已配置并启动: $SERVICE_NAME"

    local public_ip
    public_ip=$(get_public_ip)
    echo ""
    echo "====================================================="
    echo "  New API 部署成功！(版本: ${version})"
    echo "  访问地址: http://${public_ip}:${SERVICE_PORT}"
    echo "  服务管理: systemctl status ${SERVICE_NAME}"
    echo "  数据目录: ${INSTALL_DIR}/data"
    echo "  日志目录: ${INSTALL_DIR}/logs"
    echo ""
    echo "确认访问没问题请解析一个域名 回源到${SERVICE_PORT} 端口"
    echo "====================================================="
}

### 卸载
uninstall() {
    echo "[INFO] 开始卸载 ${SERVICE_NAME} ..."

    echo "[INFO] 停止并禁用服务 ${SERVICE_NAME} ..."
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true

    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        echo "[WARN] 服务仍在运行，发送 SIGKILL ..."
        systemctl kill -s SIGKILL "$SERVICE_NAME" 2>/dev/null || true
        sleep 1
    fi
    echo "[OK] 服务已停止并禁用"

    local removed=false
    for f in \
        "/etc/systemd/system/${SERVICE_NAME}.service" \
        "/lib/systemd/system/${SERVICE_NAME}.service" \
        "/usr/lib/systemd/system/${SERVICE_NAME}.service"; do
        if [[ -f "$f" ]]; then
            rm -f "$f"
            echo "[OK] 已删除 $f"
            removed=true
        fi
    done
    if [[ "$removed" == false ]]; then
        echo "[INFO] 未找到 ${SERVICE_NAME}.service 文件。"
    fi

    systemctl daemon-reload
    systemctl reset-failed "$SERVICE_NAME" 2>/dev/null || true

    if pgrep -f "${INSTALL_DIR}/new-api" &>/dev/null; then
        echo "[WARN] 检测到残留进程，正在结束..."
        pkill -f "${INSTALL_DIR}/new-api" || true
        sleep 1
    fi

    if [[ -d "$INSTALL_DIR" ]]; then
        local ans="n"
        if [[ -t 0 ]]; then
            read -rp "是否删除安装目录 ${INSTALL_DIR}（包含 SQLite 数据库）? [y/N] " ans
        else
            echo "[INFO] 非交互环境，默认保留 ${INSTALL_DIR}。"
        fi
        if [[ "${ans,,}" == "y" ]]; then
            rm -rf "$INSTALL_DIR"
            echo "[OK] 已删除 $INSTALL_DIR"
        else
            echo "[INFO] 已保留 $INSTALL_DIR"
        fi
    fi
    echo "[OK] 卸载完成。"
}

main() {
    case "${1:-}" in
        -u|--uninstall) require_root; uninstall ;;
        -h|--help) usage ;;
        "") require_root; install_new_api ;;
        *) echo "[ERROR] 未知参数: $1"; usage; exit 1 ;;
    esac
}

main "$@"
