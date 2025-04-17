#!/bin/bash

set -e

REALSRCMD="./realsr-ncnn"
REALCUGANCMD="./realcugan-ncnn"

TMP_DIR="tmp_frames"
OUT_DIR="out_frames"
LOG_FILE="upscaling.log"

print_model_info() {
  echo "Available Models and Capabilities:"
  echo
  echo "[realsr-ncnn]"
  echo "  models-ESRGAN-Nomos8kSC         => scale: 4"
  echo "  models-Real-ESRGAN              => scale: 4"
  echo "  models-Real-ESRGAN-anime        => scale: 4"
  echo "  models-Real-ESRGAN-animevideov3 => scale: 2, 3, 4"
  echo "  models-Real-ESRGANv2-anime      => scale: 2, 4"
  echo "  models-Real-ESRGANv3-anime      => scale: 2, 3, 4"
  echo "  models-Real-ESRGAN-plus         => scale: 4"
  echo "  models-Real-ESRGAN-plus-anime   => scale: 4"
  echo "  models-RealeSR-general-v3       => scale: 4"
  echo "  models-RealeSR-general-v3-wdn   => scale: 4"
  echo "  models-Real-ESRGAN-SourceBook   => scale: 2"
  echo
  echo "[realcugan-ncnn] (supports denoise)"
  echo "  models-nose => scale: 2 (no-denoise only)"
  echo "  models-pro  => scale: 2, 3 with denoise levels 0–3"
  echo "  models-se   => scale: 2, 3, 4 with denoise levels 0–3"
  echo
}

show_help() {
  cat <<EOF
Usage: $0 -i <input_video> -e <engine> -m <model> -s <scale> -o <output_name> [-n <denoise>] [--help]

Required:
  -i <input_video>   Input video file
  -e <engine>        Engine: realsr or realcugan
  -m <model>         Model name (relative to models/)
  -s <scale>         Scale factor (1/2/3/4 depending on model)
  -o <output_name>   Output file name (e.g., upscaled.mp4)

Optional (realcugan only):
  -n <denoise>       Denoise level (-1 to 3)

Other:
  --help             Show this help and model capabilities

EOF
  print_model_info
  exit 0
}

# Argument parsing
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    -i) INPUT_VIDEO="$2"; shift ;;
    -e) ENGINE="$2"; shift ;;
    -m) MODEL="$2"; shift ;;
    -s) SCALE="$2"; shift ;;
    -o) OUTPUT_NAME="$2"; shift ;;
    -n) DENOISE="$2"; shift ;;
    -h|--help) show_help ;;
    *) echo "Unknown option: $1"; show_help ;;
  esac
  shift
done

[[ -z "$INPUT_VIDEO" || -z "$ENGINE" || -z "$MODEL" || -z "$SCALE" || -z "$OUTPUT_NAME" ]] && show_help
[[ ! -f "$INPUT_VIDEO" ]] && { echo "Video not found: $INPUT_VIDEO"; exit 1; }

mkdir -p "$TMP_DIR" "$OUT_DIR"
> "$LOG_FILE"  # Clear log file

# Validate scale
validate_model_scale() {
  case "$MODEL" in
    models-Real-ESRGAN-animevideov3|models-Real-ESRGANv3-anime)
      [[ "$SCALE" =~ ^[234]$ ]] || { echo "Scale for $MODEL must be 2, 3, or 4"; exit 1; } ;;
    models-Real-ESRGANv2-anime)
      [[ "$SCALE" == "2" || "$SCALE" == "4" ]] || { echo "Scale for $MODEL must be 2 or 4"; exit 1; } ;;
    models-Real-ESRGAN-SourceBook)
      [[ "$SCALE" == "2" ]] || { echo "Scale for $MODEL must be 2"; exit 1; } ;;
    models-nose)
      [[ "$SCALE" == "2" ]] || { echo "models-nose only supports scale 2"; exit 1; }
      [[ -z "$DENOISE" || "$DENOISE" == "-1" ]] || { echo "models-nose only supports no-denoise"; exit 1; } ;;
    models-pro)
      [[ "$SCALE" == "2" || "$SCALE" == "3" ]] || { echo "models-pro supports scale 2 or 3"; exit 1; } ;;
    models-se)
      [[ "$SCALE" == "2" || "$SCALE" == "3" || "$SCALE" == "4" ]] || { echo "models-se supports scale 2, 3, or 4"; exit 1; } ;;
    *)
      [[ "$SCALE" == "4" ]] || { echo "Model $MODEL supports only scale 4"; exit 1; } ;;
  esac
}
validate_model_scale

