#!/bin/bash

# ==================================================================================
# Manim 并发渲染脚本 - 精简安全版本
# 用途: 并发渲染多个场景并合并为最终视频
# ==================================================================================

set -euo pipefail  # 严格模式：错误退出、未定义变量报错、管道错误传播

# === 全局变量 ===
readonly SCENES=("Intro" "AnalyzePattern" "FindSolution" "VerifyAnswer" "Summary")
declare -a RENDER_PIDS=()
declare -a FAILED_SCENES=()
TEMP_FILES=()

# === 清理函数 ===
cleanup() {
    local exit_code=$?
    
    # 终止所有后台渲染进程
    for pid in "${RENDER_PIDS[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            echo "🛑 终止渲染进程 $pid"
            kill "$pid" 2>/dev/null || true
        fi
    done
    
    # 清理临时文件（如果不保留）
    if [[ "${KEEP_TEMP:-false}" == "false" ]]; then
        for temp_file in "${TEMP_FILES[@]}"; do
            [[ -f "$temp_file" ]] && rm -f "$temp_file"
        done
    fi
    
    exit $exit_code
}

# 注册清理函数
trap cleanup EXIT INT TERM

# === 参数验证 ===
usage() {
    cat << EOF
用法: $0 <manim_path> <py文件路径> <manim_media_dir> <输出视频路径> <清晰度> [帧率] [--keep-temp]

参数说明:
  manim_path     - manim可执行文件路径
  py文件路径     - Python脚本文件路径
  manim_media_dir - manim工作目录
  输出视频路径   - 最终输出的视频文件路径
  清晰度         - 渲染清晰度 (ql|qm|qh|qk)
  帧率          - 可选，视频帧率
  --keep-temp   - 可选，保留临时文件

示例:
  $0 /usr/local/bin/manim lesson.py /data/manim final.mp4 qh 30 --keep-temp
EOF
}

if [[ $# -lt 5 ]]; then
    usage
    exit 1
fi

# 解析参数
readonly MANIM_PATH="$1"
readonly PY_FILE="$2"
readonly MEDIA_DIR="$3"
readonly OUTPUT_VIDEO="$4"
readonly CLARITY="$5"
readonly FRAMERATE="${6:-}"

# 检查是否保留临时文件
KEEP_TEMP=false
[[ "$*" == *"--keep-temp"* ]] && KEEP_TEMP=true

# 验证输入文件
[[ -x "$MANIM_PATH" ]] || { echo "❌ manim程序不存在或不可执行: $MANIM_PATH"; exit 1; }
[[ -f "$PY_FILE" ]] || { echo "❌ Python文件不存在: $PY_FILE"; exit 1; }
if [[ ! -d "$MEDIA_DIR" ]]; then
    echo "📁 媒体目录不存在，正在创建: $MEDIA_DIR"
    mkdir -p "$MEDIA_DIR" || { echo "❌ 创建媒体目录失败: $MEDIA_DIR"; exit 1; }
    echo "✅ 媒体目录创建成功"
fi

# 获取脚本基本名称
readonly BASENAME=$(basename "$PY_FILE" .py)

# === 清晰度配置 ===
case "$CLARITY" in
    ql) QUALITY_FLAG="-ql"; RESOLUTION_DIR="480p15" ;;
    qm) QUALITY_FLAG="-qm"; RESOLUTION_DIR="720p30" ;;
    qh) QUALITY_FLAG="-qh"; RESOLUTION_DIR="1080p60" ;;
    qk) QUALITY_FLAG="-qk"; RESOLUTION_DIR="2160p60" ;;
    *) echo "❌ 未知清晰度: $CLARITY (支持: ql|qm|qh|qk)"; exit 1 ;;
esac

# === 核心函数 ===

# 预创建 manim 工作子目录
prepare_manim_directories() {
    echo "📂 预创建 manim 工作子目录..."
    
    local directories=(
        "$MEDIA_DIR/images/$BASENAME"
        "$MEDIA_DIR/Tex"
        "$MEDIA_DIR/texts"
        "$MEDIA_DIR/videos/$BASENAME"
    )
    
    for dir in "${directories[@]}"; do
        if [[ ! -d "$dir" ]]; then
            echo "  📁 创建目录: $dir"
            mkdir -p "$dir" || { echo "❌ 创建目录失败: $dir"; exit 1; }
        else
            echo "  ✅ 目录已存在: $dir"
        fi
    done
    
    echo "✅ manim 工作目录准备完成"
}

