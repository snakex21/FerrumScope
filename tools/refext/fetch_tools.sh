#!/usr/bin/env bash
# fetch_tools.sh — pobiera zewnętrzne narzędzia analityczne do tools/refext/bin/.
# Narzędzia NIE są częścią FerrumScope; służą wyłącznie do analizy referencyjnych
# binariów (CPU-Z / GPU-Z) i nie są dystrybuowane wraz z projektem.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$here/bin"

if command -v upx >/dev/null 2>&1; then
  echo "[ok] upx jest już w PATH: $(command -v upx)"
  exit 0
fi

ver="${UPX_VERSION:-5.2.1}"
url="https://github.com/upx/upx/releases/download/v${ver}/upx-${ver}-win64.zip"
out="$here/bin/upx-${ver}-win64.zip"

echo "[pobieram] $url"
python - "$url" "$out" <<'PY'
import sys, urllib.request, zipfile
url, out = sys.argv[1], sys.argv[2]
with urllib.request.urlopen(url, timeout=180) as r:
    data = r.read()
with open(out, "wb") as fh:
    fh.write(data)
zipfile.ZipFile(out).extractall(__import__("os").path.dirname(out))
print("[ok] rozpakowano do", out)
PY

rm -f "$out"
echo "[ok] gotowe. Uruchom: python tools/refext/harvest_ref.py --all"
