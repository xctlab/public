#!/bin/bash
set -e

REDROID_CONTAINER="redroid"
REDROID_PORT=5555
WS_SCRCPY_CONTAINER="ws-scrcpy"

# 安装docker
install_docker() {
  if command -v docker &>/dev/null; then
    echo "Docker 已安装"
  else
    curl -fsSL https://get.docker.com | sudo bash
  fi
}

# 安装binder_linux模块
install_binder_linux() {
  # 安装内核模块扩展包
  sudo apt install -y linux-modules-extra-`uname -r`
  # 加载binder_linux模块
  sudo modprobe binder_linux devices="binder,hwbinder,vndbinder"

  # 开机自动加载 binder_linux 模块
  echo "binder_linux" | sudo tee /etc/modules-load.d/binder_linux.conf
  sudo tee /etc/modprobe.d/binder_linux.conf <<EOF
options binder_linux devices="binder,hwbinder,vndbinder"
EOF
}

# 安装redroid https://github.com/ERSTT/redroid/blob/main/README_CN.md
install_redroid() {
  if ! sudo docker ps -a --format '{{.Names}}' | grep -q "$REDROID_CONTAINER"; then
    sudo docker run -itd --privileged \
      -p "$REDROID_PORT:$REDROID_PORT" \
      --name "$REDROID_CONTAINER" \
      --restart=unless-stopped \
      kylindemons/redroid:15.0.0_amd64-GApps-latest
  else
    echo "$REDROID_CONTAINER 已安装"
    sudo docker start "$REDROID_CONTAINER"
  fi
}

# 安装ws-scrcpy
install_ws_scrcpy() {
  if ! sudo docker ps -a --format '{{.Names}}' | grep -q "$WS_SCRCPY_CONTAINER"; then
    # 手动打包ws-scrcpy镜像，docker仓库里面的太老了
    sudo docker build -t ws-scrcpy - << EOF
FROM node:18
MAINTAINER Scavin <scavin@appinn.com>

ENV LANG C.UTF-8
WORKDIR /ws-scrcpy

RUN npm install -g node-gyp
RUN apt update;apt install android-tools-adb -y
RUN git clone https://github.com/NetrisTV/ws-scrcpy.git .
RUN npm install
RUN npm run dist

EXPOSE 8000

CMD ["node","dist/index.js"]
EOF
    # 启动ws-scrcpy容器
    sudo docker run --name "$WS_SCRCPY_CONTAINER" --restart=unless-stopped -d -p 8000:8000 ws-scrcpy
  else
    echo "$WS_SCRCPY_CONTAINER 已安装"
    sudo docker start "$WS_SCRCPY_CONTAINER"
  fi
}

# 配置ws-scrcpy自动连接模拟器
configure_ws_scrcpy_auto_connect() {
  # 写入脚本，监听端口可用时ws-scrcpy自动连接adb
  sudo tee /usr/local/bin/adb_connect_docker.sh << 'EOF'
#!/bin/bash

CONTAINER_NAME="redroid"
CONTAINER_IP="$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$CONTAINER_NAME")"
ADB_PORT="5555"
MAX_RETRIES=3600

echo "$(date) - 等待容器 $CONTAINER_NAME 启动..."

# 等待容器运行
while true; do
  if docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null | grep -q true; then
    echo "$(date) - 容器已启动"
    break
  fi
  echo "$(date) - 容器未启动，继续等待..."
  sleep 2
done

# 重试 adb connect
ADB_TARGET="$CONTAINER_IP:$ADB_PORT"
for i in $(seq 1 $MAX_RETRIES); do
  echo "$(date) - 第 $i 次尝试连接 adb: $ADB_TARGET"
  docker exec ws-scrcpy adb connect "$ADB_TARGET"

  # 判断是否连接成功（可按需启用更严格检测）
  if docker exec ws-scrcpy adb devices | grep -q "$ADB_TARGET"; then
    echo "$(date) - 成功连接到 adb: $ADB_TARGET"
    docker exec ws-scrcpy adb -s "$ADB_TARGET" root
    exit 0
  fi

  echo "$(date) - 连接失败，等待重试..."
  sleep 3
done

echo "$(date) - 超过最大重试次数，连接失败"
exit 1
EOF

  sudo chmod +x /usr/local/bin/adb_connect_docker.sh

  # 创建 systemd 服务文件
  sudo tee /etc/systemd/system/adb_connect_docker.service << 'EOF'
[Unit]
Description=等待Docker容器启动并让ws-scrcpy自动连接adb设备
After=docker.service
Requires=docker.service

[Service]
ExecStart=/usr/local/bin/adb_connect_docker.sh
Restart=on-failure
Environment=PATH=/usr/bin:/usr/local/bin

[Install]
WantedBy=multi-user.target
EOF

  sudo systemctl daemon-reload
  sudo systemctl enable adb_connect_docker.service
  sudo systemctl start adb_connect_docker.service
}

# 模拟器伪装机型
disguise_emu_device() {
  local -A PROPS=(
    [ro.product.model]="Pixel 5"
    [ro.product.brand]="google"
    [ro.product.manufacturer]="Google"
    [ro.build.fingerprint]="google/redfin/redfin:11/RQ3A.210805.001.A1/7474174:user/release-keys"
  )
  for key in "${!PROPS[@]}"; do
    val="${PROPS[$key]}"
    echo "🔧 设置 $key = $val"

    sudo docker exec "$REDROID_CONTAINER" sh -c "
      if grep -q '^$key=' /system/build.prop; then
        sed -i 's|^$key=.*|$key=$val|' /system/build.prop
      else
        echo '$key=$val' >> /system/build.prop
      fi
    "
  done
}

configure_gapps_to_emu() {
  cd /tmp
  if [ -d "gapps" ] && [ "$(ls -A gapps)" ]; then
    echo "gapps 目录已存在且非空，不需要重新下载解压。"
  else
    echo "开始下载 gapps.zip ..."
    curl -L -o gapps.zip https://github.com/hhoy/redroid/releases/download/v1.0.0/gapps.zip
    echo "下载完成，开始解压..."
    unzip -q gapps.zip -d gapps
    echo "解压完成。"
  fi

  # 伪装机型
  disguise_emu_device

  sudo docker exec "$REDROID_CONTAINER" rm -rf /system/priv-app/PackageInstaller
  sudo docker cp gapps/. "$REDROID_CONTAINER:/"
  sudo docker exec "$REDROID_CONTAINER" pm grant com.google.android.gms android.permission.ACCESS_COARSE_LOCATION
  sudo docker exec "$REDROID_CONTAINER" pm grant com.google.android.gms android.permission.ACCESS_FINE_LOCATION
  sudo docker exec "$REDROID_CONTAINER" pm grant com.google.android.setupwizard android.permission.READ_PHONE_STATE
  sudo docker exec "$REDROID_CONTAINER" pm grant com.google.android.setupwizard android.permission.READ_CONTACTS
  
  sudo docker restart "$REDROID_CONTAINER"
  rm -rf gapps
}

install_docker
install_binder_linux
install_redroid
install_ws_scrcpy
configure_ws_scrcpy_auto_connect
echo "redroid安卓模拟器部署完成"

# 这里用redroid-14-gms来部署模拟器，就不用自己添加gapps了
# echo "🛠️ 开始配置OpenGApps到模拟器"
# configure_gapps_to_emu

serverIp=$(curl -s ifconfig.me)
echo "浏览器打开'$serverIp:8000'查看设备列表"
# echo "使用scrcpy -s '$serverIp:5555'连接远程模拟器"
echo "如果打不开请联系运维开放对应端口"