FPS=$(ffmpeg -i "$INPUT_VIDEO" 2>&1 | grep -oP '(\d+(\.\d+)?) fps' | head -n1 | grep -oP '\d+(\.\d+)?')
[[ -z "$FPS" ]] && FPS=23.98

echo "[1/4] Extracting frames from video..."
ffmpeg -i "$INPUT_VIDEO" -qscale:v 1 -qmin 1 -qmax 1 -vsync 0 "$TMP_DIR/frame%08d.png"

FRAME_TOTAL=$(find "$TMP_DIR" -type f -name '*.png' | wc -l)
echo "[2/4] Upscaling $FRAME_TOTAL frames with $ENGINE..."

# Start upscaling in background
START_TIME=$(date +%s)
if [[ "$ENGINE" == "realsr" ]]; then
  $REALSRCMD -i "$TMP_DIR" -o "$OUT_DIR" -m models/"$MODEL" -s "$SCALE" -f jpg >> "$LOG_FILE" 2>&1 &
else
  [[ -z "$DENOISE" ]] && { echo "realcugan requires -n <denoise>"; exit 1; }
  $REALCUGANCMD -i "$TMP_DIR" -o "$OUT_DIR" -m models/"$MODEL" -s "$SCALE" -n "$DENOISE" -f jpg >> "$LOG_FILE" 2>&1 &
fi

PID=$!

# Progress and ETA
PREV_COUNT=0
PREV_TIME=$START_TIME

while kill -0 $PID 2>/dev/null; do
  COUNT=$(ls -U "$OUT_DIR"/*.jpg 2>/dev/null | wc -l)
  CURRENT_TIME=$(date +%s)
  ELAPSED=$((CURRENT_TIME - START_TIME))

  if (( COUNT > 0 )); then
    REMAINING=$((FRAME_TOTAL - COUNT))
    RATE=$(echo "$COUNT / $ELAPSED" | bc -l)
    ETA=$(echo "$REMAINING / $RATE" | bc -l)
    ETA_MINS=$(printf "%.0f" "$(echo "$ETA / 60" | bc -l)")
    ETA_SECS=$(printf "%.0f" "$(echo "$ETA % 60" | bc -l)")
    PERCENT=$((COUNT * 100 / FRAME_TOTAL))
    echo -ne "Upscaling: $PERCENT% ($COUNT/$FRAME_TOTAL) | ETA: ${ETA_MINS}m ${ETA_SECS}s\r"
  else
    echo -ne "Upscaling: 0% (0/$FRAME_TOTAL) | ETA: --m --s\r"
  fi

  sleep 1
done

echo -ne "Upscaling: 100% ($FRAME_TOTAL/$FRAME_TOTAL) | ETA: 0m 0s\n"

echo "[3/4] Rebuilding video..."
ffmpeg -r "$FPS" -i "$OUT_DIR/frame%08d.jpg" -i "$INPUT_VIDEO" -map 0:v:0 -map 1:a:0 \
  -c:a copy -c:v libx264 -r "$FPS" -pix_fmt yuv420p "$OUTPUT_NAME"

echo "[4/4] Cleaning up..."
rm -rf "$TMP_DIR" "$OUT_DIR"
