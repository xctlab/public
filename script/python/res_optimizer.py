#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
图片和Lottie文件压缩工具

功能：
- 遍历指定目录, 压缩png、jpg、webp等图片文件, 支持pngquant和webp压缩方式
- 解析并压缩lottie动画中的内嵌图片资源
- 跳过已压缩过且未修改的文件，提升处理效率, 避免重复压缩
- 自动向上查找包含Gradle构建文件的项目根目录, 记录到optimize_files.txt

用法：
    python res_optimizer.py <目标目录>

示例：
    python res_optimizer.py app/src/main

依赖：
- Python 3.6+
- Pillow(PIL)
- zopfli(无损压缩算法实现, 需预先安装)
- pngquant(命令行工具, 需预先安装)
- cwebp(命令行工具, 需预先安装)

依赖：
- Python 3.6+
- Python 库：
    - Pillow (图像处理): pip install pillow
    - zopfli(无损 PNG 压缩): pip install zopfli
- 外部命令行工具（需预先安装，确保可执行）：
    - pngquant (有损 PNG 压缩): https://pngquant.org
        - macOS: brew install pngquant
        - Ubuntu: sudo apt install pngquant
    - cwebp (WebP 压缩工具): https://developers.google.com/speed/webp
        - macOS: brew install webp
        - Ubuntu: sudo apt install webp

