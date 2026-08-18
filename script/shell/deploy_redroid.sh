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
# 脚本自身版本，仅用于日志和排查，不影响 Redroid 或 Android 版本。
SCRIPT_VERSION="2026.08.18.14"

# Redroid 的 Docker 容器名；部署、正常关机和 ADB 连接都会使用该名称。
REDROID_CONTAINER="${REDROID_CONTAINER:-redroid}"
# ws-scrcpy 的 Docker 容器名；浏览器远程控制服务使用该容器。
WS_SCRCPY_CONTAINER="${WS_SCRCPY_CONTAINER:-ws-scrcpy}"
# 两个容器共用的 Docker 网络；ws-scrcpy 通过容器名连接 Redroid。
ANDROID_NETWORK="${ANDROID_NETWORK:-android-control}"
# 宿主机本地 ADB 端口；只绑定 127.0.0.1，不直接暴露到公网。
REDROID_ADB_PORT="${REDROID_ADB_PORT:-5555}"
# Android /data 的宿主机持久化目录；重建容器时应用和设置保存在这里。
# 已经部署后不要随意更换，否则新容器会看到另一套空数据。
REDROID_DATA_DIR="${REDROID_DATA_DIR:-/var/lib/redroid/data}"
# Redroid 镜像。固定摘要，避免 latest 在重建容器时静默切换内容。
REDROID_IMAGE="${REDROID_IMAGE:-darknightlab/redroid-14-gms@sha256:d6e052064341c5b025a75471b011df31e9a5d76adb8b8cbba97f58e598f108fa}"
# ws-scrcpy 源码版本；可用 master，或使用完整 40 位 Commit 固定版本。
WS_SCRCPY_REF="${WS_SCRCPY_REF:-master}"
# 设为 1 表示接受 Redroid 使用 latest 等浮动标签，仅关闭风险提示。
# 该参数不会改变镜像内容，也不会自动固定镜像版本。
ALLOW_MUTABLE_IMAGE="${ALLOW_MUTABLE_IMAGE:-0}"
# 等待 Android 完成启动的最大检查次数；每次检查之间等待 5 秒。
BOOT_ATTEMPTS="${BOOT_ATTEMPTS:-36}"
# ws-scrcpy 连接 Redroid ADB 的最大重试次数。
ADB_ATTEMPTS="${ADB_ATTEMPTS:-60}"
# 宿主机 Binder 检查与修复脚本；缺少模块时安装当前内核对应的软件包。
BINDER_SETUP_PATH="${BINDER_SETUP_PATH:-/usr/local/libexec/binder-linux-setup}"
# Redroid 正常关机脚本；优先请求 Android 自己关机，超时后才由 Docker 停止。
REDROID_STOP_PATH="${REDROID_STOP_PATH:-/usr/local/libexec/redroid-stop}"
# 开机检查、安装并加载 Binder 模块的 systemd 服务名。
BINDER_SERVICE_NAME="${BINDER_SERVICE_NAME:-binder-linux-setup.service}"

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
    ca-certificates curl git iproute2 kmod
  # 这里只启用服务。Binder 检查通过前不主动启动 Docker，避免已有
  # restart 容器抢先启动 Redroid。
  systemctl enable docker
}

# BinderFS 注册且传统设备或 BinderFS 设备完整存在，才允许执行 Android /init。
binder_is_ready() {
  grep -qE '^[[:space:]]*nodev[[:space:]]+binder$' /proc/filesystems || return 1
  if [[ -c /dev/binder && -c /dev/hwbinder && -c /dev/vndbinder ]]; then
    return 0
  fi
  [[ -c /dev/binderfs/binder ]] \
    && [[ -c /dev/binderfs/hwbinder ]] \
    && [[ -c /dev/binderfs/vndbinder ]]
}

