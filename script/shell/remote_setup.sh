#!/bin/bash
set -e

scripts=(
    [0]="Linux配置远程桌面环境|install_desktop.sh|"
    [1]="Linux安装或更新Android Studio|install_android_studio.sh|"
    [2]="Linux配置Android SDK开发环境|install_android_env.sh|"
    [3]="Linux安装 Redroid Android 15 / API 35 / GMS（默认模拟器）|deploy_redroid.sh|redroid-api35"
    [4]="Linux安装 Redroid Android 14 / API 34 / GMS|deploy_redroid.sh|redroid-api34"
    [5]="Linux安装 Redroid Android 13 / API 33 / GMS|deploy_redroid.sh|redroid-api33"
    [6]="Linux安装 Redroid Android 12 / API 31 / AOSP|deploy_redroid.sh|redroid-api31"
    [7]="Linux安装 Redroid Android 11 / API 30 / GMS|deploy_redroid.sh|redroid-api30"
    [8]="Linux安装 Redroid Android 8.1 / API 27 / GMS|deploy_redroid.sh|redroid-api27"
)

# 输入 all 时只执行这些菜单项：远程桌面、Android Studio、Android SDK，
# 以及最新版 Android 15 模拟器。其他模拟器仍可通过菜单单独选择。
default_install_indices=(
    0 1 2 3
)

print_menu() {
    echo "请输入序号执行脚本（可多选，空格或逗号分隔，例如：0 2 3）。"
    echo "输入 all 执行全部常规安装，并且只安装默认的最新版模拟器："
    for i in "${!scripts[@]}"; do
        echo "$i --- ${scripts[$i]%%|*}"
    done
}

run_script() {
    local idx=$1
    if [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -ge 0 ] && [ "$idx" -lt "${#scripts[@]}" ]; then
        local script_info script_name script_file script_arg remainder
        script_info="${scripts[$idx]}"
        script_name="${script_info%%|*}"
        remainder="${script_info#*|}"
        script_file="${remainder%%|*}"
        script_arg="${remainder#*|}"
        echo "执行脚本: $script_name"
        if [ -n "$script_arg" ]; then
            curl -fsSL "${prefix_url}${script_file}" | sudo bash -s -- "$script_arg"
        else
            curl -fsSL "${prefix_url}${script_file}" | sudo bash -s --
        fi
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
    for i in "${default_install_indices[@]}"; do
        run_script "$i"
    done
else
    while IFS= read -r idx; do
        [ -n "$idx" ] || continue
        run_script "$idx"
    done <<EOF
$(echo "$input" | tr ' ' '\n' | grep -E '^[0-9]+$' || true)
EOF
fi
