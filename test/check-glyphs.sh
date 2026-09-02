#!/bin/bash
# Verify every codepoint in lib/Icons.js exists in the bar's font, and that no
# raw private-use characters have crept into the source.
#
# Both checks matter. A missing codepoint renders as a tofu box; a raw glyph
# character pasted into source can be silently dropped in transit (the
# U+F000-U+F8FF range is especially fragile), leaving an empty string, an
# invisible control, and no error anywhere.
#
# Needs fonttools:  python3 -m venv .venv && .venv/bin/pip install fonttools
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PY_BIN="${PYTHON:-python3}"
# Font resolution: $FONT env or a file path argument wins (CI passes the
# downloaded TTF directly); otherwise ask fontconfig for the monospace face.
if [[ ! -f ${FONT:-} ]]; then
  if [[ -f ${1:-} ]]; then FONT="$1"; else FONT=$(fc-match -f '%{file}' "${1:-monospace}"); fi
fi
echo "font: $FONT"

"$PY_BIN" - "$FONT" "$ROOT" <<'PYEOF'
import re, sys, glob, os
try:
    from fontTools.ttLib import TTFont
except ImportError:
    print("fonttools is required (the fonttools Python package)", file=sys.stderr)
    sys.exit(2)

font_path, root = sys.argv[1], sys.argv[2]
icons = open(os.path.join(root, "lib", "Icons.js"), encoding="utf-8").read()

# Each entry is `name: 0xCODE,  // nerd-font-glyph-name`. Verify BOTH that the
# codepoint is in the font and that it still maps to the glyph we named. A
# codepoint alone proves nothing: U+F0B0E exists but is md-alpha_g_box, not
# md-broadcast.
by_codepoint = {}
for table in TTFont(font_path, fontNumber=0)['cmap'].tables:
    by_codepoint.update(table.cmap)

entries = re.findall(r'^\s*(\w+)\s*:\s*0x([0-9A-Fa-f]+)\s*,\s*//\s*([\w.-]+)\s*$',
                     icons, re.M)
unannotated = re.findall(r'^\s*(\w+)\s*:\s*0x([0-9A-Fa-f]+)\s*,\s*$', icons, re.M)

missing, mismatched = [], []
for name, cp_hex, expected in entries:
    cp = int(cp_hex, 16)
    actual = by_codepoint.get(cp)
    if actual is None:
        missing.append((name, cp))
    elif actual != expected:
        mismatched.append((name, cp, expected, actual))

print(f"{len(entries)} annotated codepoints checked")
for name, cp in missing:
    print(f"  MISSING  {name} U+{cp:05X} is not in this font")
for name, cp, expected, actual in mismatched:
    print(f"  MISMATCH {name} U+{cp:05X} is '{actual}', not '{expected}'")
for name, cp_hex in unannotated:
    print(f"  UNVERIFIED {name} 0x{cp_hex} has no // glyph-name comment")

# Every icon name referenced anywhere must be a key of CP: Icons.g() returns
# "" for an unknown name with no warning, which is the same invisible-control
# failure the codepoint checks above guard against, one layer up.
declared_names = set(name for name, _, _ in entries)
used = set()
sources = glob.glob(os.path.join(root, "*.qml")) + [
    os.path.join(root, "lib", "Detect.js"),
]
for path in sources:
    text = open(path, encoding="utf-8").read()
    # Capture the whole argument span: Icons.g(cond ? "a" : "b") must
    # contribute both names, not silently none.
    for m in re.finditer(r'Icons\.g\(([^)]*)\)', text):
        # Comparison literals inside the call (status === "setup") are
        # not icon names; strip them before harvesting.
        span = re.sub(r'[!=]==?\s*"\w+"', '', m.group(1))
        for name in re.findall(r'"(\w+)"', span):
            used.add(name)
    if path.endswith("Detect.js"):
        for m in re.finditer(r'icon:\s*"(\w+)"', text):
            used.add(m.group(1))

unknown_names = sorted(used - declared_names)
print(f"{len(used)} icon names referenced across QML/Detect.js, {len(unknown_names)} unknown")
for n in unknown_names:
    print(f"  UNKNOWN NAME '{n}' is not a key of Icons.js CP")

# No raw private-use characters outside Icons.js.
stray = []
for path in glob.glob(os.path.join(root, "*.qml")) + glob.glob(os.path.join(root, "lib", "*.js")) \
        + glob.glob(os.path.join(root, "scripts", "*")):
    if os.path.basename(path) == "Icons.js" or not os.path.isfile(path):
        continue
    try:
        text = open(path, encoding="utf-8").read()
    except (UnicodeDecodeError, IsADirectoryError):
        continue
    for ch in text:
        cp = ord(ch)
        if 0xE000 <= cp <= 0xF8FF or 0xF0000 <= cp <= 0xFFFFD:
            stray.append((os.path.relpath(path, root), cp))
            break

if stray:
    print(f"\n{len(stray)} file(s) contain raw private-use glyphs; use Icons.g(\"name\") instead:")
    for path, cp in stray:
        print(f"  {path}  (first at U+{cp:05X})")

sys.exit(1 if (missing or mismatched or unannotated or unknown_names or stray) else 0)
PYEOF
