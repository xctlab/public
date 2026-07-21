#!/usr/bin/env bash
set -Eeuo pipefail

# Redroid + ws-scrcpy 部署脚本
#
# 公网访问链路：
#   浏览器 :8000 -> ws-scrcpy
#
# ADB 访问链路：
#   ws-scrcpy -> Docker 内网 -> redroid:5555
#   本地客户端 -> SSH 隧道 -> 127.0.0.1:5555
#
SCRIPT_VERSION="2026.07.21.6"
REDROID_CONTAINER="${REDROID_CONTAINER:-redroid}"
WS_SCRCPY_CONTAINER="${WS_SCRCPY_CONTAINER:-ws-scrcpy}"
ANDROID_NETWORK="${ANDROID_NETWORK:-android-control}"
REDROID_ADB_PORT="${REDROID_ADB_PORT:-5555}"
REDROID_DATA_DIR="${REDROID_DATA_DIR:-/var/lib/redroid/data}"
WS_SCRCPY_BUILD_DIR="${WS_SCRCPY_BUILD_DIR:-/opt/ws-scrcpy-build}"
REDROID_IMAGE="${REDROID_IMAGE:-darknightlab/redroid-14-gms:latest}"
WS_SCRCPY_REF="${WS_SCRCPY_REF:-master}"
ALLOW_MUTABLE_IMAGE="${ALLOW_MUTABLE_IMAGE:-0}"
BOOT_ATTEMPTS="${BOOT_ATTEMPTS:-36}"
ADB_ATTEMPTS="${ADB_ATTEMPTS:-60}"

log() { printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
die() { log "错误：$*" >&2; exit 1; }

# 系统级安装和 systemd 配置需要 root。
# curl | bash 没有真实脚本路径，因此这里只检查权限，不通过 $0 重新执行。
if [[ ${EUID} -ne 0 ]]; then
  die "请使用 root 权限执行此脚本"
fi

on_error() {
  local exit_code=$?
  local line_number="$1"
  local failed_command="$2"
  trap - ERR
  die "第 ${line_number} 行执行失败，退出码=${exit_code}，命令：${failed_command}"
}

trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

# 精确判断容器是否存在，避免 grep 把 redroid-old 误认为 redroid。
container_exists() {
  docker container inspect "$1" >/dev/null 2>&1
}

container_running() {
  [[ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null || true)" == "true" ]]
}

# 通过多个独立服务依次查询公网 IPv4，不使用 hostname -I，避免误取内网/Docker 地址。
# IP 检测只影响最终提示，不应因为单个查询服务失败而中断部署。
detect_server_ip() {
  local endpoint server_ip
  local endpoints=(
    "https://api.ipify.org"
    "https://ifconfig.me/ip"
    "https://ipv4.icanhazip.com"
  )
  for endpoint in "${endpoints[@]}"; do
    server_ip="$(curl -4 -fsS --connect-timeout 3 --max-time 5 "$endpoint" 2>/dev/null | tr -d '[:space:]' || true)"
    if [[ "$server_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      printf '%s\n' "$server_ip"
      return
    fi
  done
  printf '%s\n' "<服务器公网IP>"
}

# 安装docker及部署所需工具。
# Docker 使用官方 get.docker.com 安装 Docker CE，不与 Ubuntu docker.io 混装。
# linux-modules-extra 必须与当前正在运行的内核版本完全一致。
install_docker() {
  export DEBIAN_FRONTEND=noninteractive
  if command -v docker >/dev/null 2>&1; then
    log "Docker 已安装，跳过官方安装脚本"
  else
    local docker_installer
    docker_installer="$(mktemp)"
    log "下载 Docker 官方安装脚本"
    curl -fsSL --retry 3 --connect-timeout 15 \
      https://get.docker.com \
      -o "$docker_installer"
    sh "$docker_installer"
    rm -f "$docker_installer"
  fi

  # Docker 准备完成后再安装本脚本的其他依赖，不安装 docker.io/containerd。
  apt-get update
  apt-get install -y --no-install-recommends \
    ca-certificates curl git iproute2 \
    "linux-modules-extra-$(uname -r)"
  systemctl enable --now docker
}

# 安装并加载binder_linux模块。
# 这是对“升级内核后 reboot，Redroid 因缺少 Binder 启动循环”的修复。
install_binder_linux() {
  # 新安装模块后重建 modules.dep，否则 modprobe 可能仍报告 Module not found。
  depmod -a "$(uname -r)"
  modprobe binder_linux

  # Redroid 使用 BinderFS。只看到模块文件还不够，文件系统必须真正注册。
  grep -qE '^[[:space:]]*nodev[[:space:]]+binder$' /proc/filesystems \
    || die "BinderFS 未注册，请检查当前内核的 linux-modules-extra 包"

  # 开机自动加载 Binder，并确保 Docker 恢复容器前模块已经加载完成。
  printf 'binder_linux\n' >/etc/modules-load.d/redroid-binder.conf
  mkdir -p /etc/systemd/system/docker.service.d
  cat >/etc/systemd/system/docker.service.d/binder.conf <<'EOF'
[Unit]
After=systemd-modules-load.service
Requires=systemd-modules-load.service
EOF
  systemctl daemon-reload
}

# 在修改系统和容器前验证参数，避免部署到一半才发现配置无效。
validate_inputs() {
  [[ "$REDROID_ADB_PORT" =~ ^[0-9]+$ ]] && (( REDROID_ADB_PORT >= 1 && REDROID_ADB_PORT <= 65535 )) \
    || die "REDROID_ADB_PORT 必须是 1-65535"
  # 默认保持原脚本行为，构建 ws-scrcpy 的 master；也可传完整 Commit 固定版本。
  if ! container_exists "$WS_SCRCPY_CONTAINER"; then
    [[ "$WS_SCRCPY_REF" == "master" || "$WS_SCRCPY_REF" =~ ^[0-9a-fA-F]{40}$ ]] \
      || die "WS_SCRCPY_REF 必须是 master 或完整的 40 位 Git Commit"
  fi

  # 保持原脚本的开箱即用行为；使用浮动 tag 时提示风险但不阻断部署。
  if ! container_exists "$REDROID_CONTAINER" \
    && [[ "$ALLOW_MUTABLE_IMAGE" != "1" && "$REDROID_IMAGE" != *@sha256:* ]]; then
    log "警告：REDROID_IMAGE 未固定 sha256，镜像 tag 后续可能变化：$REDROID_IMAGE"
  fi
}

# 用户自定义网络带有 Docker DNS，容器可用 redroid 名称互相访问。
# 这避免容器重建后 172.17.0.x 地址改变导致 ADB 连接失败。
network_bridge_name() {
  local network_id configured_name
  network_id="$(docker network inspect -f '{{.Id}}' "$ANDROID_NETWORK")"
  configured_name="$(docker network inspect -f '{{index .Options "com.docker.network.bridge.name"}}' "$ANDROID_NETWORK" 2>/dev/null || true)"
  [[ "$configured_name" == "<no value>" ]] && configured_name=""
  printf '%s\n' "${configured_name:-br-${network_id:0:12}}"
}

# Docker 网络元数据存在并不代表 bridge 创建成功；同时验证接口和网关地址。
network_is_healthy() {
  docker network inspect "$ANDROID_NETWORK" >/dev/null 2>&1 || return 1
  local bridge gateway
  bridge="$(network_bridge_name)"
  gateway="$(docker network inspect -f '{{(index .IPAM.Config 0).Gateway}}' "$ANDROID_NETWORK")"
  ip link show "$bridge" >/dev/null 2>&1 || return 1
  ip -4 address show dev "$bridge" | grep -Fq "${gateway}/" || return 1
}

# 只允许自动重建本脚本专用的网络。若发现其他业务容器，停止并要求人工确认。
recreate_android_network() {
  local container attached_containers
  attached_containers="$(docker network inspect -f '{{range .Containers}}{{println .Name}}{{end}}' "$ANDROID_NETWORK" 2>/dev/null || true)"
  while IFS= read -r container; do
    [[ -z "$container" ]] && continue
    if [[ "$container" != "$REDROID_CONTAINER" && "$container" != "$WS_SCRCPY_CONTAINER" ]]; then
      die "网络 $ANDROID_NETWORK 还连接了其他容器 $container，拒绝自动重建"
    fi
  done <<<"$attached_containers"

  log "Docker 网络 $ANDROID_NETWORK 的 bridge 或网关异常，正在安全重建"
  for container in "$REDROID_CONTAINER" "$WS_SCRCPY_CONTAINER"; do
    if container_exists "$container"; then
      docker network disconnect -f "$ANDROID_NETWORK" "$container" >/dev/null 2>&1 || true
      # 半创建网络可能只写入容器配置却未登记 endpoint；删除网络前确认引用已清除。
      if docker inspect -f '{{json .NetworkSettings.Networks}}' "$container" | grep -q "\"$ANDROID_NETWORK\""; then
        die "$container 仍引用异常网络 $ANDROID_NETWORK，拒绝删除网络以免留下失效 NetworkID"
      fi
    fi
  done
  docker network rm "$ANDROID_NETWORK" >/dev/null 2>&1 || true
  docker network create --driver bridge "$ANDROID_NETWORK" >/dev/null

  # Docker 创建 bridge 可能有短暂延迟，最多等待 5 秒。
  for _ in {1..10}; do
    network_is_healthy && break
    sleep 0.5
  done
  network_is_healthy || die "Docker 网络 $ANDROID_NETWORK 重建后仍缺少 bridge 或网关路由"

  for container in "$REDROID_CONTAINER" "$WS_SCRCPY_CONTAINER"; do
    if container_exists "$container"; then
      connect_network "$container"
    fi
  done
}

ensure_network() {
  if ! docker network inspect "$ANDROID_NETWORK" >/dev/null 2>&1; then
    docker network create --driver bridge "$ANDROID_NETWORK" >/dev/null
  fi
  network_is_healthy || recreate_android_network
}

connect_network() {
  local container="$1"
  local actual_network_id container_network_id
  actual_network_id="$(docker network inspect -f '{{.Id}}' "$ANDROID_NETWORK")"
  container_network_id="$(docker inspect -f "{{with index .NetworkSettings.Networks \"$ANDROID_NETWORK\"}}{{.NetworkID}}{{end}}" "$container")"

  if [[ "$container_network_id" == "$actual_network_id" ]]; then
    return
  fi

  # 名称相同但 ID 不同，说明容器仍引用已经删除的旧网络。
  if [[ -n "$container_network_id" ]]; then
    log "$container 引用了失效网络 $container_network_id，尝试清理"
    docker network disconnect -f "$ANDROID_NETWORK" "$container" >/dev/null 2>&1 || true
    container_network_id="$(docker inspect -f "{{with index .NetworkSettings.Networks \"$ANDROID_NETWORK\"}}{{.NetworkID}}{{end}}" "$container")"
    [[ -z "$container_network_id" ]] \
      || die "$container 的失效网络引用无法由 Docker 清理；请先按提示备份并重建该容器"
  fi

  if ! docker network connect "$ANDROID_NETWORK" "$container"; then
    # 连接失败时重新检查一次，修复 Docker 的半创建网络后再连接。
    recreate_android_network
    docker inspect -f '{{json .NetworkSettings.Networks}}' "$container" | grep -q "\"$ANDROID_NETWORK\"" \
      || docker network connect "$ANDROID_NETWORK" "$container"
  fi
}

# 安装redroid https://github.com/ERSTT/redroid/blob/main/README_CN.md
install_redroid() {
  if container_exists "$REDROID_CONTAINER"; then
    log "$REDROID_CONTAINER 已存在，保留容器和数据"
    connect_network "$REDROID_CONTAINER"

    # Binder 在容器启动时挂载。模块刚恢复时必须重启容器，不能只 docker start。
    if container_running "$REDROID_CONTAINER"; then
      log "重启 $REDROID_CONTAINER，使 Binder 初始化重新执行"
      docker restart --time 30 "$REDROID_CONTAINER" >/dev/null
    else
      docker start "$REDROID_CONTAINER" >/dev/null
    fi

    # 不自动迁移旧容器数据，避免错误复制或删除用户现有 Android 数据。
    if [[ "$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/data"}}yes{{end}}{{end}}' "$REDROID_CONTAINER")" != "yes" ]]; then
      log "警告：现有容器的 /data 未持久化；重建容器会丢失 Android 数据"
    fi
    return
  fi

  # 新部署将 /data 保存到宿主机，容器重建后应用和设置仍然保留。
  install -d -m 0755 "$REDROID_DATA_DIR"
  docker pull "$REDROID_IMAGE"
  docker run -d \
    --name "$REDROID_CONTAINER" \
    --hostname "$REDROID_CONTAINER" \
    --privileged \
    --restart unless-stopped \
    --network "$ANDROID_NETWORK" \
    -p "127.0.0.1:${REDROID_ADB_PORT}:5555" \
    -v "$REDROID_DATA_DIR:/data" \
    "$REDROID_IMAGE" >/dev/null
}

# 手动打包ws-scrcpy镜像，Docker仓库里的版本通常较旧。
# 使用完整 Git Commit，避免每次构建得到不同的 master 内容。
build_ws_scrcpy() {
  install -d -m 0755 "$WS_SCRCPY_BUILD_DIR"
  cat >"$WS_SCRCPY_BUILD_DIR/Dockerfile" <<'EOF'
FROM node:18-bookworm
ARG WS_SCRCPY_REF
RUN apt-get update \
 && apt-get install -y --no-install-recommends android-tools-adb git python3 make g++ \
 && rm -rf /var/lib/apt/lists/*
RUN npm install -g node-gyp
WORKDIR /opt/ws-scrcpy
RUN git clone https://github.com/NetrisTV/ws-scrcpy.git . \
 && git checkout --detach "$WS_SCRCPY_REF"
RUN npm install
RUN npm run dist
RUN npm cache clean --force && rm -rf .git
EXPOSE 8000
CMD ["node", "dist/index.js"]
EOF

  docker build --pull --progress=plain \
    --build-arg "WS_SCRCPY_REF=$WS_SCRCPY_REF" \
    -t "ws-scrcpy:${WS_SCRCPY_REF}" \
    "$WS_SCRCPY_BUILD_DIR"
}

# 安装ws-scrcpy，直接将容器 8000 映射到公网固定端口 8000。
install_ws_scrcpy() {
  if container_exists "$WS_SCRCPY_CONTAINER"; then
    local expected_binding="0.0.0.0:8000"
    if docker port "$WS_SCRCPY_CONTAINER" 8000/tcp 2>/dev/null | grep -Fxq "$expected_binding"; then
      log "$WS_SCRCPY_CONTAINER 已使用本机后端端口"
      connect_network "$WS_SCRCPY_CONTAINER"
      docker start "$WS_SCRCPY_CONTAINER" >/dev/null || true
      return
    fi

    # ws-scrcpy 本身无状态。若用户额外挂载了数据则拒绝自动删除。
    [[ "$(docker inspect -f '{{len .Mounts}}' "$WS_SCRCPY_CONTAINER")" == "0" ]] \
      || die "$WS_SCRCPY_CONTAINER 使用了数据挂载，无法自动重建端口绑定"
    local current_image
    current_image="$(docker inspect -f '{{.Config.Image}}' "$WS_SCRCPY_CONTAINER")"
    log "停止旧 ws-scrcpy，并迁移到公网 8000 端口"
    docker rm -f "$WS_SCRCPY_CONTAINER" >/dev/null
    docker run -d \
      --name "$WS_SCRCPY_CONTAINER" \
      --hostname "$WS_SCRCPY_CONTAINER" \
      --restart unless-stopped \
      --network "$ANDROID_NETWORK" \
      -p "8000:8000" \
      "$current_image" >/dev/null
    return
  fi

  build_ws_scrcpy
  docker run -d \
    --name "$WS_SCRCPY_CONTAINER" \
    --hostname "$WS_SCRCPY_CONTAINER" \
    --restart unless-stopped \
    --network "$ANDROID_NETWORK" \
    -p "8000:8000" \
    "ws-scrcpy:${WS_SCRCPY_REF}" >/dev/null
}

# 配置ws-scrcpy自动连接模拟器。
# 先等待 sys.boot_completed=1，不能只根据 Docker 容器显示 Up 判断 Android 可用。
configure_ws_scrcpy_auto_connect() {
  # 写入实际执行 ADB 连接的脚本。
  cat >/usr/local/bin/redroid-adb-connect <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
REDROID_CONTAINER="$REDROID_CONTAINER"
WS_SCRCPY_CONTAINER="$WS_SCRCPY_CONTAINER"
ADB_TARGET="$REDROID_CONTAINER:5555"
BOOT_ATTEMPTS="$BOOT_ATTEMPTS"
ADB_ATTEMPTS="$ADB_ATTEMPTS"

log() { printf '%s %s\\n' "\$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "\$*"; }

# 等待 Redroid 容器运行且 Android Framework 完成启动。
for ((i=1; i<=BOOT_ATTEMPTS; i++)); do
  if [[ "\$(docker inspect -f '{{.State.Running}}' "\$REDROID_CONTAINER" 2>/dev/null || true)" == "true" ]] \
    && [[ "\$(timeout 5s docker exec "\$REDROID_CONTAINER" getprop sys.boot_completed 2>/dev/null || true)" == "1" ]]; then
    log "Redroid 已完成启动"
    break
  fi
  (( i == BOOT_ATTEMPTS )) && { log "Redroid 未在限定时间内完成启动"; exit 1; }
  sleep 5
done

# 使用 Docker DNS 名称连接，不使用会变化的容器 IP。
docker start "\$WS_SCRCPY_CONTAINER" >/dev/null || true
for ((i=1; i<=ADB_ATTEMPTS; i++)); do
  log "第 \$i 次连接 \$ADB_TARGET"
  timeout 15s docker exec "\$WS_SCRCPY_CONTAINER" adb connect "\$ADB_TARGET" || true

  # adb devices 中只有状态为 device 才算成功，offline/unauthorized 均继续重试。
  if timeout 10s docker exec "\$WS_SCRCPY_CONTAINER" adb devices \
    | awk -v target="\$ADB_TARGET" '\$1 == target && \$2 == "device" { found=1 } END { exit !found }'; then
    log "ADB 已连接：\$ADB_TARGET"
    exit 0
  fi
  sleep 3
done

log "ADB 在限定次数内未连接成功"
exit 1
EOF
  chmod 0755 /usr/local/bin/redroid-adb-connect

  # 创建 systemd 服务。失败时有限重试，避免原脚本连续重试三小时刷日志。
  cat >/etc/systemd/system/redroid-adb-connect.service <<EOF
[Unit]
Description=Connect ws-scrcpy to Redroid after Android boots
After=docker.service network-online.target
Requires=docker.service
Wants=network-online.target
StartLimitIntervalSec=1800
StartLimitBurst=5

[Service]
Type=oneshot
ExecStart=/usr/local/bin/redroid-adb-connect
Restart=on-failure
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  # oneshot 服务内部可能等待 Android/ADB 数分钟；后台启动，避免部署脚本看起来卡住。
  systemctl enable redroid-adb-connect.service
  systemctl restart --no-block redroid-adb-connect.service
  log "ADB 自动连接已在后台启动；查看进度：journalctl -fu redroid-adb-connect.service"
}

main() {
  local server_ip
  log "deploy_redroid_ws_scrcpy 版本：$SCRIPT_VERSION"
  validate_inputs
  install_docker
  install_binder_linux
  ensure_network
  install_redroid
  install_ws_scrcpy
  configure_ws_scrcpy_auto_connect

  server_ip="$(detect_server_ip)"
  log "redroid安卓模拟器部署完成"
  log "浏览器打开 http://${server_ip}:8000"
  log "ADB 仅绑定本机：127.0.0.1:${REDROID_ADB_PORT}"
  log "如果打不开，请检查云安全组和主机防火墙是否开放 TCP 8000"
}

main "$@"
