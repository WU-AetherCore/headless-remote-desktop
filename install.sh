#!/usr/bin/env bash
# headless-remote-desktop 一键安装脚本
# 用法: sudo bash install.sh
# 自定义: sudo RESOLUTION=2560x1440 WEB_PORT=8080 bash install.sh
set -euo pipefail

RESOLUTION="${RESOLUTION:-1920x1080}"
VNC_PORT="${VNC_PORT:-5900}"
WEB_PORT="${WEB_PORT:-6080}"
PANEL_PORT="${PANEL_PORT:-80}"
INSTALL_PANEL="${INSTALL_PANEL:-1}"
DESKTOP_USER="${DESKTOP_USER:-}"
SERVICE="headless-desktop"
PANEL_SERVICE="headless-desktop-panel"

c_ok()   { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
c_warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
c_err()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; }
die()    { c_err "$*"; exit 1; }

[ "$(id -u)" -eq 0 ] || die "请用 root 运行：sudo bash install.sh"

# ---------- 1. 选择桌面用户 ----------
if [ -z "$DESKTOP_USER" ]; then
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        DESKTOP_USER="$SUDO_USER"
    else
        DESKTOP_USER="$(awk -F: '$3>=1000 && $3<65534 {print $1; exit}' /etc/passwd)"
    fi
fi
id "$DESKTOP_USER" >/dev/null 2>&1 || die "找不到用户: $DESKTOP_USER"
D_UID="$(id -u "$DESKTOP_USER")"
D_GID="$(id -g "$DESKTOP_USER")"
c_ok "桌面用户: $DESKTOP_USER (uid=$D_UID)"

# ---------- 2. 安装依赖 ----------
c_ok "安装依赖..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq || c_warn "apt update 失败，继续尝试"

NEED=""
for pkg in wayvnc novnc websockify wlr-randr labwc; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then NEED="$NEED $pkg"; fi
done

if [ -n "$NEED" ]; then
    c_ok "需要安装:$NEED"
    # shellcheck disable=SC2086
    apt-get install -y $NEED || {
        c_warn "整包安装失败，逐个尝试"
        for pkg in $NEED; do
            apt-get install -y "$pkg" || c_warn "安装失败: $pkg"
        done
    }
else
    c_ok "依赖已齐备，无需下载"
fi

for bin in wayvnc wlr-randr; do
    command -v "$bin" >/dev/null 2>&1 || die "缺少必要命令: $bin（请手动安装后重试）"
done
command -v labwc >/dev/null 2>&1 || die "缺少 labwc（Wayland 合成器），请手动安装后重试"
[ -d /usr/share/novnc ] || die "缺少 noVNC 页面目录 /usr/share/novnc"
command -v websockify >/dev/null 2>&1 || die "缺少 websockify"

# ---------- 3. 写入启动脚本 ----------
c_ok "写入启动/停止脚本..."
cat > /usr/local/bin/${SERVICE}-start.sh <<EOF
#!/usr/bin/env bash
set -u
USER_NAME="${DESKTOP_USER}"
RES="${RESOLUTION}"
RT="/run/user/${D_UID}"
export XDG_RUNTIME_DIR="\$RT"

[ -d "\$RT" ] || { echo "运行目录不存在: \$RT（用户未登录过？）"; exit 1; }

# 清理上一次残留
for f in /run/${SERVICE}.labwc.pid /run/${SERVICE}.wayvnc.pid /run/${SERVICE}.novnc.pid; do
    [ -f "\$f" ] && kill "\$(cat "\$f")" 2>/dev/null
    rm -f "\$f"
done
pkill -f "wayvnc -o" 2>/dev/null || true
pkill -f "websockify --web=/usr/share/novnc ${WEB_PORT}" 2>/dev/null || true
rm -f "\$RT"/wayland-* 2>/dev/null || true

export WLR_BACKENDS=headless
export WLR_HEADLESS_OUTPUTS=1
export WLR_RENDERER=pixman

