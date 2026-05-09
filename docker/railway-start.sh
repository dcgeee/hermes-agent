#!/bin/bash
# Railway 启动脚本 — 独立初始化 + 配置 + 启动 Gateway
# 由于 railway.json 的 startCommand 覆盖了 Dockerfile 的 ENTRYPOINT，
# 本脚本需要自己完成 entrypoint.sh 中的所有初始化工作。
set -e

HERMES_HOME="${HERMES_HOME:-/opt/data}"
INSTALL_DIR="/opt/hermes"

echo "=== Hermes Railway Boot ==="

# Railway 的 startCommand 会绕过 Dockerfile ENTRYPOINT，因此这里也必须
# 复制 entrypoint.sh 的 root -> hermes 降权逻辑。否则 gateway 会拒绝以
# root 身份启动，并导致 Railway healthcheck 超时。
if [ "$(id -u)" = "0" ]; then
    mkdir -p "$HERMES_HOME"

    if [ -n "$HERMES_UID" ] && [ "$HERMES_UID" != "$(id -u hermes)" ]; then
        echo "Changing hermes UID to $HERMES_UID"
        usermod -u "$HERMES_UID" hermes
    fi

    if [ -n "$HERMES_GID" ] && [ "$HERMES_GID" != "$(id -g hermes)" ]; then
        echo "Changing hermes GID to $HERMES_GID"
        groupmod -o -g "$HERMES_GID" hermes 2>/dev/null || true
    fi

    actual_hermes_uid=$(id -u hermes)
    needs_chown=false
    if [ -n "$HERMES_UID" ] && [ "$HERMES_UID" != "10000" ]; then
        needs_chown=true
    elif [ "$(stat -c %u "$HERMES_HOME" 2>/dev/null)" != "$actual_hermes_uid" ]; then
        needs_chown=true
    fi

    if [ "$needs_chown" = true ]; then
        echo "Fixing ownership of $HERMES_HOME to hermes ($actual_hermes_uid)"
        chown -R hermes:hermes "$HERMES_HOME" 2>/dev/null || \
            echo "Warning: chown failed (rootless container?) — continuing anyway"
    fi

    if [ -f "$HERMES_HOME/config.yaml" ]; then
        chown hermes:hermes "$HERMES_HOME/config.yaml" 2>/dev/null || true
        chmod 640 "$HERMES_HOME/config.yaml" 2>/dev/null || true
    fi

    echo "Dropping root privileges"
    exec gosu hermes bash "$0" "$@"
fi

# ── 1. 激活虚拟环境 ──
source "${INSTALL_DIR}/.venv/bin/activate"

# ── 2. 创建目录结构 ──
mkdir -p "$HERMES_HOME"/{cron,sessions,logs,hooks,memories,skills,skins,plans,workspace,home}

# ── 3. 初始化 .env（如果不存在） ──
if [ ! -f "$HERMES_HOME/.env" ]; then
    echo "Bootstrapping .env from example..."
    cp "$INSTALL_DIR/.env.example" "$HERMES_HOME/.env"
fi

# ── 4. 初始化 config.yaml（如果不存在） ──
if [ ! -f "$HERMES_HOME/config.yaml" ]; then
    echo "Bootstrapping config.yaml from example..."
    cp "$INSTALL_DIR/cli-config.yaml.example" "$HERMES_HOME/config.yaml"
fi

# ── 5. 初始化 SOUL.md（如果不存在） ──
if [ ! -f "$HERMES_HOME/SOUL.md" ] && [ -f "$INSTALL_DIR/docker/SOUL.md" ]; then
    cp "$INSTALL_DIR/docker/SOUL.md" "$HERMES_HOME/SOUL.md"
fi

# ── 6. 同步内置 skills ──
if [ -d "$INSTALL_DIR/skills" ]; then
    python3 "$INSTALL_DIR/tools/skills_sync.py" 2>/dev/null || true
fi

# ── 7. 写入模型配置 ──
echo "Configuring model..."
hermes config set model.default "${HERMES_MODEL:-deepseek-v4-pro}"
hermes config set model.provider "${HERMES_PROVIDER:-custom}"
hermes config set model.base_url "${HERMES_BASE_URL:-https://api.deepseek.com}"
hermes config set model.api_key "${DEEPSEEK_API_KEY:-}"

# ── 8. Railway healthcheck 需要 API Server 监听 /health ──
# Railway 只会把外部流量转发到 $PORT；api_server 默认不启用且默认只适合本地。
# 显式启用并绑定 0.0.0.0:$PORT，避免 /health 返回 service unavailable。
export API_SERVER_ENABLED="true"
export API_SERVER_HOST="0.0.0.0"
export API_SERVER_PORT="${PORT:-${API_SERVER_PORT:-8642}}"

# api_server refuses to bind to a public interface without an API key. Railway
# healthchecks do not need the key, but the server will not start unless one is
# configured. Prefer a Railway-provided API_SERVER_KEY; otherwise generate a
# persistent random key in the mounted HERMES_HOME volume.
if [ -z "${API_SERVER_KEY:-}" ]; then
    api_key_file="$HERMES_HOME/api_server.key"
    if [ -f "$api_key_file" ]; then
        API_SERVER_KEY="$(cat "$api_key_file")"
        echo "Loaded existing API_SERVER_KEY from $api_key_file"
    else
        API_SERVER_KEY="$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')"
        printf '%s\n' "$API_SERVER_KEY" > "$api_key_file"
        chmod 600 "$api_key_file" 2>/dev/null || true
        echo "Generated API_SERVER_KEY and stored it in $api_key_file"
    fi
fi
export API_SERVER_KEY

echo "Configuring API server healthcheck listener on ${API_SERVER_HOST}:${API_SERVER_PORT}..."
hermes config set platforms.api_server.enabled true
hermes config set platforms.api_server.extra.host "$API_SERVER_HOST"
hermes config set platforms.api_server.extra.port "$API_SERVER_PORT"
hermes config set platforms.api_server.extra.key "$API_SERVER_KEY"

echo "=== Starting Hermes Gateway ==="
exec hermes gateway run
