#!/bin/bash
# Railway 启动脚本 — 从环境变量写入配置，然后启动 Gateway
set -e

HERMES_HOME="${HERMES_HOME:-/opt/data}"

echo "=== Hermes Railway Boot ==="

# 等待 entrypoint 完成初始化
sleep 3

# 确保 config.yaml 存在
if [ ! -f "$HERMES_HOME/config.yaml" ]; then
    echo "ERROR: config.yaml not found after entrypoint init"
    exit 1
fi

# 写入模型配置（从 Railway 环境变量读取）
echo "Configuring model..."
hermes config set model.default "${HERMES_MODEL:-deepseek-v4-pro}"
hermes config set model.provider "${HERMES_PROVIDER:-custom}"
hermes config set model.base_url "${HERMES_BASE_URL:-https://api.deepseek.com}"
hermes config set model.api_key "${DEEPSEEK_API_KEY:-}"

# 如果配置了 Telegram Webhook，写入配置
if [ -n "${TELEGRAM_WEBHOOK_URL}" ]; then
    echo "Setting Telegram webhook: ${TELEGRAM_WEBHOOK_URL}"
fi

echo "=== Starting Hermes Gateway ==="
exec hermes gateway run