# 新内核可能只通过 BinderFS 创建设备，不再在 /dev 根目录生成传统节点。
ensure_binder_devices() {
  if [[ -c /dev/binder && -c /dev/hwbinder && -c /dev/vndbinder ]]; then
    return
  fi
  install -d -m 0755 /dev/binderfs
  mountpoint -q /dev/binderfs || mount -t binder binder /dev/binderfs
}

# BinderFS 新建设备默认为 0600，Android 的 system 用户无法访问。
set_binder_device_permissions() {
  local device
  for device in \
    /dev/binder /dev/hwbinder /dev/vndbinder \
    /dev/binderfs/binder /dev/binderfs/hwbinder /dev/binderfs/vndbinder; do
    [[ -c "$device" ]] && chmod 0666 "$device"
  done
}

# Ubuntu 将部分内核驱动拆到与当前内核精确匹配的 modules-extra 包中。
# 其他发行版如果已经内置或提供 binder_linux，则不会进入此安装分支。
install_kernel_extra_meta_if_available() {
  local kernel_release kernel_flavor meta_package
  kernel_release="$(uname -r)"
  kernel_flavor="${kernel_release##*-}"
  meta_package="linux-modules-extra-${kernel_flavor}"
  if command -v apt-get >/dev/null 2>&1 \
    && apt-cache show "$meta_package" >/dev/null 2>&1; then
    apt-get install -y --no-install-recommends "$meta_package"
  else
    log "未发现可用的内核扩展元包 ${meta_package}；后续内核升级由启动保护兜底"
  fi
}

install_current_kernel_binder_package() {
  local kernel_release exact_package
  kernel_release="$(uname -r)"
  exact_package="linux-modules-extra-${kernel_release}"

  command -v apt-get >/dev/null 2>&1 \
    || die "当前内核缺少 binder_linux，请为 ${kernel_release} 安装对应 Binder 模块"
  apt-get update
  apt-cache show "$exact_package" >/dev/null 2>&1 \
    || die "软件源中不存在 ${exact_package}，请为当前内核安装 Binder 模块"
  apt-get install -y --no-install-recommends "$exact_package"
}

# 安装并加载 binder_linux。即使未来内核缺少模块，Docker 仍可启动；
# Redroid 的独立服务会修复 Binder，直接 docker start 则会因缺少映射设备而失败。
install_binder_linux() {
  # 旧脚本曾让整个 Docker 依赖 modules-load；先解除该耦合，避免 Binder
  # 修复失败时连带阻止打包容器启动。
  rm -f /etc/systemd/system/docker.service.d/binder.conf
  rmdir /etc/systemd/system/docker.service.d >/dev/null 2>&1 || true
  systemctl daemon-reload

  install -d -m 0755 /etc/modules-load.d /etc/modprobe.d
  rm -f /etc/modules-load.d/redroid-binder.conf
  printf 'options binder_linux devices="binder,hwbinder,vndbinder"\n' \
    >/etc/modprobe.d/binder_linux.conf
  printf 'binder_linux\n' >/etc/modules-load.d/binder-linux.conf

  if ! modprobe binder_linux >/dev/null 2>&1; then
    install_current_kernel_binder_package
    depmod -a "$(uname -r)"
    modprobe binder_linux
  fi

  ensure_binder_devices
  set_binder_device_permissions
  # udev 创建设备可能稍有延迟。
  for _ in {1..10}; do
    binder_is_ready && break
    sleep 0.5
  done
  binder_is_ready \
    || die "Binder 未就绪：请检查 /dev/binder 或 /dev/binderfs 下的三个 Binder 设备"
  install_kernel_extra_meta_if_available

}