labwc >/tmp/${SERVICE}-labwc.log 2>&1 &
echo \$! > /run/${SERVICE}.labwc.pid

SOCK=""
for i in \$(seq 1 40); do
    SOCK=\$(ls "\$RT"/wayland-* 2>/dev/null | grep -v '\.lock' | head -1)
    [ -n "\$SOCK" ] && break
    sleep 0.5
done
if [ -z "\$SOCK" ]; then
    echo "labwc 启动失败，日志：/tmp/${SERVICE}-labwc.log"
    exit 1
fi
export WAYLAND_DISPLAY=\$(basename "\$SOCK")

OUT=\$(wlr-randr 2>/dev/null | awk '/^[A-Za-z0-9_-]+ /{print \$1; exit}')
[ -z "\$OUT" ] && OUT="HEADLESS-1"
wlr-randr --output "\$OUT" --custom-mode "\$RES" >/dev/null 2>&1 || true

wayvnc -o "\$OUT" 0.0.0.0 ${VNC_PORT} >/tmp/${SERVICE}-wayvnc.log 2>&1 &
echo \$! > /run/${SERVICE}.wayvnc.pid
sleep 2

websockify --web=/usr/share/novnc ${WEB_PORT} 127.0.0.1:${VNC_PORT} >/tmp/${SERVICE}-novnc.log 2>&1 &
echo \$! > /run/${SERVICE}.novnc.pid
sleep 1

echo "桌面已启动: http://0.0.0.0:${WEB_PORT}/  (输出=\$OUT, 分辨率=\$RES)"
EOF

cat > /usr/local/bin/${SERVICE}-stop.sh <<EOF
#!/usr/bin/env bash
set -u
for f in /run/${SERVICE}.novnc.pid /run/${SERVICE}.wayvnc.pid /run/${SERVICE}.labwc.pid; do
    [ -f "\$f" ] && kill "\$(cat "\$f")" 2>/dev/null
    rm -f "\$f"
done
pkill -f "websockify --web=/usr/share/novnc ${WEB_PORT}" 2>/dev/null || true
pkill -f "wayvnc -o" 2>/dev/null || true
pkill -u "${DESKTOP_USER}" -f labwc 2>/dev/null || true
sleep 1
echo "桌面已停止，内存已释放"
EOF

chmod 755 /usr/local/bin/${SERVICE}-start.sh /usr/local/bin/${SERVICE}-stop.sh

# ---------- 4. 写入 systemd 桌面服务 ----------
c_ok "写入 systemd 服务..."
cat > /etc/systemd/system/${SERVICE}.service <<EOF
[Unit]
Description=On-demand headless desktop (labwc + wayvnc + noVNC)
After=network-online.target systemd-user-sessions.service

[Service]
Type=oneshot
RemainAfterExit=yes
User=${DESKTOP_USER}
Group=${D_GID}
ExecStart=/usr/local/bin/${SERVICE}-start.sh
ExecStop=/usr/local/bin/${SERVICE}-stop.sh
KillMode=control-group
TimeoutStopSec=15
Nice=5

[Install]
WantedBy=multi-user.target
EOF

# ---------- 5. noVNC 入口页（自动连接 + 自适应） ----------
if [ -f /usr/share/novnc/index.html ] && ! grep -q 'headless-desktop' /usr/share/novnc/index.html 2>/dev/null; then
    cp -f /usr/share/novnc/index.html /usr/share/novnc/index.html.bak 2>/dev/null || true
