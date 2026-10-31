#!/bin/bash
# Records the README animations from the real app, filled with fictional demo data (nothing from this Mac).
# Needs ffmpeg. Prune briefly comes to the front while it steps through each scenario.
set -euo pipefail
cd "$(dirname "$0")/.."

./build.sh >/dev/null
OUT="docs/media"
SHOTS="$(mktemp -d)"
trap 'rm -rf "$SHOTS"' EXIT
pkill -x Prune 2>/dev/null || true
build/Prune.app/Contents/MacOS/Prune -PruneDemo YES -PruneShots "$SHOTS" -ApplePersistenceIgnoreState YES >/dev/null 2>&1
[ -f "$SHOTS/DONE" ] || { echo "Capture did not finish"; exit 1; }

mkdir -p "$OUT"
rm -f "$OUT"/*.svg "$OUT"/*.gif "$OUT"/*.png
gif() { # scene, output, extra filter
  ffmpeg -loglevel error -y -f concat -safe 0 -i "$SHOTS/$1/list.txt" -fps_mode vfr \
    -vf "${3:-}scale=${4:-1200}:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=256:stats_mode=full[p];[b][p]paletteuse=dither=sierra2_4a" \
    -loop 0 "$OUT/$2.gif"
}
gif overview scan-and-clean
gif drives every-drive
gif secrets secrets
gif backup code-backup
gif doctor doctor-and-extensions
gif explainer how-it-works "crop=1050:185:300:52," 1000
for still in overview-dark secrets-dark timeline maintenance about; do
  sips -Z 1400 "$SHOTS/$still.png" --out "$OUT/$still.png" >/dev/null
done
ls -lh "$OUT"