# 校验 dvisvgm 版本
check_dvisvgm_version() {
    echo "🔍 检查 dvisvgm 版本..."
    
    if ! command -v dvisvgm &> /dev/null; then
        echo "❌ dvisvgm 未安装或不在 PATH 中"
        exit 1
    fi
    
    local version_output=$(dvisvgm --version 2>&1 | head -1)
    local version=$(echo "$version_output" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)
    
    if [[ -z "$version" ]]; then
        echo "❌ 无法获取 dvisvgm 版本信息"
        exit 1
    fi
    
    # 版本比较：要求版本 > 2.4
    if [[ $(echo "$version 2.4" | awk '{print ($1 > $2)}') -eq 1 ]]; then
        echo "✅ dvisvgm 版本检查通过: $version (> 2.4)"
    else
        echo "❌ dvisvgm 版本过低: $version (需要 > 2.4)"
        exit 1
    fi
}

# 渲染单个场景
render_scene() {
    local scene="$1"
    local cmd_args=("$PY_FILE" "$scene" "$QUALITY_FLAG" --media_dir "$MEDIA_DIR")
    
    # 添加帧率参数（如果指定且不是--keep-temp）
    if [[ -n "$FRAMERATE" && "$FRAMERATE" != "--keep-temp" ]]; then
        cmd_args+=(--fps "$FRAMERATE")
    fi
    
    # 执行渲染命令
    "$MANIM_PATH" "${cmd_args[@]}"
}

# 等待所有渲染完成
wait_all_renders() {
    local failed_count=0
    
    echo "⏳ 等待 ${#RENDER_PIDS[@]} 个渲染任务完成..."
    
    for i in "${!RENDER_PIDS[@]}"; do
        local pid="${RENDER_PIDS[i]}"
        local scene="${SCENES[i]}"
        
        if wait "$pid"; then
            echo "✅ $scene 渲染完成"
        else
            echo "❌ $scene 渲染失败"
            FAILED_SCENES+=("$scene")
            ((failed_count++))
        fi
    done
    
    if [[ $failed_count -gt 0 ]]; then
        echo "💥 $failed_count 个场景渲染失败: ${FAILED_SCENES[*]}"
        exit 1
    fi
    
    echo "🎉 所有场景渲染成功!"
}

# 合并视频
merge_videos() {
    echo "⏱️  开始计时 - 视频合并阶段"
    local merge_start_time=$(date +%s)
    
    local list_file="$MEDIA_DIR/videos/$BASENAME/list.txt"
    TEMP_FILES+=("$list_file")
    
    echo "📝 生成合并列表..."
    mkdir -p "$(dirname "$list_file")"
    
    # 生成文件列表
    for scene in "${SCENES[@]}"; do
        local video_path="$MEDIA_DIR/videos/$BASENAME/$RESOLUTION_DIR/${scene}.mp4"
        if [[ ! -f "$video_path" ]]; then
            echo "❌ 场景视频文件不存在: $video_path"
            exit 1
        fi
        echo "file '$video_path'" >> "$list_file"
    done
    
    echo "🔗 合并视频..."
    local ffmpeg_args=(-y -f concat -safe 0 -i "$list_file")
    
    # 尝试无损合并
    if ffmpeg "${ffmpeg_args[@]}" -c copy "$OUTPUT_VIDEO" 2>/dev/null; then
        echo "✅ 合并成功 (无损模式)"
    else
        echo "⚠️ 无损合并失败，使用转码模式..."
        ffmpeg_args+=(-c:v libx264 -crf 18 -preset fast -pix_fmt yuv420p)
        
        # 添加帧率参数（如果指定）
        if [[ -n "$FRAMERATE" && "$FRAMERATE" != "--keep-temp" ]]; then
            ffmpeg_args+=(-r "$FRAMERATE")
        fi
        
        ffmpeg "${ffmpeg_args[@]}" "$OUTPUT_VIDEO"
        echo "✅ 合并成功 (转码模式)"
    fi
    
    local merge_end_time=$(date +%s)
    local merge_duration=$((merge_end_time - merge_start_time))
    echo "✅ 视频合并完成，用时: ${merge_duration}秒"
    echo "📁 输出文件: $OUTPUT_VIDEO"
}

# === 主执行流程 ===
main() {
    echo "🚀 开始并发渲染 ${#SCENES[@]} 个场景 (清晰度: $CLARITY)"
    
    # 预创建工作目录以避免并发冲突
    prepare_manim_directories
    
    # 校验 dvisvgm 版本
    check_dvisvgm_version
    
    # 启动所有渲染任务
    echo "⏱️  开始计时 - 并发渲染阶段"
    local render_start_time=$(date +%s)
    
    for scene in "${SCENES[@]}"; do
        echo "🎬 启动渲染: $scene"
        render_scene "$scene" &
        RENDER_PIDS+=($!)
    done
    
    # 等待所有任务完成
    wait_all_renders
    
    local render_end_time=$(date +%s)
    local render_duration=$((render_end_time - render_start_time))
    echo "✅ 并发渲染完成，用时: ${render_duration}秒"
    
    # 合并视频
    merge_videos
    
    echo "🎊 渲染完成! 总用时: ${SECONDS}秒"
}

# 执行主函数
main "$@"