fi
cat > /usr/share/novnc/index.html <<EOF
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="generator" content="headless-desktop">
<title>远程桌面</title>
<meta http-equiv="refresh" content="0; url=vnc.html?autoconnect=1&resize=scale&reconnect=1&reconnect_delay=2000&show_dot=true">
<style>
body{background:#0a0e14;color:#c9d1d9;font-family:system-ui,-apple-system,"Segoe UI",sans-serif;
display:flex;align-items:center;justify-content:center;height:100vh;margin:0;flex-direction:column;gap:14px}
a{color:#58a6ff;text-decoration:none}
</style>
</head>
<body>
<div>正在连接桌面…</div>
<div><a href="vnc.html?autoconnect=1&resize=scale&reconnect=1">如果没有自动跳转，点这里</a></div>
</body>
</html>
EOF

# ---------- 6. 网页控制台 ----------
if [ "$INSTALL_PANEL" = "1" ]; then
    c_ok "写入网页控制台..."
    cat > /usr/local/bin/${PANEL_SERVICE}.py <<'PYEOF'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import http.server, socketserver, subprocess, json, threading, os

SERVICE = "@SERVICE@"
WEB_PORT = @WEB_PORT@
PANEL_PORT = @PANEL_PORT@

def is_running():
    r = subprocess.run(["systemctl", "is-active", SERVICE], capture_output=True, text=True)
    return r.stdout.strip() == "active"

def mem():
    try:
        d = {}
        for l in open("/proc/meminfo"):
            if ":" in l:
                d[l.split(":")[0]] = int(l.split()[1])
        return round((d["MemTotal"] - d["MemAvailable"]) / 1024), round(d["MemAvailable"] / 1024)
    except Exception:
        return 0, 0

PAGE = """<!DOCTYPE html>
<html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>远程桌面控制台</title>
<style>
:root{--bg:#0d1117;--card:#161b22;--line:#30363d;--tx:#c9d1d9;--mut:#8b949e;--ok:#3fb950;--off:#f85149}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--tx);font-family:system-ui,-apple-system,"Segoe UI","PingFang SC","Microsoft YaHei",sans-serif;display:flex;align-items:center;justify-content:center;min-height:100vh;padding:20px}
.card{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:30px 34px;max-width:520px;width:100%;box-shadow:0 8px 30px rgba(0,0,0,.45)}
h1{font-size:20px;margin:0 0 6px}
.sub{color:var(--mut);font-size:13px;margin-bottom:22px}
.state{display:flex;align-items:center;gap:10px;font-size:16px;margin-bottom:8px}
.dot{width:11px;height:11px;border-radius:50%;display:inline-block}
.on{background:var(--ok);box-shadow:0 0 10px var(--ok)}
.off{background:var(--off)}
.mem{color:var(--mut);font-size:13px;margin-bottom:24px}
.btns{display:flex;gap:12px;flex-wrap:wrap}
button,.link{flex:1;min-width:130px;padding:13px 18px;border-radius:9px;border:1px solid var(--line);background:#21262d;color:var(--tx);font-size:15px;cursor:pointer;text-align:center;text-decoration:none}
button:hover,.link:hover{background:#30363d}
.go{background:#238636;border-color:#238636;color:#fff}
.go:hover{background:#2ea043}
.stop{background:#b62324;border-color:#b62324;color:#fff}
.stop:hover{background:#d1242f}
.tip{margin-top:20px;color:var(--mut);font-size:12px;line-height:1.8;border-top:1px solid var(--line);padding-top:16px}
code{background:#0d1117;padding:2px 6px;border-radius:4px;font-size:12px}
</style></head><body>
<div class="card">
  <h1>远程桌面</h1>
  <div class="sub">无头服务器 · 按需开启，用完关闭</div>
  <div class="state"><span class="dot __DOT__"></span><b>__STATE__</b></div>
  <div class="mem">系统内存：已用 __USED__ MB / 可用 __AVAIL__ MB</div>
  <div class="btns">__ACTIONS__</div>
  <div class="tip">
    开启后点「打开桌面」，或访问 <code>http://__HOST__:__WEB__/</code><br>
    也支持任何 VNC 客户端连接 <code>__HOST__:5900</code><br>
    关闭后进程完全退出，内存立即释放
  </div>
</div></body></html>"""

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code, body, ctype):
        b = body.encode("utf-8") if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        if self.path.startswith("/api/status"):
            self._send(200, json.dumps({"running": is_running()}), "application/json")
            return
        on = is_running()
        used, avail = mem()
        host = (self.headers.get("Host") or "%s" % os.uname().nodename).split(":")[0]
        if on:
            actions = ('<a class="link go" href="http://' + host + ':' + str(WEB_PORT) + '/" target="_blank">打开桌面</a>'
                       '<form method="post" action="/stop" style="flex:1;margin:0"><button class="stop">关闭桌面</button></form>')
        else:
            actions = ('<form method="post" action="/start" style="flex:1;margin:0"><button class="go">启动桌面</button></form>'
                       '<a class="link" href="/">刷新状态</a>')
        html = (PAGE.replace("__DOT__", "on" if on else "off")
                    .replace("__STATE__", "运行中" if on else "已关闭")
                    .replace("__USED__", str(used)).replace("__AVAIL__", str(avail))
                    .replace("__WEB__", str(WEB_PORT))
                    .replace("__HOST__", host).replace("__ACTIONS__", actions))
        self._send(200, html, "text/html; charset=utf-8")

    def do_POST(self):
        if self.path.startswith("/start"):
            subprocess.run(["systemctl", "start", SERVICE], timeout=90)
        elif self.path.startswith("/stop"):
            subprocess.run(["systemctl", "stop", SERVICE], timeout=90)
        self.send_response(303)
        self.send_header("Location", "/")
        self.end_headers()