# 在修改系统和容器前验证参数，避免部署到一半才发现配置无效。
validate_inputs() {
  [[ "$REDROID_CONTAINER" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$ ]] \
    || die "REDROID_CONTAINER 不是有效的 Docker 容器名"
  [[ "$WS_SCRCPY_CONTAINER" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$ ]] \
    || die "WS_SCRCPY_CONTAINER 不是有效的 Docker 容器名"
  [[ "$ANDROID_NETWORK" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$ ]] \
    || die "ANDROID_NETWORK 不是有效的 Docker 网络名"
  [[ "$BINDER_SERVICE_NAME" =~ ^[A-Za-z0-9_.@-]+\.service$ ]] \
    || die "BINDER_SERVICE_NAME 不是有效的 systemd 服务名"
  [[ "$BINDER_SETUP_PATH" == /* && "$REDROID_STOP_PATH" == /* ]] \
    || die "Binder 修复和 Redroid 停止脚本路径必须是绝对路径"
  [[ "$BOOT_ATTEMPTS" =~ ^[1-9][0-9]*$ ]] \
    || die "BOOT_ATTEMPTS 必须是正整数"
  [[ "$ADB_ATTEMPTS" =~ ^[1-9][0-9]*$ ]] \
    || die "ADB_ATTEMPTS 必须是正整数"
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

# 宿主机修复脚本供 systemd 使用：先检查，缺失时安装当前内核模块，
# 最后加载 binder_linux 并验证实际设备。
install_binder_setup_script() {
  install -d -m 0755 "$(dirname "$BINDER_SETUP_PATH")"

  cat >"$BINDER_SETUP_PATH" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

binder_is_ready() {
  grep -qE '^[[:space:]]*nodev[[:space:]]+binder$' /proc/filesystems || return 1
  if test -c /dev/binder && test -c /dev/hwbinder && test -c /dev/vndbinder; then
    return 0
  fi
  test -c /dev/binderfs/binder \
    && test -c /dev/binderfs/hwbinder \
    && test -c /dev/binderfs/vndbinder
}

ensure_binder_devices() {
  if test -c /dev/binder && test -c /dev/hwbinder && test -c /dev/vndbinder; then
    return
  fi
  install -d -m 0755 /dev/binderfs
  mountpoint -q /dev/binderfs || mount -t binder binder /dev/binderfs
}

set_binder_device_permissions() {
  for device in \
    /dev/binder /dev/hwbinder /dev/vndbinder \
    /dev/binderfs/binder /dev/binderfs/hwbinder /dev/binderfs/vndbinder; do
    test -c "$device" && chmod 0666 "$device"
  done
}

if binder_is_ready; then
  set_binder_device_permissions
  exit 0
fi

install -d -m 0755 /etc/modules-load.d /etc/modprobe.d
rm -f /etc/modules-load.d/redroid-binder.conf
printf 'options binder_linux devices="binder,hwbinder,vndbinder"\n' \
  >/etc/modprobe.d/binder_linux.conf
printf 'binder_linux\n' >/etc/modules-load.d/binder-linux.conf

if ! modprobe binder_linux >/dev/null 2>&1; then
  kernel_release="$(uname -r)"
  package="linux-modules-extra-${kernel_release}"
  command -v apt-get >/dev/null 2>&1 \
    || { echo "Binder 修复失败：系统没有 apt-get，请为 ${kernel_release} 安装 binder_linux" >&2; exit 1; }

  echo "当前内核缺少 binder_linux，正在安装 ${package}"
  apt-get -o DPkg::Lock::Timeout=120 update
  apt-cache show "$package" >/dev/null 2>&1 \
    || { echo "Binder 修复失败：软件源中不存在 ${package}" >&2; exit 1; }
  apt-get -o DPkg::Lock::Timeout=120 install -y --no-install-recommends "$package"
  depmod -a "$kernel_release"
  modprobe binder_linux
fi

ensure_binder_devices
set_binder_device_permissions
for _ in {1..10}; do
  binder_is_ready && exit 0
  sleep 0.5
done

grep -qE '^[[:space:]]*nodev[[:space:]]+binder$' /proc/filesystems \
  || { echo "Binder 修复失败：BinderFS 未注册" >&2; exit 1; }
binder_is_ready \
  || { echo "Binder 修复失败：/dev/binder 和 /dev/binderfs 中都没有完整设备" >&2; exit 1; }
EOF
  chmod 0755 "$BINDER_SETUP_PATH"
}

install_redroid_stop_script() {
  install -d -m 0755 "$(dirname "$REDROID_STOP_PATH")"
  cat >"$REDROID_STOP_PATH" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

container="${1:?缺少 Redroid 容器名}"
[[ "$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null || true)" == "true" ]] \
  || exit 0

# Android init 处理 sys.powerctl 后会自行退出；正常关机实测退出码为 130。
docker exec "$container" setprop sys.powerctl shutdown >/dev/null 2>&1 || true
for _ in {1..30}; do
  [[ "$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null || true)" != "true" ]] \
    && exit 0
  sleep 1
done

docker stop --timeout 10 "$container" >/dev/null
EOF
  chmod 0755 "$REDROID_STOP_PATH"
}

create_redroid_container() {
  local image="$1"
  local data_dir="$2"
  local binder_device_dir="/dev"
  if [[ ! -c /dev/binder || ! -c /dev/hwbinder || ! -c /dev/vndbinder ]]; then
    binder_device_dir="/dev/binderfs"
  fi
  [[ -c "$binder_device_dir/binder" \
    && -c "$binder_device_dir/hwbinder" \
    && -c "$binder_device_dir/vndbinder" ]] \
    || die "创建 Redroid 失败：宿主机 Binder 设备不完整"
  docker create \
    --name "$REDROID_CONTAINER" \
    --hostname "$REDROID_CONTAINER" \
    --privileged \
    --restart unless-stopped \
    --network "$ANDROID_NETWORK" \
    -p "127.0.0.1:${REDROID_ADB_PORT}:5555" \
    --mount "type=bind,src=$binder_device_dir/binder,dst=/dev/binder" \
    --mount "type=bind,src=$binder_device_dir/hwbinder,dst=/dev/hwbinder" \
    --mount "type=bind,src=$binder_device_dir/vndbinder,dst=/dev/vndbinder" \
    -v "$data_dir:/data" \
    "$image" >/dev/null
}

# 安装redroid https://github.com/ERSTT/redroid/blob/main/README_CN.md
install_redroid() {
  if container_exists "$REDROID_CONTAINER"; then
    log "停止并删除现有 $REDROID_CONTAINER 容器；宿主机 Android 数据目录保持不变"
    "$REDROID_STOP_PATH" "$REDROID_CONTAINER" || true
    docker rm -f "$REDROID_CONTAINER" >/dev/null
  fi

  # /data 保存在宿主机，重建容器不会删除该目录中的应用和设置。
  install -d -m 0755 "$REDROID_DATA_DIR"
  docker pull "$REDROID_IMAGE"
  create_redroid_container "$REDROID_IMAGE" "$REDROID_DATA_DIR"
}

# Binder 服务只负责宿主机模块的检查、安装和加载。Docker 弱依赖该服务：
# 会等待检查结束，但 Binder 修复失败不会阻止 Docker 和打包容器启动。
configure_binder_startup() {
  cat >"/etc/systemd/system/$BINDER_SERVICE_NAME" <<EOF
[Unit]
Description=Ensure Linux Binder kernel module and devices
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=$BINDER_SETUP_PATH
RemainAfterExit=yes
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
EOF

  install -d -m 0755 /etc/systemd/system/docker.service.d
  cat >/etc/systemd/system/docker.service.d/binder-linux-setup.conf <<EOF
[Unit]
Wants=$BINDER_SERVICE_NAME
After=$BINDER_SERVICE_NAME
EOF

  systemctl daemon-reload
  systemctl enable "$BINDER_SERVICE_NAME"
  systemctl restart "$BINDER_SERVICE_NAME"
  docker update --restart=unless-stopped "$REDROID_CONTAINER" >/dev/null
  docker start "$REDROID_CONTAINER" >/dev/null
}

# darknightlab/redroid-14-gms 的 Google APK 被打包为 0777。Android 14
# 会拒绝加载当前进程可写的 dex，因此必须在首次启动后修正容器可写层。
fix_redroid_gms_apk_permissions() {
  local apk mode
  local changed=0
  local gms_apks=(
    /system/app/GoogleCalendarSyncAdapter/GoogleCalendarSyncAdapter.apk
    /system/app/GoogleContactsSyncAdapter/GoogleContactsSyncAdapter.apk
    /system/priv-app/GmsCore/GmsCore.apk
    /system/priv-app/GoogleServicesFramework/GoogleServicesFramework.apk
    /system/priv-app/Phonesky/Phonesky.apk
  )

  for apk in "${gms_apks[@]}"; do
    if ! docker exec "$REDROID_CONTAINER" test -f "$apk"; then
      log "警告：镜像中不存在预期的 GMS APK：$apk"
      continue
    fi

    mode="$(docker exec "$REDROID_CONTAINER" stat -c '%a' "$apk")"
    if [[ "$mode" != "644" && "$mode" != "0644" ]]; then
      log "修复 GMS APK 权限：$apk（$mode -> 644）"
      docker exec "$REDROID_CONTAINER" chmod 0644 "$apk"
      changed=1
    fi
  done

  if (( changed )); then
    log "GMS APK 权限已修复，重启 Redroid 使 Android 重新扫描系统应用"
    docker restart --time 30 "$REDROID_CONTAINER" >/dev/null
  else
    log "GMS APK 权限已符合 Android 14 要求"
  fi
}

wait_for_redroid_boot() {
  local i container_status exit_code
  log "等待 Redroid Android Framework 完成启动"
  for ((i=1; i<=BOOT_ATTEMPTS; i++)); do
    if container_running "$REDROID_CONTAINER" \
      && [[ "$(timeout 5s docker exec "$REDROID_CONTAINER" getprop sys.boot_completed 2>/dev/null || true)" == "1" ]]; then
      log "Redroid 已完成启动"
      return
    fi
    container_status="$(docker inspect -f '{{.State.Status}}' "$REDROID_CONTAINER" 2>/dev/null || true)"
    exit_code="$(docker inspect -f '{{.State.ExitCode}}' "$REDROID_CONTAINER" 2>/dev/null || true)"
    if [[ "$container_status" == "exited" ]]; then
      log "Redroid 容器已提前退出，退出码=${exit_code:-未知}"
      break
    fi
    sleep 5
  done

  "$REDROID_STOP_PATH" "$REDROID_CONTAINER" || true
  die "Redroid 未在限定时间内完成启动，已安全停止；请查看 docker logs $REDROID_CONTAINER"
}

# 手动打包ws-scrcpy镜像，Docker仓库里的版本通常较旧。
# 使用完整 Git Commit，避免每次构建得到不同的 master 内容。
build_ws_scrcpy() (
  local build_dir
  build_dir="$(mktemp -d "${TMPDIR:-/tmp}/ws-scrcpy-build.XXXXXX")"
  trap 'rm -rf "$build_dir"' EXIT

  cat >"$build_dir/Dockerfile" <<'EOF'
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
    "$build_dir"
)

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
  systemctl start docker
  install_binder_setup_script
  install_redroid_stop_script
  ensure_network
  install_redroid
  configure_binder_startup
  fix_redroid_gms_apk_permissions
  wait_for_redroid_boot
  install_ws_scrcpy
  configure_ws_scrcpy_auto_connect

  server_ip="$(detect_server_ip)"
  log "redroid安卓模拟器部署完成"
  log "浏览器打开 http://${server_ip}:8000"
  log "ADB 仅绑定本机：127.0.0.1:${REDROID_ADB_PORT}"
  log "如果打不开，请检查云安全组和主机防火墙是否开放 TCP 8000"
}

main "$@"
