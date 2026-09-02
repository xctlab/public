#!/bin/bash
set -e

# 获取当前登录会话的原始用户名
REAL_USER=$(logname)
# 安全解析该用户的 home 目录
USER_HOME=$(eval echo "~$REAL_USER")

# 获取最新版本的command-tools下载链接
get_latest_cmd_tools_url() {
  local url
  url=$(curl -s https://developer.android.com/studio#command-tools | grep -Eo 'https://dl\.google\.com/android/repository/commandlinetools-linux-[0-9]+_latest\.zip' | head -1)

  if [[ -z "$url" ]]; then
    echo "Error: 未能获取最新命令行工具下载链接" >&2
    return 1
  fi

  echo "$url"
}

echo "📦 Step 1: 安装必要依赖..."
sudo apt update
sudo apt install -y wget unzip zip curl

echo "✅ 依赖安装完成。"

# 配置路径
SDK_ROOT="$USER_HOME/Android/Sdk"
TOOLS_DIR="$SDK_ROOT/cmdline-tools"
TOOL_VERSION="latest"
SDK_ZIP_URL=$(get_latest_cmd_tools_url)

# 判断是否已经安装了commandline tools
if [ ! -d "$TOOLS_DIR/$TOOL_VERSION" ]; then
  echo "📁 Step 2: 准备 SDK 安装目录：$TOOLS_DIR/$TOOL_VERSION"
  mkdir -p "$TOOLS_DIR"
  cd "$TOOLS_DIR"
  echo "🌐 Step 3: 下载 Android commandline tools..."
  wget -O sdk-tools.zip "$SDK_ZIP_URL"

  echo "📦 Step 4: 解压工具包..."
  unzip sdk-tools.zip
  rm sdk-tools.zip

  echo "🔄 Step 5: 重命名目录为 $TOOL_VERSION（供 sdkmanager 识别）"
  mv cmdline-tools "$TOOL_VERSION"

  echo "✅ 工具下载与解压完成。"
else
  echo "⚠️ cmdline-tools已安装，跳过。"
fi

# 添加环境变量到 ~/.bashrc 配置
echo "🔧 Step 6: 配置环境变量..."
ENV_CONFIG_FILE="$USER_HOME/.user_env"
ENV_CONFIG_NAME="${ENV_CONFIG_FILE##*/}"
if ! grep -q ANDROID_SDK_ROOT "$ENV_CONFIG_FILE"; then
  cat <<'EOF' >> "$ENV_CONFIG_FILE"

# >>> Android SDK 设置 >>>
export JAVA_HOME=/opt/android-studio/jbr
export PATH=$JAVA_HOME/bin:$PATH

export ANDROID_HOME=$HOME/Android/Sdk
export ANDROID_SDK_ROOT=$ANDROID_HOME
export PATH=$ANDROID_SDK_ROOT/cmdline-tools/latest/bin:$PATH
export PATH=$ANDROID_SDK_ROOT/platform-tools:$PATH
export PATH=$ANDROID_SDK_ROOT/emulator:$PATH
# <<< Android SDK 设置 <<<
EOF
  echo "✅ 已添加到 $ENV_CONFIG_FILE。"
else
  if ! grep -q ANDROID_HOME "$ENV_CONFIG_FILE"; then
    sed -i '/export ANDROID_SDK_ROOT=/i export ANDROID_HOME=$HOME/Android/Sdk' "$ENV_CONFIG_FILE"
    sed -i 's|export ANDROID_SDK_ROOT=.*|export ANDROID_SDK_ROOT=$ANDROID_HOME|' "$ENV_CONFIG_FILE"
  fi
  echo "⚠️ 已检测到 $ENV_CONFIG_FILE 存在 SDK 环境变量配置，已补齐兼容变量。"
fi
if grep -q '^export BASH_ENV=' "$ENV_CONFIG_FILE"; then
  sed -i "s|^export BASH_ENV=.*|export BASH_ENV=\"$ENV_CONFIG_FILE\"|" "$ENV_CONFIG_FILE"
else
  echo "export BASH_ENV=\"$ENV_CONFIG_FILE\"" >> "$ENV_CONFIG_FILE"
fi

# 配置同步到 ~/.bash_profile；bash -lc 会优先读取它而不是 ~/.profile。
BASH_PROFILE_FILE="$USER_HOME/.bash_profile"
if ! grep -Fq "$ENV_CONFIG_NAME" "$BASH_PROFILE_FILE" 2>/dev/null; then
  cat <<EOF >> "$BASH_PROFILE_FILE"

# include .user_env if it exists
if [ -f "$ENV_CONFIG_FILE" ]; then
  . "$ENV_CONFIG_FILE"
fi
EOF
  echo "✅ 已同步到 $BASH_PROFILE_FILE。"
else
  echo "⚠️ 检测到 $BASH_PROFILE_FILE 已配置，未重复添加。"
fi

# 配置同步到 ~/.profile,
PROFILE_FILE="$USER_HOME/.profile"
if ! grep -Fq "$ENV_CONFIG_NAME" "$PROFILE_FILE"; then
  cat <<EOF >> "$PROFILE_FILE"

# include .user_env if it exists
if [ -f "$ENV_CONFIG_FILE" ]; then
  . "$ENV_CONFIG_FILE"
fi
EOF
  echo "✅ 已同步到 $PROFILE_FILE。"
else
  echo "⚠️ 检测到 $PROFILE_FILE 已配置 ，未重复添加。"
fi

# 配置同步到 ~/.bashrc。放在文件开头，避免非交互 shell 提前 return。
BASHRC_FILE="$USER_HOME/.bashrc"
if [ ! -f "$BASHRC_FILE" ] || [ "$(grep -Fn -m1 "$ENV_CONFIG_NAME" "$BASHRC_FILE" | cut -d: -f1)" != "1" ]; then
  BASHRC_TMP=$(mktemp)
  cat <<EOF > "$BASHRC_TMP"
# include .user_env if it exists
if [ -f "$ENV_CONFIG_FILE" ]; then
  . "$ENV_CONFIG_FILE"
fi
EOF
  if [ -f "$BASHRC_FILE" ]; then
    sed '/^# include \.user_env if it exists$/,/^fi$/d' "$BASHRC_FILE" >> "$BASHRC_TMP"
  fi
  cat "$BASHRC_TMP" > "$BASHRC_FILE"
  rm "$BASHRC_TMP"
  echo "✅ 已同步到 $BASHRC_FILE"
else
  echo "⚠️ 检测到 $BASHRC_FILE 已配置 ，未重复添加。"
fi

# 生效当前终端
export JAVA_HOME=/opt/android-studio/jbr
export PATH=$JAVA_HOME/bin:$PATH

export ANDROID_HOME="$USER_HOME/Android/Sdk"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export PATH="$ANDROID_SDK_ROOT/cmdline-tools/latest/bin:$PATH"
export PATH="$ANDROID_SDK_ROOT/platform-tools:$PATH"
export PATH="$ANDROID_SDK_ROOT/emulator:$PATH"


echo "📄 Step 7: 接受 SDK License 条款..."
yes | sdkmanager --licenses

echo "⬇️ Step 8: 安装基础组件..."
sdkmanager "platform-tools" "platforms;android-35" "build-tools;35.0.0"

echo "🎉 所有步骤完成！你现在可以使用 adb / sdkmanager 等工具了。"

echo "✅ 示例："
echo "    adb --version"
echo "    sdkmanager --list"
