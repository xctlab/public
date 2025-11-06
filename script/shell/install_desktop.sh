#!/bin/bash

set -e

# 获取当前登录会话的原始用户名
REAL_USER=$(logname)
# 安全解析该用户的 home 目录
USER_HOME=$(eval echo "~$REAL_USER")

echo "🔄 更新系统..."
sudo apt update && sudo apt upgrade -y

# 安装 Google Noto 中日韩字体包（CJK: Chinese, Japanese, Korean）
sudo apt install -y fonts-noto-cjk

echo "📦 安装 Xfce 桌面环境..."
sudo apt install -y --no-install-recommends xfce4
sudo apt install -y elementary-xfce-icon-theme greybird-gtk-theme
# # 保留屏保
# xfconf-query -c xfce4-screensaver -p /saver/enabled -s true -t bool -n || true
# # 禁用锁屏密码
# xfconf-query -c xfce4-screensaver -p /lock/enabled -s false -t bool -n 2>/dev/null || true
# # 禁用 colord 密码弹窗
# sudo tee /etc/polkit-1/localauthority/50-local.d/colord.pkla > /dev/null <<EOF
# [Allow colord without password]
# Identity=unix-user:$(logname)
# Action=org.freedesktop.color-manager.*
# ResultAny=yes
# ResultInactive=yes
# ResultActive=yes
# EOF

echo "🖥️ 安装 xrdp 远程桌面服务..."
sudo apt install -y xrdp
sudo systemctl enable xrdp
sudo systemctl start xrdp

echo "🛠️ 配置 xrdp 使用 Xfce..."
# xrdp 登录时使用 startxfce4 启动 XFCE 桌面环境
echo "startxfce4" > "$USER_HOME/.xsession"
# /etc/skel/ 是系统在创建新用户时默认复制配置文件的地方
sudo cp "$USER_HOME/.xsession" /etc/skel/.xsession

echo "🔓 开放 RDP 端口..."
sudo ufw allow 3389/tcp || echo "⚠️ 防火墙未启用或 ufw 未安装"

echo "⬇️ 安装firefox浏览器"
sudo apt install -y firefox

echo "✅ 所有步骤完成。你现在可以使用 Windows 远程桌面 (mstsc) 连接此主机（端口 3389）。如果连接不上请联系运维开通端口"