if __name__ == "__main__":
    socketserver.TCPServer.allow_reuse_address = True
    with socketserver.ThreadingTCPServer(("0.0.0.0", PANEL_PORT), H) as srv:
        srv.serve_forever()
PYEOF

    # 替换占位符
    sed -i "s/@SERVICE@/${SERVICE}/g; s/@WEB_PORT@/${WEB_PORT}/g; s/@PANEL_PORT@/${PANEL_PORT}/g" \
        /usr/local/bin/${PANEL_SERVICE}.py
    chmod 755 /usr/local/bin/${PANEL_SERVICE}.py
    python3 -c "import ast,sys; ast.parse(open('/usr/local/bin/${PANEL_SERVICE}.py').read())" \
        || die "控制台脚本语法错误"

    cat > /etc/systemd/system/${PANEL_SERVICE}.service <<EOF
[Unit]
Description=Remote desktop web control panel
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/bin/${PANEL_SERVICE}.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
fi

# ---------- 7. 启动服务 ----------
c_ok "启用 linger（保证无人登录时也有 /run/user/<uid>）..."
loginctl enable-linger "$DESKTOP_USER" >/dev/null 2>&1 || c_warn "enable-linger 失败，重启后可能缺少 /run/user/${D_UID}"

c_ok "启用服务..."
systemctl daemon-reload
systemctl stop "$SERVICE" 2>/dev/null || true
systemctl start "$SERVICE"
sleep 3

if ! systemctl is-active --quiet "$SERVICE"; then
    c_err "桌面服务启动失败，日志：journalctl -u ${SERVICE} -n 30"
    exit 1
fi

if [ "$INSTALL_PANEL" = "1" ]; then
    systemctl enable "${PANEL_SERVICE}" >/dev/null 2>&1 || true
    systemctl restart "${PANEL_SERVICE}" || c_warn "控制台启动失败"
fi

# ---------- 8. 结果 ----------
IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
[ -z "$IP" ] && IP="<服务器IP>"

echo
echo "──────────────────────────────────────────────"
c_ok "安装完成"
echo "  桌面地址   : http://${IP}:${WEB_PORT}/"
if [ "$INSTALL_PANEL" = "1" ]; then
    if [ "$PANEL_PORT" = "80" ]; then
        echo "  控制台地址 : http://${IP}/"
    else
        echo "  控制台地址 : http://${IP}:${PANEL_PORT}/"
    fi
fi
echo "  原生 VNC   : ${IP}:${VNC_PORT}"
echo "  分辨率     : ${RESOLUTION}"
echo "  运行用户   : ${DESKTOP_USER}"
echo
echo "  开关命令   : systemctl start|stop ${SERVICE}"
echo "  关闭后内存 : 立即释放"
echo "──────────────────────────────────────────────"