注意：
- 请确保 pngquant 和 cwebp 命令在系统 PATH 中可用
- 仅处理图片和Lottie JSON文件,其他文件自动跳过
- 建议使用未压缩的原文件进行处理, 效果最好。压缩过的再次压缩会导致质量更差
- 记得保存optimize_files.txt文件, 不要删除, 避免重复压缩导致质量降低
- 图片格式可能会发生变化, 需注意检查路径变化(例如assets中的图片)
- 如果需要设置白名单, 请添加`file_path|*`到optimize_files.txt文件中
"""

import argparse
import base64
import hashlib
import io
import json
import os
import re
import subprocess
from functools import partial
from pathlib import Path
from typing import Optional, Tuple
from concurrent.futures import ThreadPoolExecutor
import fcntl
import mimetypes

from PIL import Image
import zopfli

RECORD_FILE = "compressed_files.txt"

def calc_file_hash(file_path: str) -> str:
    """计算文件的 SHA256 哈希"""
    sha256 = hashlib.sha256()
    with open(file_path, "rb") as f:
        for chunk in iter(lambda: f.read(8192), b""):
            sha256.update(chunk)
    return sha256.hexdigest()

# 压缩图像, 如果压缩后的大小比原来大，那么会返回None
def compress_image_data(in_data:bytes) -> Optional[Tuple[str, bytes]]:
    # 判断是否为png图片数据
    def is_png(data: bytes) -> bool:
        png_signature = b'\x89PNG\r\n\x1a\n'
        return data.startswith(png_signature)

    # 使用pngquant压缩
    def png_quant(in_data: bytes) -> Optional[bytes]:
        # 命令行参数
        command = ['pngquant', '--quality=60-80', '--speed=1', '--strip', '--skip-if-larger', '-']
        # 调用pngquant并重定向输入和输出
        process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        output, _ = process.communicate(input=in_data)
        # 等待进程完成，并获取退出码
        return_code = process.wait()
        # 退出码不为0，执行失败
        if return_code != 0 or output is None:
            return None

        # zopflipng再次压缩
        c = zopfli.ZopfliPNG(
            verbose=False,
            filter_strategies="01234mepb",   # 尝试所有滤镜
            iterations=50,                   # 最大迭代次数
            iterations_large=50,
            use_zopfli=True,                 # 启用Zopfli压缩
            keep_color_type=True,            # 保持颜色类型，避免色彩损失
            lossy_transparent=False,         # 不做透明有损处理，保持无损
            lossy_8bit=False,                # 不做8位色有损处理
            auto_filter_strategy=False       # 手动指定滤镜策略
        )
        c_output = c.optimize(output)
        if len(c_output) < len(output):
            output = c_output
        if len(output) < len(in_data):
            return output
        else:
            return None

    def png_quant_safe(img: Image.Image, origin_data: bytes) -> Optional[bytes]:
        if is_png(origin_data):
            return png_quant(origin_data)
        else:
            with io.BytesIO() as output:
                img.save(output, format="PNG")
                png_bytes = output.getvalue()
                png_bytes = png_quant(png_bytes)
                if png_bytes is None or len(png_bytes) >= len(origin_data):
                    return origin_data
                else:
                    return png_bytes

    # 使用webp压缩
    def img_to_webp(in_data: bytes) -> Optional[bytes]:
        # https://developers.google.com/speed/webp/docs/cwebp?hl=zh-cn
        command = ['cwebp', '-quiet', '-q', '75', '-m', '6', '-pass', '10', '-mt', '-o', '-', '--', '-']
        # 调用pngquant并重定向输入和输出
        process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        output, _ = process.communicate(input=in_data)
        # 等待进程完成，并获取退出码
        return_code = process.wait()
        # 退出码不为0，执行失败
        if return_code != 0:
            return None
        # 数据比原来的小，才算成功
        if len(output) < len(in_data):
            return output
        else:
            return None

    # 判断图片色彩是否丰富
    def is_colorful(img: Image.Image) -> bool:
        if img.format == "PNG" and img.mode == "P":
            return False
        else:
            return img.getcolors(256 * 10) is None

    with Image.open(io.BytesIO(in_data)) as img:
        is_animated: bool = getattr(img, "is_animated")
        if is_animated:
            # todo：动图暂时不支持优化
            # n_frames = getattr(img, "is_animated")
            return None
        else:
            # 调色板模式，颜色不会太丰富，则可以使用pngquant
            if is_colorful(img):
                data = img_to_webp(in_data)
                if data is None:
                    return None
                else:
                    return "image/webp", data
            else:
                with ThreadPoolExecutor() as executor:
                    future1 = executor.submit(png_quant_safe, img, in_data)
                    future2 = executor.submit(img_to_webp, in_data)
                    results = [
                        ("image/png", future1.result()),
                        ("image/webp", future2.result())
                    ]
                    valid_results = [
                        (type, data) for type, data in results
                        if data is not None
                    ]
                    if valid_results:
                        type, data = min(valid_results, key=lambda x: len(x[1]))
                        if len(data) >= len(in_data):
                            return None
                        else:
                            return type, data
                    else:
                        return None

# 压缩图片文件[修改后的文件路径，是否修改成功]
def compress_image_file(file_path: str) -> Tuple[str, bool]:
    with open(file_path, 'rb') as f:
        file_bytes = f.read()
    compress_result = compress_image_data(file_bytes)
    if compress_result is None:
        return file_path, False
    else:
        type, new_data = compress_result

        ext = mimetypes.guess_extension(type)
        if ext is None:
            raise ValueError(f"无法解析mimeType: {ext}")
        new_path = os.path.splitext(file_path)[0] + ext

        with open(new_path, "wb") as f:
                f.write(new_data)
                f.flush()
                os.fsync(f.fileno())
        if os.path.abspath(file_path) != os.path.abspath(new_path):
            # 移除旧文件
            os.remove(file_path)
        return new_path, True

# 压缩lottie文件[修改后的文件路径，是否修改成功]
def compress_lottie(lottie: dict, output: str) -> Tuple[str, bool]:
    has_compressed = False
    # https://lottiefiles.github.io/lottie-docs/assets/
    assets: list = lottie["assets"]
    if assets is not None:
        for item in assets:
            # e	0-1 integer 文件是否嵌入
            if item.get("e") == 1:
                asset_data = item["p"]
                match = re.match(r"data:image/(?P<format>\w+);base64,(?P<data>\S+)", asset_data)
                if match is None:
                    continue
                results = match.groupdict()

                # file_format = results["format"]
                base64_data = results["data"]
                byte_data = base64.b64decode(base64_data)
                compress_result = compress_image_data(byte_data)
                if compress_result is not None:
                    mime_type, new_data = compress_result
                    item["p"] = f"data:{mime_type};base64,{base64.b64encode(new_data).decode()}"
                    has_compressed = True
    if has_compressed:
        json_result = json.dumps(lottie, separators=(',', ':'), ensure_ascii=False)
        with open(output, "w") as f:
            f.write(json_result)
            f.flush()
            os.fsync(f.fileno())
        return output, True
    else:
        return output, False

def find_gradle_dir(start_path: str) -> Path:
    """从 start_path 向上查找包含 build.gradle 或 build.gradle.kts 的目录"""
    current = Path(start_path).resolve()
    while current != current.parent:
        if (current / "build.gradle").exists() or (current / "build.gradle.kts").exists():
            return current
        current = current.parent
    raise FileNotFoundError("未找到包含 build.gradle 或 build.gradle.kts 的上级目录")

def compress_directory(directory: str, no_optimize: bool = False):
    def load_record(path: str) -> dict[str, str]:
        record_dir = os.path.dirname(path)
        record: dict[str, str] = {}
        if os.path.exists(path):
            with open(path, "r") as f:
                for line in f:
                    line = line.strip()
                    if not line or "|" not in line:
                        continue
                    file_path, file_hash = map(str.strip, line.split("|", 1))
                    file_path = os.path.abspath(os.path.join(record_dir, file_path))
                    record[file_path] = file_hash
        return record

    def write_record(record_path: str, record: dict[str, str]):
        record_dir = os.path.dirname(record_path)
        with open(record_path, "w", encoding="utf-8") as f:
            # 加文件锁（独占锁）
            fcntl.flock(f, fcntl.LOCK_EX)
            try:
                for (path, file_hash) in record.items():
                    # 如果目标文件存在才写入
                    if os.path.exists(path) or file_hash == '*':
                        file_path = os.path.relpath(path, record_dir)
                        f.write(f"{file_path}|{file_hash}\n")
                f.flush()
                os.fsync(f.fileno())
            finally:
                fcntl.flock(f, fcntl.LOCK_UN)  # 释放锁

    record_path = os.path.join(find_gradle_dir(directory), RECORD_FILE)
    record = load_record(record_path)

    # 先收集所有已记录的hash集合，方便快速判断
    recorded_hashes = set(record.values())

    def is_image_file(file_path: str) -> bool:
        image_exts = {'.png', '.jpg', '.jpeg', '.webp', '.bmp'}
        ext = os.path.splitext(file_path)[1].lower()
        return ext in image_exts
    
    def is_nine_patch_png(filename: str) -> bool:
        return os.path.basename(filename).lower().endswith('.9.png')

    def load_lottie_file(file_path: str) -> Optional[dict]:
        if not file_path.endswith(".json"):
            return None
        with open(file_path, 'r', encoding='utf-8') as lottie_file:
            lottie = json.load(lottie_file)
        # https://lottiefiles.github.io/lottie-docs/animation/
        # 以下是 Lottie JSON 文件中一些关键的必需字段：
        # fr: 动画的帧率。
        # w: 动画的宽度。
        # h: 动画的高度。
        # layers: 一个包含所有动画层的数组。每个层都有自己的属性，如位置、缩放、旋转、锚点、透明度等，并且可能有自己的嵌套层。
        required_fields = ["v", "fr", "w", "h", "layers"]
        if all(field in lottie for field in required_fields):
            return lottie
        else:
            # raise ValueError(f"错误：无效的lottie文件：{file_path}")
            return None

    def procress_file(file_path: str):
        if is_nine_patch_png(file_path):
            # 9.png不需要处理
            return
        elif is_image_file(file_path):
            # 处理图片文件
            action = partial(compress_image_file, file_path)
        else:
            # 处理lottie json文件
            lottie = load_lottie_file(file_path)
            if lottie is not None:
                action = partial(compress_lottie, lottie, file_path)
            else:
                return

        current_hash = calc_file_hash(file_path)

        if file_path in record and record[file_path] == current_hash:
            # 文件路径和哈希都一样，跳过
            # print(f"Skipped (unchanged): {file_path}")
            return

        if current_hash in recorded_hashes:
            # 同样hash的文件之前已压缩，跳过压缩，但加入记录
            print(f"Skipped (hash exists): {file_path}")
            record[file_path] = current_hash
            return

        if no_optimize:
            record[file_path] = current_hash
            return

        # 执行压缩
        new_path, is_compressed = action()
        if is_compressed:
            if file_path == new_path:
                print(f"Compressed: {file_path}")
            else:
                print(f"Compressed and replaced: {file_path} -> {new_path}")

            # 压缩后重新计算hash（根据你的流程）
            new_hash = calc_file_hash(new_path)

            # 文件已被修改到其他路径，删除旧记录
            if file_path != new_path and file_path in record:
                del record[file_path]

            record[new_path] = new_hash
            recorded_hashes.add(new_hash)
        else:
            # print(f"No compression needed for: {file_path}")
            pass

    all_files = []
    for root, _, files in os.walk(directory):
        for name in files:
            full_path = os.path.abspath(os.path.join(root, name))
            # *表示白名单，不作处理
            if full_path in record and record[full_path] == '*':
                # print(f"{full_path} skipped.")
                pass
            else:
                all_files.append(full_path)

    with ThreadPoolExecutor() as executor:
        for file_path in all_files:
            executor.submit(procress_file, file_path)

    write_record(record_path, record)

    print(f"Done. Record saved to {record_path}")

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--no-optimize", action="store_true", help="只记录，不进行任何优化")
    parser.add_argument("target_dir", help="要处理的目录路径")
    args = parser.parse_args()
    compress_directory(args.target_dir, no_optimize = args.no_optimize)