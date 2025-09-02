#!/bin/bash
set -e

scripts=(
    "Linux配置远程桌面环境:install_desktop.sh"
    "Linux安装或更新Android Studio:install_android_studio.sh"
    "Linux配置Android SDK开发环境:install_android_env.sh"
    "Linux安装安卓11模拟器(gms):install_emu.sh"
)

print_menu() {
    echo "请输入序号执行脚本（可多选，空格或逗号分隔，例如：0 2 3），或输入 all 执行全部："
    for i in "${!scripts[@]}"; do
        echo "$i --- ${scripts[$i]%%:*}"
    done
}

run_script() {
    local idx=$1
    if [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -ge 0 ] && [ "$idx" -lt "${#scripts[@]}" ]; then
        script_info="${scripts[$idx]}"
        script_name="${script_info%%:*}"
        script_file="${script_info#*:}"
        echo "执行脚本: $script_name"
        sudo /bin/bash -c "$(curl -fsSL "${prefix_url}${script_file}")"
    else
        echo "无效序号：'$idx'"
    fi
}

prefix_url="https://raw.githubusercontent.com/xctlab/public/refs/heads/main/script/shell/"

if [ -z "$1" ]; then
    print_menu
    read -r input
else
    input="$*"
fi

input="$(echo "$input" | tr ',，' ' ')"  # 支持中文逗号
input="$(echo "$input" | xargs)"         # 去除前后多余空格

if [[ "$input" == "all" ]]; then
    for i in "${!scripts[@]}"; do
        run_script "$i"
    done
else
    mapfile -t indices < <(echo "$input" | tr ' ' '\n' | grep -E '^[0-9]+$')
    for idx in "${indices[@]}"; do
        run_script "$idx"
    done
fi
