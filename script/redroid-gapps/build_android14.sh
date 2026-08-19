#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_NAME="${IMAGE_NAME:-local/redroid-14-mtg:2026.08.19}"
TARGET_PLATFORM="${TARGET_PLATFORM:-linux/amd64}"
MINDTHEGAPPS_COMMIT="${MINDTHEGAPPS_COMMIT:-f75de2aa2af5d2662e394d833464e8dda55c9e6e}"
REDROID_BASE_IMAGE="${REDROID_BASE_IMAGE:-redroid/redroid:14.0.0-latest@sha256:a3e654caad74faed03cd5ead057a989e06f507778cda678e5d3b9772e0092f1c}"

log() { printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
die() { log "错误：$*" >&2; exit 1; }

case "$TARGET_PLATFORM" in
  linux/amd64) default_gapps_arch=x86_64 ;;
  linux/arm64) default_gapps_arch=arm64 ;;
  *) die "不支持的平台：$TARGET_PLATFORM" ;;
esac
GAPPS_ARCH="${GAPPS_ARCH:-$default_gapps_arch}"

command -v docker >/dev/null 2>&1 || die "未安装 Docker"
docker buildx version >/dev/null 2>&1 || die "Docker buildx 不可用"

log "构建 ${IMAGE_NAME}（平台：${TARGET_PLATFORM}）"
docker buildx build \
  --platform "$TARGET_PLATFORM" \
  --file "$SCRIPT_DIR/Dockerfile.android14" \
  --build-arg "MINDTHEGAPPS_COMMIT=$MINDTHEGAPPS_COMMIT" \
  --build-arg "REDROID_BASE_IMAGE=$REDROID_BASE_IMAGE" \
  --build-arg "GAPPS_ARCH=$GAPPS_ARCH" \
  --label "io.redroid.gapps.build-date=$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  --load \
  --tag "$IMAGE_NAME" \
  "$SCRIPT_DIR"

actual_platform="$(docker image inspect "$IMAGE_NAME" --format '{{.Os}}/{{.Architecture}}')"
[[ "$actual_platform" == "$TARGET_PLATFORM" ]] \
  || die "镜像平台错误：实际为 $actual_platform，预期为 $TARGET_PLATFORM"

actual_commit="$(docker image inspect "$IMAGE_NAME" \
  --format '{{index .Config.Labels "io.redroid.gapps.mindthegapps.commit"}}')"
[[ "$actual_commit" == "$MINDTHEGAPPS_COMMIT" ]] \
  || die "MindTheGapps 标签错误：实际为 $actual_commit，预期为 $MINDTHEGAPPS_COMMIT"

actual_base_image="$(docker image inspect "$IMAGE_NAME" \
  --format '{{index .Config.Labels "io.redroid.gapps.redroid-base"}}')"
[[ "$actual_base_image" == "$REDROID_BASE_IMAGE" ]] \
  || die "Redroid 基础镜像标签错误：实际为 $actual_base_image，预期为 $REDROID_BASE_IMAGE"

actual_gapps_arch="$(docker image inspect "$IMAGE_NAME" \
  --format '{{index .Config.Labels "io.redroid.gapps.arch"}}')"
[[ "$actual_gapps_arch" == "$GAPPS_ARCH" ]] \
  || die "GApps 架构标签错误：实际为 $actual_gapps_arch，预期为 $GAPPS_ARCH"

container_id="$(docker create --platform "$TARGET_PLATFORM" "$IMAGE_NAME")"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"; docker rm -f "$container_id" >/dev/null 2>&1 || true' EXIT

gapps_apks=(
  /system/product/app/GoogleCalendarSyncAdapter/GoogleCalendarSyncAdapter.apk
  /system/product/app/GoogleContactsSyncAdapter/GoogleContactsSyncAdapter.apk
  /system/product/app/PrebuiltExchange3Google/PrebuiltExchange3Google.apk
  /system/product/overlay/GmsOverlay.apk
  /system/product/overlay/GmsSettingsOverlay.apk
  /system/product/overlay/GmsSettingsProviderOverlay.apk
  /system/product/overlay/GmsSetupWizardOverlay.apk
  /system/product/priv-app/AndroidAutoStub/AndroidAutoStub.apk
  /system/product/priv-app/GmsCore/GmsCore.apk
  /system/product/priv-app/GooglePartnerSetup/GooglePartnerSetup.apk
  /system/product/priv-app/GoogleRestore/GoogleRestore.apk
  /system/product/priv-app/Phonesky/Phonesky.apk
  /system/product/priv-app/Velvet/Velvet.apk
  /system/product/priv-app/Wellbeing/Wellbeing.apk
  /system/system_ext/priv-app/GoogleFeedback/GoogleFeedback.apk
  /system/system_ext/priv-app/GoogleServicesFramework/GoogleServicesFramework.apk
  /system/system_ext/priv-app/SetupWizard/SetupWizard.apk
)

expected_paths=(
  /system/product/etc/permissions/privapp-permissions-google-product.xml
  /system/system_ext/etc/permissions/privapp-permissions-google-system-ext.xml
)

file_mode() {
  if stat -c '%a' "$1" >/dev/null 2>&1; then
    stat -c '%a' "$1"
  else
    stat -f '%Lp' "$1"
  fi
}

for path in "${gapps_apks[@]}" "${expected_paths[@]}"; do
  check_path="$tmp_dir/$(printf '%s' "$path" | tr '/' '_')"
  docker cp "$container_id:$path" "$check_path" >/dev/null 2>&1 \
    || die "镜像缺少文件：$path"

  if [[ "$path" == *.apk ]]; then
    mode="$(file_mode "$check_path")"
    [[ "$mode" == "644" ]] \
      || die "GApps APK 权限错误：$path（实际为 $mode，应为 644）"
  fi
done

if docker cp "$container_id:/system/system_ext/priv-app/Provision" "$tmp_dir/Provision" >/dev/null 2>&1; then
  die "AOSP Provision 仍然存在，会与 Google SetupWizard 冲突"
fi

docker cp "$container_id:/system/product/overlay/GmsOverlay.apk" "$tmp_dir/GmsOverlay.apk"

aapt2_path=""
if command -v aapt2 >/dev/null 2>&1; then
  aapt2_path="$(command -v aapt2)"
elif [[ -n "${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}" ]]; then
  sdk_root="${ANDROID_HOME:-$ANDROID_SDK_ROOT}"
  aapt2_path="$(find "$sdk_root/build-tools" -maxdepth 2 -type f -name aapt2 -print 2>/dev/null | sort -V | tail -1)"
fi

if [[ -n "$aapt2_path" && -x "$aapt2_path" ]]; then
  "$aapt2_path" dump resources "$tmp_dir/GmsOverlay.apk" >"$tmp_dir/GmsOverlay.resources.txt"
  awk '
    /string\/config_deviceConfiguratorPackageName$/ {
      getline
      if ($0 ~ /"com.google.android.gms"/) found=1
    }
    END { exit !found }
  ' "$tmp_dir/GmsOverlay.resources.txt" \
    || die "GmsOverlay 缺少 Device Configurator 资源"
else
  log "未找到 aapt2，跳过 RRO 内容检查"
fi

log "构建完成：$IMAGE_NAME"
log "MindTheGapps commit：$MINDTHEGAPPS_COMMIT"
