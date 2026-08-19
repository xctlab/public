# Redroid multi-version deployment and GMS images

This directory contains the reproducible GMS layers used by
`deploy_redroid.sh`. It does not download or compile the AOSP source tree.

The build files have explicit roles:

- `Dockerfile.android14`: builds Android 14 GMS from the pinned MindTheGapps source.
- `Dockerfile.android15`: layers the Android 15 Cocoon base with the tested configurator overlay and Docker networking fix.
- `Dockerfile.gapps-archive`: layers pinned GApps archives onto Android 8.1, 11, or 13 Redroid bases.
- `cocoon-network-fix.sh`: Android 15-only Docker bridge networking workaround copied into the image by `Dockerfile.android15`.

- Android 8.1 / API 27 and Android 11 / API 30: official Redroid plus pinned LiteGapps archives.
- Android 13 / API 33: official Redroid plus a pinned MindTheGapps x86_64 archive.
- Android 14 / API 34: official Redroid plus pinned MindTheGapps sources.
- Android 15 / API 35: Cocoon's Redroid-based LiteGapps image plus the patched
  Device Configurator overlay and a Docker bridge network fix.

The build also patches MindTheGapps' framework overlay so Google Play services
is selected as Android's device configurator. Without that resource, recent
Google Play services versions cannot write their DeviceConfig flags.

The Android 14 inputs are pinned to the official Redroid image digest and the
MindTheGapps `upsilon` commit recorded in `Dockerfile.android14`. The Android 15 base is
also pinned by digest. Both deployment images target `linux/amd64`.

## Requirements

- Docker Engine with buildx
- About 10 GB of free disk space for source, layers, and build cache
- Network access to Docker Hub and GitLab

The target image is `linux/amd64`, but the build host may use another
architecture when its Docker installation supports cross-platform builds.

## Build

Build Android 14 first; Android 15 reuses its patched resource overlay:

```bash
cd script/redroid-gapps
./build_android14.sh
docker buildx build \
  --platform linux/amd64 \
  --file Dockerfile.android15 \
  --load \
  --tag local/redroid-15-gms:2026.08.19 \
  .
```

The Android 14 build script's default image name is:

```text
local/redroid-14-mtg:2026.08.19
```

Override it when a private registry is available:

```bash
IMAGE_NAME=registry.example.com/private/redroid-14-mtg:2026.08.19 ./build_android14.sh
docker push registry.example.com/private/redroid-14-mtg:2026.08.19
```

## Deploy

The deployment script accepts only one optional argument: the canonical Docker
container name. `redroid-android14` selects Android 14 / API 34 and uses this
GMS image:

```bash
sudo bash script/shell/deploy_redroid.sh redroid-android14
```

If the local image is missing, the deployment script builds it automatically
from this directory. The instance is named `redroid-android14`, stores data in
`/var/lib/redroid/instances/android14/data`, and binds ADB to
`127.0.0.1:15534`.

With no argument, the script opens an interactive menu on `/dev/tty`; this also
works when the script is piped into `sudo bash`. Enter either the menu number or
the canonical container name. With one argument, it deploys that container
directly without prompting:

```bash
sudo bash script/shell/deploy_redroid.sh
sudo bash script/shell/deploy_redroid.sh redroid-android15
```

Current choices:

| Android | API Level | Image type | Container | Local ADB |
|---------|-----------|------------|-----------|-----------|
| 8.1 | 27 | LiteGapps | `redroid-android81` | `127.0.0.1:15527` |
| 11 | 30 | LiteGapps | `redroid-android11` | `127.0.0.1:15530` |
| 12 | 31 | Official Redroid AOSP | `redroid-android12` | `127.0.0.1:15531` |
| 13 | 33 | MindTheGapps archive | `redroid-android13` | `127.0.0.1:15533` |
| 14 | 34 | MindTheGapps | `redroid-android14` | `127.0.0.1:15534` |
| 15 | 35 | LiteGapps | `redroid-android15` | `127.0.0.1:15535` |

Redroid does not publish an official Android 7 image; its earliest supported
release here is Android 8.1 / API 27. Android 16 / API 36 is intentionally
disabled because the available x86_64 image does not finish booting with
software rendering on the tested non-GPU server.

All versions use the fixed ws-scrcpy port `8000`. Each version has its own data
directory and ADB port, and all registered instances appear in the same
ws-scrcpy device list. Re-running the script reuses a matching running instance
without restarting it. It also refuses to replace an existing instance whose
image, data directory, or port differs.

The existing AOSP containers named `redroid-android81`, `redroid-android11`, or
`redroid-android13` are therefore not silently replaced by the new GMS images;
stop and remove an old instance manually after backing up its `/data` volume
before migrating that canonical name.

Google applications are proprietary. Keep the resulting image private and
review the applicable Google terms before distribution.
