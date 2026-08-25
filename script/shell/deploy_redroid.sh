#!/usr/bin/env bash
set -Eeuo pipefail

# Redroid + ws-scrcpy 多版本部署脚本
#
# 公网访问链路：
#   浏览器 :8000 -> ws-scrcpy
#
# ADB 访问链路：
#   ws-scrcpy -> Docker 内网 -> redroid-apiXX:5555
#   本地客户端 -> SSH 隧道 -> 127.0.0.1:15500+API Level
#
# 脚本自身版本，仅用于日志和排查，不影响 Redroid 或 Android 版本。
SCRIPT_VERSION="2026.08.25.1"

# 唯一部署参数是规范容器名。不传参数时显示交互菜单。
REDROID_CONTAINER="${1:-}"

# 以下均为脚本内部配置，不作为安装参数暴露。
WS_SCRCPY_CONTAINER="ws-scrcpy"
ANDROID_NETWORK="android-control"
WS_SCRCPY_REF="master"
WS_SCRCPY_PORT="8000"
BOOT_ATTEMPTS="60"
ADB_ATTEMPTS="60"
BINDER_SETUP_PATH="/usr/local/libexec/binder-linux-setup"
REDROID_STOP_PATH="/usr/local/libexec/redroid-stop"
BINDER_SERVICE_NAME="binder-linux-setup.service"
INSTANCE_REGISTRY_DIR="/etc/redroid/instances.d"
GAPPS_BUILD_CONTEXT="https://github.com/xctlab/public.git#main:script/redroid-gapps"

ANDROID_VERSION=""
SDK_VERSION=""
REDROID_DATA_DIR=""
REDROID_IMAGE=""
REDROID_BASE_IMAGE=""
REDROID_ADB_PORT=""
IMAGE_HAS_GMS="0"
GAPPS_FLAVOR="none"
GAPPS_URL=""
GAPPS_SHA256=""
GAPPS_SOURCE=""
GAPPS_GRANT_DEVICE_CONFIG="1"
OVERLAY_REQUIRED="1"

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

# Redroid 的 privileged 容器会建立自己的 Binder 设备；宿主机只需注册 BinderFS。
binder_is_ready() {
  grep -qE '^[[:space:]]*nodev[[:space:]]+binder$' /proc/filesystems
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

# 安装并加载 binder_linux。已经运行的实例不会因此重启。
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

  binder_is_ready \
    || die "Binder 未就绪：当前内核没有注册 BinderFS"
  install_kernel_extra_meta_if_available

}

# 无参数运行时从真实终端读取选择，兼容 curl | sudo bash 的调用方式。
choose_release_interactively() {
  local selection
  [[ -r /dev/tty ]] || die "无交互终端，请传入容器名，例如：$0 redroid-api35"
  cat >/dev/tty <<'EOF'
请选择要部署的 Android 系统：
  1) redroid-api27 / Android 8.1 / API 27 / GMS
  2) redroid-api30 / Android 11  / API 30 / GMS
  3) redroid-api31 / Android 12  / API 31 / AOSP
  4) redroid-api33 / Android 13  / API 33 / GMS
  5) redroid-api34 / Android 14  / API 34 / GMS
  6) redroid-api35 / Android 15  / API 35 / GMS
输入序号或容器名：
EOF
  read -r selection </dev/tty
  case "$selection" in
    1) REDROID_CONTAINER="redroid-api27" ;;
    2) REDROID_CONTAINER="redroid-api30" ;;
    3) REDROID_CONTAINER="redroid-api31" ;;
    4) REDROID_CONTAINER="redroid-api33" ;;
    5) REDROID_CONTAINER="redroid-api34" ;;
    6) REDROID_CONTAINER="redroid-api35" ;;
    redroid-api27|redroid-api30|redroid-api31|redroid-api33|redroid-api34|redroid-api35)
      REDROID_CONTAINER="$selection"
      ;;
    *) die "无效选择：$selection" ;;
  esac
}

