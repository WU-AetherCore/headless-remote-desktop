#!/usr/bin/env bash
# headless-remote-desktop 卸载脚本
set -uo pipefail

SERVICE="headless-desktop"
PANEL_SERVICE="headless-desktop-panel"

c_ok() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }

[ "$(id -u)" -eq 0 ] || { echo "请用 root 运行：sudo bash uninstall.sh" >&2; exit 1; }

c_ok "停止并删除服务..."
for s in "$SERVICE" "$PANEL_SERVICE"; do
    systemctl stop "$s" 2>/dev/null
    systemctl disable "$s" 2>/dev/null
    rm -f "/etc/systemd/system/${s}.service"
done
systemctl daemon-reload

c_ok "删除脚本..."
rm -f /usr/local/bin/${SERVICE}-start.sh \
      /usr/local/bin/${SERVICE}-stop.sh \
      /usr/local/bin/${PANEL_SERVICE}.py

c_ok "清理运行时文件..."
rm -f /run/${SERVICE}.*.pid /tmp/${SERVICE}-*.log

c_ok "还原 noVNC 入口页..."
if [ -f /usr/share/novnc/index.html.bak ]; then
    mv -f /usr/share/novnc/index.html.bak /usr/share/novnc/index.html
elif grep -q 'headless-desktop' /usr/share/novnc/index.html 2>/dev/null; then
    rm -f /usr/share/novnc/index.html
fi

echo
c_ok "卸载完成（系统依赖包未删除，如需删除请执行："
echo "   apt-get remove --purge wayvnc novnc websockify wlr-randr)"
