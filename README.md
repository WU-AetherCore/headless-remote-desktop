# headless-remote-desktop

给**无显示器的 Linux 服务器**（树莓派、Orange Pi、云服务器、NAS）按需开启一个
**可以用浏览器访问的桌面**，用完就关，不占内存。

一条命令安装，一个网页控制台开关，不需要接显示器、不需要 VNC 客户端。

```
浏览器 → http://<服务器IP>          ← 控制台：启动 / 关闭 / 看状态
浏览器 → http://<服务器IP>:6080     ← 桌面：自动连接、自适应窗口
```

---

## 它解决什么问题

服务器通常没有显示器。偶尔需要：

- 看一下某个图形程序的运行情况
- 用 `gpio`、`raspi-config` 这类只有图形界面才好用的工具
- 远程帮别人操作桌面

传统做法是装一整套 VNC（`x11vnc` + 桌面环境），代价是**常驻几百 MB 内存**，
而且服务器没接显示器时，X 服务往往起不来。

本项目换了个思路：

| 传统 VNC | 本项目 |
|---|---|
| 需要一个真实显示器/虚拟屏 | 用 **wlroots headless 后端**凭空造一个 1080p 输出 |
| 桌面常驻，一直吃内存 | **按需启动**，关掉就完全退出 |
| 需要装 VNC 客户端 | 浏览器直接看（noVNC） |
| 常开端口 | 只在需要时开 |

实测在树莓派 5 上：**开着约 145 MB，关掉 0 MB**。

---

## 环境要求

| 项目 | 要求 |
|---|---|
| 系统 | Debian 12+ / Ubuntu 22.04+ / Raspberry Pi OS Bookworm+ |
| 架构 | arm64 / x86_64 均可 |
| 桌面协议 | **Wayland**（wlroots 系合成器，如 labwc） |
| 依赖 | `labwc` `wayvnc` `wlr-randr` `novnc` `websockify` `python3` |
| 权限 | root（安装时需要） |

> 已经是 Raspberry Pi OS Bookworm 的话，`wayvnc` 和 `labwc` 都是预装的，安装脚本几乎不用下载东西。

---

## 一键安装

```bash
curl -fsSL https://raw.githubusercontent.com/<你的用户名>/headless-remote-desktop/main/install.sh | sudo bash
```

或者克隆后本地安装：

```bash
git clone https://github.com/<你的用户名>/headless-remote-desktop.git
cd headless-remote-desktop
sudo bash install.sh
```

安装完成后会打印访问地址。

### 自定义参数

所有参数都通过环境变量传入：

```bash
sudo RESOLUTION=2560x1440 WEB_PORT=8080 PANEL_PORT=8000 bash install.sh
```

| 变量 | 默认值 | 说明 |
|---|---|---|
| `DESKTOP_USER` | 第一个 UID≥1000 的用户 | 以哪个用户身份运行桌面 |
| `RESOLUTION` | `1920x1080` | 虚拟屏幕分辨率 |
| `VNC_PORT` | `5900` | 原生 VNC 端口（给 VNC 客户端用） |
| `WEB_PORT` | `6080` | 浏览器访问端口（noVNC） |
| `PANEL_PORT` | `80` | 控制台端口 |
| `INSTALL_PANEL` | `1` | 设为 `0` 则不装网页控制台 |

---

## 使用

### 网页控制台

打开 `http://<服务器IP>`：

- 显示 **运行中 / 已关闭** 和内存占用
- 点「启动桌面」→ 几秒后可用
- 点「关闭桌面」→ 进程完全退出，内存释放
- 点「打开桌面」→ 直接跳到桌面画面

### 直接开桌面

`http://<服务器IP>:6080` —— 自动连接、自适应窗口大小、无滚动条。

### 命令行

```bash
sudo systemctl start  headless-desktop   # 打开
sudo systemctl stop   headless-desktop   # 关闭
sudo systemctl status headless-desktop   # 状态
```

桌面服务**默认不开机自启**，符合「用完就关」的预期。想开机自启：

```bash
sudo systemctl enable headless-desktop
```

### 用 VNC 客户端连

除了浏览器，也可以连原生 VNC（端口 `5900`）：

- macOS：Finder → 前往 → 连接服务器 → `vnc://<IP>:5900`
- Windows：TightVNC / RealVNC Viewer / TigerVNC
- 手机：VNC Viewer

---

## 工作原理

```
systemctl start headless-desktop
        │
        ├─ labwc（WLR_BACKENDS=headless）   ← 凭空创建一个 Wayland 输出
        │      └─ 输出名如 HEADLESS-1，分辨率 1920x1080
        │
        ├─ wayvnc -o HEADLESS-1 :5900       ← 把这个输出导出为 VNC
        │
        └─ websockify :6080 → 5900          ← 把 VNC 转成 WebSocket
               └─ noVNC 页面（浏览器里渲染）
```

关键点：

1. **`WLR_BACKENDS=headless`** 让 wlroots 合成器不需要真实显卡输出。
   这是「无显示器也能有桌面」的核心。
2. **`WLR_RENDERER=pixman`** 走软件渲染，不依赖 GPU（服务器通常没有）。
3. **`wayvnc`** 直接读 Wayland 输出，不经过 X11，画质和延迟都比 X11 方案好。
4. **`websockify` + `noVNC`** 把 VNC 转成浏览器可播放的 WebSocket。

---

## 常见问题

**Q：桌面打开了但是黑屏？**

看日志：`cat /tmp/headless-desktop-labwc.log`。
常见原因是 `labwc` 没装，或者 `wlr-randr` 拿不到输出名。
脚本会自动探测输出名，探测不到时回退为 `HEADLESS-1`。

**Q：浏览器显示「正在连接」但不出来？**

检查 `6080` 端口是否被防火墙挡住：
`sudo ufw allow 6080/tcp` 或 `sudo firewall-cmd --add-port=6080/tcp --permanent`。

**Q：能不能用 X11 而不是 Wayland？**

可以，但本项目是针对 Wayland/wlroots 写的（更省资源、无显示器更好处理）。
X11 场景建议用 `x11vnc` + `Xvfb`。

**Q：非 Debian 系系统？**

`install.sh` 里的依赖安装部分只支持 apt。其他发行版可以只拷贝
`bin/` 和 `systemd/` 下的文件，自己装依赖后手动替换其中的路径占位符。

**Q：会不会有安全风险？**

控制台和桌面**默认都没有密码**，请只在可信内网使用。
需要暴露到公网时，建议：

- 放在反向代理后面并加 Basic Auth / OAuth
- 或者只允许通过 VPN / Tailscale 访问

---

## 卸载

```bash
sudo bash uninstall.sh
```

会停止并删除服务、脚本、noVNC 入口页，保留已安装的系统依赖。

---

## 目录结构

```
install.sh                  # 一键安装
uninstall.sh                # 卸载
bin/desktop-start.sh        # 启动脚本（labwc + wayvnc + websockify）
bin/desktop-stop.sh         # 停止脚本
bin/desktop-panel.py        # 网页控制台
systemd/desktop.service     # 桌面服务模板
systemd/panel.service       # 控制台服务
```

---

## 已验证环境

| 设备 | 系统 | 状态 |
|---|---|---|
| Raspberry Pi 5 (8G) | Debian 13 (trixie) / arm64 | ✅ 1920×1080，中文正常 |
| Raspberry Pi 5 (4G) | Raspberry Pi OS Bookworm | ✅ 内存占用约 145 MB |

---

## License

MIT