# 根据规范容器名选择经过验证的系统版本、API Level 和固定镜像。
select_release() {
  (( $# <= 1 )) || die "只接受一个可选参数：规范容器名，例如 $0 redroid-api35"
  [[ -n "$REDROID_CONTAINER" ]] || choose_release_interactively

  case "$REDROID_CONTAINER" in
    redroid-api27)
      ANDROID_VERSION="8.1"
      SDK_VERSION="27"
      REDROID_BASE_IMAGE="redroid/redroid:8.1.0-latest@sha256:ad6fd8ec7d9cdbc6856e0f3bd51ed06ebdde3d76ecbc71e886ed4314c3e9bfda"
      REDROID_IMAGE="local/redroid-81-gms:2026.08.19"
      IMAGE_HAS_GMS="1"
      GAPPS_FLAVOR="archive"
      GAPPS_URL="https://downloads.sourceforge.net/project/litegapps/litegapps/x86_64/27/lite/v2.6/%5BAUTO%5DLiteGapps_x86_64_8.1_v2.6_official.zip"
      GAPPS_SHA256="3e4c79d46de31a3131745dbb9586f4d71a268f94bdf79829e7d95d4509b85f8b"
      GAPPS_SOURCE="litegapps-8.1-x86_64"
      GAPPS_GRANT_DEVICE_CONFIG="0"
      OVERLAY_REQUIRED="0"
      ;;
    redroid-api30)
      ANDROID_VERSION="11"
      SDK_VERSION="30"
      REDROID_BASE_IMAGE="redroid/redroid:11.0.0-latest@sha256:60b0810684be4578733a847be3314c50b70f73bc92405b5a627ebe9b633ebb5e"
      REDROID_IMAGE="local/redroid-11-gms:2026.08.19"
      IMAGE_HAS_GMS="1"
      GAPPS_FLAVOR="archive"
      GAPPS_URL="https://downloads.sourceforge.net/project/litegapps/litegapps/x86_64/30/lite/2024-10-12/AUTO-LiteGapps-x86_64-11.0-20241012-official.zip"
      GAPPS_SHA256="96f5d1f7c9f73a4f27658603e3c9e049c72f58ac777b0bae51a3658c648cbdf4"
      GAPPS_SOURCE="litegapps-11-x86_64"
      GAPPS_GRANT_DEVICE_CONFIG="0"
      OVERLAY_REQUIRED="0"
      ;;
    redroid-api31)
      ANDROID_VERSION="12"
      SDK_VERSION="31"
      REDROID_IMAGE="redroid/redroid:12.0.0-latest@sha256:52332b2d74f337982d5ac281a8020ec297fb1ea05cbdcdaaa9c19a2065ae1adc"
      ;;
    redroid-api33)
      ANDROID_VERSION="13"
      SDK_VERSION="33"
      REDROID_BASE_IMAGE="redroid/redroid:13.0.0-latest@sha256:41e5f0c1ff27a4a474c474e5595168cedf6c40fc5dd102c5617f48c80f511e9e"
      REDROID_IMAGE="local/redroid-13-gms:2026.08.19"
      IMAGE_HAS_GMS="1"
      GAPPS_FLAVOR="archive"
      GAPPS_URL="https://github.com/MindTheGapps/13.0.0-x86_64/releases/download/MindTheGapps-13.0.0-x86_64-20231025_201203/MindTheGapps-13.0.0-x86_64-20231025_201203.zip"
      GAPPS_SHA256="2076179bcb6f30e78853d52cf70a4bd1d27502c3852332195e5356816cddfdd9"
      GAPPS_SOURCE="mindthegapps-13-x86_64"
      ;;
    redroid-api34)
      ANDROID_VERSION="14"
      SDK_VERSION="34"
      REDROID_IMAGE="local/redroid-14-mtg:2026.08.19"
      IMAGE_HAS_GMS="1"
      GAPPS_FLAVOR="mindthegapps"
      ;;
    redroid-api35)
      ANDROID_VERSION="15"
      SDK_VERSION="35"
      REDROID_IMAGE="local/redroid-15-gms:2026.08.19"
      IMAGE_HAS_GMS="1"
      GAPPS_FLAVOR="litegapps"
      ;;
    redroid-android7|redroid-android70)
      die "Android 7 没有官方 Redroid 镜像；当前最早支持 redroid-api27"
      ;;
    redroid-android16)
      die "redroid-android16 暂不支持：官方 x86_64 镜像在无 GPU 主机上会因 SurfaceFlinger 软件渲染缺陷无法完成启动"
      ;;
    *)
      die "不支持容器名 $REDROID_CONTAINER；可选：redroid-api27、redroid-api30、redroid-api31、redroid-api33、redroid-api34、redroid-api35"
      ;;
  esac

  REDROID_DATA_DIR="/var/lib/redroid/instances/android${ANDROID_VERSION//./}/data"
  REDROID_ADB_PORT="$((15500 + SDK_VERSION))"
}

