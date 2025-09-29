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

function check_add_bash_env() {
  # 检查 .bashrc 有没有 source ~/.bash_env
  if ! grep -q "source ~/.bash_env" "$HOME/.bashrc"; then
    cat >> "$HOME/.bashrc" <<EOF

# include .bash_env if it exists
if [ -f ~/.bash_env ]; then
  source ~/.bash_env
fi
EOF
  fi
  # 检查 .bash_profile 有没有 source ~/.bash_env
  if ! grep -q "source ~/.bash_env" "$HOME/.bash_profile"; then
    cat >> "$HOME/.bashrc" <<EOF

# include .bash_env if it exists
if [ -f ~/.bash_env ]; then
  source ~/.bash_env
fi
EOF
  fi
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
  # 在用户目录下安装
  sudo -u $REAL_USER $SHELL <<EOF
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
EOF
else
  echo "⚠️ cmdline-tools已安装，跳过。"
fi

# 添加环境变量到 shell 配置
echo "🔧 Step 6: 配置环境变量..."
check_add_bash_env
ENV_CONFIG_FILE="$USER_HOME/.bash_env"
if ! grep -q ANDROID_SDK_ROOT "$ENV_CONFIG_FILE"; then
  cat <<'EOF' >> "$ENV_CONFIG_FILE"

# >>> Android SDK 设置 >>>
export JAVA_HOME=/opt/android-studio/jbr
export PATH=$JAVA_HOME/bin:$PATH

export ANDROID_SDK_ROOT=$HOME/Android/Sdk
export PATH=$ANDROID_SDK_ROOT/cmdline-tools/latest/bin:$PATH
export PATH=$ANDROID_SDK_ROOT/platform-tools:$PATH
export PATH=$ANDROID_SDK_ROOT/emulator:$PATH
# <<< Android SDK 设置 <<<
EOF
  echo "✅ 已添加到 $ENV_CONFIG_FILE。请运行 source $ENV_CONFIG_FILE 或重新打开终端以生效。"
else
  echo "⚠️ 已检测到 SDK 环境变量配置，未重复添加。"
fi

# 生效当前终端
export JAVA_HOME=/opt/android-studio/jbr
export PATH=$JAVA_HOME/bin:$PATH

export ANDROID_SDK_ROOT="$USER_HOME/Android/Sdk"
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