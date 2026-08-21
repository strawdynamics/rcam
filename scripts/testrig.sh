#!/bin/bash
# Local RTSP test rig: mediamtx + two synthetic H.264 pushes (Homebrew ffmpeg,
# rig only — never ships).
#   rtsp://127.0.0.1:8554/test      1280x720@30, burned-in frame counter
#   rtsp://127.0.0.1:8554/test-sub   640x480@30 (4:3 → pillarbox), burned-in frame counter
# Idempotent: `start` kills any previous rig instance first.
set -euo pipefail
cd "$(dirname "$0")/.."

RIG_DIR=".testrig"
FFMPEG=/opt/homebrew/bin/ffmpeg
MEDIAMTX=/opt/homebrew/bin/mediamtx

stop_rig() {
  for pidfile in "$RIG_DIR"/*.pid; do
    [[ -f "$pidfile" ]] || continue
    kill "$(cat "$pidfile")" 2>/dev/null || true
    rm -f "$pidfile"
  done
  # Belt and braces for orphans from a previous checkout/session.
  pkill -f "mediamtx $PWD/$RIG_DIR/mediamtx.yml" 2>/dev/null || true
  pkill -f "rtsp://127.0.0.1:8554/test" 2>/dev/null || true
}

push() { # $1=size $2=path
  # testsrc (not testsrc2): burns a large running clock into the frame, which
  # doubles as the frame counter — this ffmpeg build has no drawtext filter.
  nohup "$FFMPEG" -hide_banner -loglevel warning \
    -re -f lavfi -i "testsrc=size=$1:rate=30" \
    -c:v libx264 -preset veryfast -tune zerolatency -g 30 -pix_fmt yuv420p \
    -f rtsp -rtsp_transport tcp "rtsp://127.0.0.1:8554/$2" \
    > "$RIG_DIR/push-$2.log" 2>&1 &
  echo $! > "$RIG_DIR/push-$2.pid"
}

case "${1:-}" in
  start)
    mkdir -p "$RIG_DIR"
    stop_rig
    cat > "$RIG_DIR/mediamtx.yml" <<EOF
logLevel: info
rtspAddress: :8554
rtmp: no
hls: no
webrtc: no
srt: no
paths:
  all_others:
EOF
    nohup "$MEDIAMTX" "$PWD/$RIG_DIR/mediamtx.yml" > "$RIG_DIR/mediamtx.log" 2>&1 &
    echo $! > "$RIG_DIR/mediamtx.pid"
    for _ in $(seq 1 50); do
      nc -z 127.0.0.1 8554 2>/dev/null && break
      sleep 0.2
    done
    nc -z 127.0.0.1 8554 || { echo "error: mediamtx did not open :8554" >&2; exit 1; }
    push 1280x720 test
    push 640x480 test-sub
    sleep 2
    echo "test rig up: rtsp://127.0.0.1:8554/test and /test-sub"
    ;;
  stop)
    stop_rig
    echo "test rig stopped"
    ;;
  stop-push)
    # Kill just one push (simulates a camera dying); mediamtx stays up.
    PATH_NAME="${2:?usage: testrig.sh stop-push <path>}"
    [[ -f "$RIG_DIR/push-$PATH_NAME.pid" ]] && kill "$(cat "$RIG_DIR/push-$PATH_NAME.pid")" 2>/dev/null || true
    rm -f "$RIG_DIR/push-$PATH_NAME.pid"
    echo "push $PATH_NAME stopped"
    ;;
  start-push)
    PATH_NAME="${2:?usage: testrig.sh start-push <path> [size]}"
    SIZE="${3:-1280x720}"
    push "$SIZE" "$PATH_NAME"
    echo "push $PATH_NAME started ($SIZE)"
    ;;
  *)
    echo "usage: testrig.sh {start|stop|stop-push <path>|start-push <path> [size]}" >&2
    exit 64
    ;;
esac