# 在修改系统和容器前验证内部配置，避免部署到一半才发现配置无效。
validate_inputs() {
  [[ "$REDROID_CONTAINER" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$ ]] \
    || die "REDROID_CONTAINER 不是有效的 Docker 容器名"
  [[ "$WS_SCRCPY_CONTAINER" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$ ]] \
    || die "WS_SCRCPY_CONTAINER 不是有效的 Docker 容器名"
  [[ "$ANDROID_NETWORK" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$ ]] \
    || die "ANDROID_NETWORK 不是有效的 Docker 网络名"
  [[ "$BINDER_SERVICE_NAME" =~ ^[A-Za-z0-9_.@-]+\.service$ ]] \
    || die "BINDER_SERVICE_NAME 不是有效的 systemd 服务名"
  [[ "$BINDER_SETUP_PATH" == /* && "$REDROID_STOP_PATH" == /* \
    && "$INSTANCE_REGISTRY_DIR" == /* ]] \
    || die "Binder、Redroid 停止脚本和实例注册目录必须是绝对路径"
  [[ "$BOOT_ATTEMPTS" =~ ^[1-9][0-9]*$ ]] \
    || die "BOOT_ATTEMPTS 必须是正整数"
  [[ "$ADB_ATTEMPTS" =~ ^[1-9][0-9]*$ ]] \
    || die "ADB_ATTEMPTS 必须是正整数"
  if [[ ! "$REDROID_ADB_PORT" =~ ^[0-9]+$ ]] \
    || (( REDROID_ADB_PORT < 1 || REDROID_ADB_PORT > 65535 )); then
    die "REDROID_ADB_PORT 必须是 1-65535"
  fi
  if [[ ! "$WS_SCRCPY_PORT" =~ ^[0-9]+$ ]] \
    || (( WS_SCRCPY_PORT < 1 || WS_SCRCPY_PORT > 65535 )); then
    die "WS_SCRCPY_PORT 必须是 1-65535"
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
  ip -4 address show dev "$bridge" | grep -F "${gateway}/" >/dev/null || return 1
}

# 网络上可能同时存在多个 Android 实例。异常网络只在没有容器引用时重建，
# 避免为了部署一个新版本而中断已经运行的模拟器。
recreate_android_network() {
  local attached_containers
  attached_containers="$(docker network inspect -f '{{range .Containers}}{{println .Name}}{{end}}' "$ANDROID_NETWORK" 2>/dev/null || true)"
  [[ -z "${attached_containers//[[:space:]]/}" ]] \
    || die "网络 $ANDROID_NETWORK 异常但仍连接容器，拒绝重建以免中断现有模拟器：${attached_containers//$'\n'/, }"

  log "Docker 网络 $ANDROID_NETWORK 的 bridge 或网关异常，且没有容器引用，正在重建"
  docker network rm "$ANDROID_NETWORK" >/dev/null 2>&1 || true
  docker network create --driver bridge "$ANDROID_NETWORK" >/dev/null

  # Docker 创建 bridge 可能有短暂延迟，最多等待 5 秒。
  for _ in {1..10}; do
    network_is_healthy && break
    sleep 0.5
  done
  network_is_healthy || die "Docker 网络 $ANDROID_NETWORK 重建后仍缺少 bridge 或网关路由"
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
    docker inspect -f '{{json .NetworkSettings.Networks}}' "$container" | grep "\"$ANDROID_NETWORK\"" >/dev/null \
      || docker network connect "$ANDROID_NETWORK" "$container"
  fi
}

# 宿主机修复脚本供 systemd 使用：缺失时安装并加载 binder_linux。
install_binder_setup_script() {
  install -d -m 0755 "$(dirname "$BINDER_SETUP_PATH")"

  cat >"$BINDER_SETUP_PATH" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

binder_is_ready() {
  grep -qE '^[[:space:]]*nodev[[:space:]]+binder$' /proc/filesystems
}

if binder_is_ready; then
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

grep -qE '^[[:space:]]*nodev[[:space:]]+binder$' /proc/filesystems \
  || { echo "Binder 修复失败：BinderFS 未注册" >&2; exit 1; }
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
  docker create \
    --name "$REDROID_CONTAINER" \
    --hostname "$REDROID_CONTAINER" \
    --privileged \
    --restart unless-stopped \
    --network "$ANDROID_NETWORK" \
    --label "io.redroid.deploy.managed=true" \
    --label "io.redroid.deploy.instance=android${ANDROID_VERSION}" \
    --label "io.redroid.deploy.android-version=$ANDROID_VERSION" \
    --label "io.redroid.deploy.sdk-version=$SDK_VERSION" \
    -p "127.0.0.1:${REDROID_ADB_PORT}:5555" \
    -v "$data_dir:/data" \
    "$image" >/dev/null
}

# GMS 镜像不存在时，从本项目的固定构建输入自动制作。
gapps_build_context() {
  local build_context="$GAPPS_BUILD_CONTEXT"
  local script_dir
  if ! script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"; then
    script_dir=""
  fi
  if [[ -f "$script_dir/../redroid-gapps/Dockerfile.android14" ]]; then
    build_context="$script_dir/../redroid-gapps"
  fi

  printf '%s\n' "$build_context"
}

build_gapps_archive_image() {
  local build_context dockerfile
  build_context="$(gapps_build_context)"
  if [[ -d "$build_context" ]]; then
    dockerfile="$build_context/Dockerfile.gapps-archive"
  else
    # For a Git URL build context, Docker resolves the file inside the context.
    dockerfile="Dockerfile.gapps-archive"
  fi
  [[ -n "$REDROID_BASE_IMAGE" && -n "$GAPPS_URL" && -n "$GAPPS_SHA256" ]] \
    || die "$REDROID_CONTAINER 的 GMS 构建输入不完整"

  log "正在构建 Android $ANDROID_VERSION + GMS 镜像：$REDROID_IMAGE"
  docker buildx build \
    --platform linux/amd64 \
    --file "$dockerfile" \
    --load \
    --build-arg "REDROID_BASE_IMAGE=$REDROID_BASE_IMAGE" \
    --build-arg "GAPPS_URL=$GAPPS_URL" \
    --build-arg "GAPPS_SHA256=$GAPPS_SHA256" \
    --build-arg "GAPPS_API=$SDK_VERSION" \
    --build-arg "GAPPS_SOURCE=$GAPPS_SOURCE" \
    --build-arg "GAPPS_GRANT_DEVICE_CONFIG=$GAPPS_GRANT_DEVICE_CONFIG" \
    --build-arg "OVERLAY_REQUIRED=$OVERLAY_REQUIRED" \
    --tag "$REDROID_IMAGE" \
    "$build_context"
}

build_android14_gms_image() {
  local build_context dockerfile
  build_context="$(gapps_build_context)"
  if [[ -d "$build_context" ]]; then
    dockerfile="$build_context/Dockerfile.android14"
  else
    dockerfile="Dockerfile.android14"
  fi

  log "首次部署 API 34，正在构建 Android 14 + GMS 镜像"
  docker buildx build \
    --platform linux/amd64 \
    --file "$dockerfile" \
    --load \
    --tag "$REDROID_IMAGE" \
    "$build_context"
}

build_android15_gms_image() {
  local build_context dockerfile
  build_context="$(gapps_build_context)"
  if [[ -d "$build_context" ]]; then
    dockerfile="$build_context/Dockerfile.android15"
  else
    # For a Git build context, Docker resolves this path inside the context.
    dockerfile="Dockerfile.android15"
  fi

  if ! docker image inspect local/redroid-14-mtg:2026.08.19 >/dev/null 2>&1; then
    local requested_image="$REDROID_IMAGE"
    REDROID_IMAGE="local/redroid-14-mtg:2026.08.19"
    build_android14_gms_image
    REDROID_IMAGE="$requested_image"
  fi

  log "首次部署 API 35，正在构建 Android 15 + GMS 镜像"
  docker buildx build \
    --platform linux/amd64 \
    --file "$dockerfile" \
    --load \
    --tag "$REDROID_IMAGE" \
    "$build_context"
}

prepare_redroid_image() {
  local gapps_commit image_arch archive_source
  if docker image inspect "$REDROID_IMAGE" >/dev/null 2>&1; then
    log "使用本地已有 Redroid 镜像：$REDROID_IMAGE"
  elif [[ "$GAPPS_FLAVOR" == "archive" ]]; then
    build_gapps_archive_image
  elif [[ "$GAPPS_FLAVOR" == "mindthegapps" ]]; then
    build_android14_gms_image
  elif [[ "$GAPPS_FLAVOR" == "litegapps" ]]; then
    build_android15_gms_image
  else
    log "本地没有 Redroid 镜像，正在拉取：$REDROID_IMAGE"
    docker pull "$REDROID_IMAGE"
  fi

  if [[ "$GAPPS_FLAVOR" == "mindthegapps" ]]; then
    gapps_commit="$(docker image inspect "$REDROID_IMAGE" \
      --format '{{index .Config.Labels "io.redroid.gapps.mindthegapps.commit"}}')"
    [[ -n "$gapps_commit" && "$gapps_commit" != "<no value>" ]] \
      || die "API 34 镜像缺少 MindTheGapps 构建标签"
  elif [[ "$GAPPS_FLAVOR" == "litegapps" ]]; then
    [[ "$(docker image inspect "$REDROID_IMAGE" \
      --format '{{index .Config.Labels "io.redroid.gapps.device-configurator"}}')" == "true" ]] \
      || die "API 35 镜像缺少 Device Configurator 修复标签"
    [[ "$(docker image inspect "$REDROID_IMAGE" \
      --format '{{index .Config.Labels "io.redroid.docker-network"}}')" == "true" ]] \
      || die "API 35 镜像缺少 Docker 网络修复标签"
  elif [[ "$GAPPS_FLAVOR" == "archive" ]]; then
    archive_source="$(docker image inspect "$REDROID_IMAGE" \
      --format '{{index .Config.Labels "io.redroid.gapps.source"}}')"
    [[ "$archive_source" == "$GAPPS_SOURCE" ]] \
      || die "GMS 镜像来源不匹配：期望 $GAPPS_SOURCE，实际 $archive_source"
  fi
  image_arch="$(docker image inspect "$REDROID_IMAGE" --format '{{.Architecture}}')"
  [[ "$image_arch" == "amd64" ]] \
    || die "服务器部署只支持 amd64 镜像，实际为 $image_arch"
}

container_data_dir() {
  docker inspect "$1" --format '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Source}}{{end}}{{end}}'
}

container_adb_port() {
  docker port "$1" 5555/tcp 2>/dev/null \
    | awk -F: '$1 == "127.0.0.1" { print $NF; exit }' \
    || true
}

existing_instance_matches() {
  local actual_image actual_image_id expected_image_id actual_data_dir actual_adb_port
  actual_image="$(docker inspect -f '{{.Config.Image}}' "$REDROID_CONTAINER")"
  actual_image_id="$(docker inspect -f '{{.Image}}' "$REDROID_CONTAINER")"
  expected_image_id="$(docker image inspect -f '{{.Id}}' "$REDROID_IMAGE")"
  actual_data_dir="$(container_data_dir "$REDROID_CONTAINER")"
  actual_adb_port="$(container_adb_port "$REDROID_CONTAINER")"

  [[ "$actual_image" == "$REDROID_IMAGE" ]] \
    && [[ "$actual_image_id" == "$expected_image_id" ]] \
    && [[ "$(readlink -m "$actual_data_dir")" == "$(readlink -m "$REDROID_DATA_DIR")" ]] \
    && [[ "$actual_adb_port" == "$REDROID_ADB_PORT" ]]
}

ensure_instance_resources_are_unique() {
  local other other_data_dir reserved_port

  while IFS= read -r other; do
    [[ -z "$other" || "$other" == "$REDROID_CONTAINER" ]] && continue
    reserved_port="$(container_adb_port "$other")"
    [[ "$reserved_port" != "$REDROID_ADB_PORT" ]] \
      || die "固定 ADB 端口 $REDROID_ADB_PORT 已被容器 $other 占用"
    other_data_dir="$(container_data_dir "$other")"
    if [[ -n "$other_data_dir" \
      && "$(readlink -m "$other_data_dir")" == "$(readlink -m "$REDROID_DATA_DIR")" ]]; then
      die "数据目录 $REDROID_DATA_DIR 已被容器 $other 使用，不同实例禁止共用 /data"
    fi
  done < <(docker ps -a --format '{{.Names}}')

  if ! container_exists "$REDROID_CONTAINER" \
    && ss -H -ltn | awk -v port="$REDROID_ADB_PORT" '
      { count=split($4, address, ":") }
      address[count] == port { found=1 }
      END { exit !found }
    '; then
    die "固定 ADB 端口 $REDROID_ADB_PORT 已被宿主机其他进程占用"
  fi
}

# 已存在且配置一致的实例原样复用，不执行 restart。配置不一致时直接失败，
# 脚本不提供自动替换开关，避免误删正在使用的模拟器。
install_redroid() {
  prepare_redroid_image
  ensure_instance_resources_are_unique

  if container_exists "$REDROID_CONTAINER"; then
    if existing_instance_matches; then
      log "复用现有实例 $REDROID_CONTAINER；不会重建或重启"
      connect_network "$REDROID_CONTAINER"
      return
    fi

    die "$REDROID_CONTAINER 已存在但镜像版本、数据目录或固定 ADB 端口不一致；脚本拒绝自动替换，请人工确认后删除该容器再重试"
  fi

  # /data 保存在实例专属目录，重建容器不会删除应用和设置。
  install -d -m 0755 "$REDROID_DATA_DIR"
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
  if container_running "$REDROID_CONTAINER"; then
    log "$REDROID_CONTAINER 已在运行，不执行重启"
  else
    docker start "$REDROID_CONTAINER" >/dev/null
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

# 自定义镜像必须在构建阶段完成 APK 权限和 Overlay 修复；部署阶段只验证，
# 不再修改容器系统分区，也不会为了修权限而重启 Android。
verify_redroid_release() {
  local actual_sdk actual_release i
  actual_sdk="$(docker exec "$REDROID_CONTAINER" getprop ro.build.version.sdk)"
  actual_release="$(docker exec "$REDROID_CONTAINER" getprop ro.build.version.release)"
  [[ "$actual_sdk" == "$SDK_VERSION" ]] \
    || die "$REDROID_CONTAINER 的 API Level 为 $actual_sdk，预期为 $SDK_VERSION"
  log "系统版本验证通过：Android $actual_release / API $actual_sdk"

  if [[ "$IMAGE_HAS_GMS" != "1" ]]; then
    log "API $SDK_VERSION 使用官方 AOSP 镜像，本版本不安装 GMS"
    return
  fi

  local package
  local packages=(
    com.google.android.gms
    com.android.vending
    com.google.android.gsf
  )

  for package in "${packages[@]}"; do
    docker exec "$REDROID_CONTAINER" sh -c \
      'export PATH=/system/bin:$PATH; cmd package list packages' \
      | grep -Fx "package:$package" >/dev/null \
      || die "$REDROID_CONTAINER 缺少系统包 $package"
  done

  if (( SDK_VERSION >= 33 )); then
    for ((i=1; i<=30; i++)); do
      if docker exec "$REDROID_CONTAINER" dumpsys package com.google.android.gms \
        | grep -F 'android.permission.WRITE_DEVICE_CONFIG: granted=true' >/dev/null; then
        break
      fi
      sleep 3
    done
    (( i <= 30 )) \
      || die "$REDROID_CONTAINER 中 Google Play services 未在限定时间内获得 WRITE_DEVICE_CONFIG"

    docker exec "$REDROID_CONTAINER" logcat -b all -c >/dev/null 2>&1 || true
    sleep 5
    if docker exec "$REDROID_CONTAINER" logcat -b all -d -v brief \
      | grep -E 'Permission denial to mutate flag|must have root, WRITE_DEVICE_CONFIG|setAllConfigSettings' >/dev/null; then
      die "$REDROID_CONTAINER 仍出现 DeviceConfig 权限拒绝"
    fi
  fi
  if (( SDK_VERSION >= 33 )); then
    log "GApps 与 WRITE_DEVICE_CONFIG 验证通过"
  else
    log "GApps 包验证通过"
  fi
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

# 安装 ws-scrcpy。已有容器只连接共享网络，不重建、不重启。
install_ws_scrcpy() {
  if container_exists "$WS_SCRCPY_CONTAINER"; then
    docker port "$WS_SCRCPY_CONTAINER" 8000/tcp 2>/dev/null \
      | grep -E "^(0\\.0\\.0\\.0|\\[::\\]):${WS_SCRCPY_PORT}$" >/dev/null \
      || die "$WS_SCRCPY_CONTAINER 已存在但未使用固定端口 $WS_SCRCPY_PORT；脚本拒绝自动重建"
    connect_network "$WS_SCRCPY_CONTAINER"
    if container_running "$WS_SCRCPY_CONTAINER"; then
      log "$WS_SCRCPY_CONTAINER 已在运行，不执行重启"
    else
      docker start "$WS_SCRCPY_CONTAINER" >/dev/null
    fi
    return
  fi

  if ss -H -ltn | awk -v port="$WS_SCRCPY_PORT" '
    { count=split($4, address, ":") }
    address[count] == port { found=1 }
    END { exit !found }
  '; then
    die "ws-scrcpy 固定端口 $WS_SCRCPY_PORT 已被宿主机其他进程占用"
  fi

  build_ws_scrcpy
  docker run -d \
    --name "$WS_SCRCPY_CONTAINER" \
    --hostname "$WS_SCRCPY_CONTAINER" \
    --restart unless-stopped \
    --network "$ANDROID_NETWORK" \
    -p "${WS_SCRCPY_PORT}:8000" \
    "ws-scrcpy:${WS_SCRCPY_REF}" >/dev/null
}

# 将当前实例加入共享设备列表。每个版本各有一个登记文件。
register_redroid_instance() {
  install -d -m 0755 "$INSTANCE_REGISTRY_DIR"
  printf '%s\n' "$REDROID_CONTAINER" \
    >"$INSTANCE_REGISTRY_DIR/$REDROID_CONTAINER.container"
}

# 配置 ws-scrcpy 自动连接全部已登记模拟器。
configure_ws_scrcpy_auto_connect() {
  cat >/usr/local/bin/redroid-adb-connect <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
WS_SCRCPY_CONTAINER="$WS_SCRCPY_CONTAINER"
INSTANCE_REGISTRY_DIR="$INSTANCE_REGISTRY_DIR"
BOOT_ATTEMPTS="$BOOT_ATTEMPTS"
ADB_ATTEMPTS="$ADB_ATTEMPTS"

log() { printf '%s %s\\n' "\$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "\$*"; }

[[ "\$(docker inspect -f '{{.State.Running}}' "\$WS_SCRCPY_CONTAINER" 2>/dev/null || true)" == "true" ]] \
  || docker start "\$WS_SCRCPY_CONTAINER" >/dev/null

shopt -s nullglob
registrations=("\$INSTANCE_REGISTRY_DIR"/*.container)
(( \${#registrations[@]} > 0 )) || { log "没有已登记的 Redroid 实例"; exit 0; }

failed=0
for registration in "\${registrations[@]}"; do
  read -r redroid_container <"\$registration"
  [[ "\$redroid_container" =~ ^redroid-android[0-9]+$ ]] \
    || { log "忽略无效登记：\$registration"; continue; }
  docker inspect "\$redroid_container" >/dev/null 2>&1 \
    || { log "忽略不存在的容器：\$redroid_container"; continue; }

  for ((i=1; i<=BOOT_ATTEMPTS; i++)); do
    if [[ "\$(docker inspect -f '{{.State.Running}}' "\$redroid_container" 2>/dev/null || true)" == "true" ]] \
      && [[ "\$(timeout 5s docker exec "\$redroid_container" getprop sys.boot_completed 2>/dev/null || true)" == "1" ]]; then
      break
    fi
    sleep 5
  done

  adb_target="\$redroid_container:5555"
  docker exec "\$WS_SCRCPY_CONTAINER" adb disconnect "\$adb_target" >/dev/null 2>&1 || true
  for ((i=1; i<=ADB_ATTEMPTS; i++)); do
    timeout --kill-after=2s 15s docker exec "\$WS_SCRCPY_CONTAINER" adb connect "\$adb_target" >/dev/null 2>&1 || true
    if timeout --kill-after=2s 10s docker exec "\$WS_SCRCPY_CONTAINER" adb devices \
      | awk -v target="\$adb_target" '\$1 == target && \$2 == "device" { found=1 } END { exit !found }'; then
      log "ADB 已连接：\$adb_target"
      break
    fi
    sleep 3
  done

  if (( i > ADB_ATTEMPTS )); then
    log "ADB 连接失败：\$adb_target"
    failed=1
  fi
done

exit "\$failed"
EOF
  chmod 0755 /usr/local/bin/redroid-adb-connect

  cat >/etc/systemd/system/redroid-adb-connect.service <<EOF
[Unit]
Description=Connect ws-scrcpy to all registered Redroid instances
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
  systemctl enable redroid-adb-connect.service
  systemctl reset-failed redroid-adb-connect.service >/dev/null 2>&1 || true
  systemctl restart --no-block redroid-adb-connect.service
  log "ws-scrcpy 正在后台连接所有已登记模拟器"
}

main() {
  local server_ip
  log "deploy_redroid_ws_scrcpy 版本：$SCRIPT_VERSION"
  select_release "$@"
  log "目标版本：Android $ANDROID_VERSION / API $SDK_VERSION"
  validate_inputs
  install_docker
  install_binder_linux
  systemctl start docker
  install_binder_setup_script
  install_redroid_stop_script
  ensure_network
  install_redroid
  configure_binder_startup
  wait_for_redroid_boot
  verify_redroid_release
  install_ws_scrcpy
  register_redroid_instance
  configure_ws_scrcpy_auto_connect

  server_ip="$(detect_server_ip)"
  log "$REDROID_CONTAINER 部署完成"
  log "浏览器打开 http://${server_ip}:${WS_SCRCPY_PORT}"
  log "ADB 仅绑定本机：127.0.0.1:${REDROID_ADB_PORT}"
  log "如果打不开，请检查云安全组和主机防火墙是否开放 TCP ${WS_SCRCPY_PORT}"
}

main "$@"
