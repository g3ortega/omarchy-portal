#!/bin/bash
# Everything that can be checked without a running shell.
#
# Runs identically on a developer machine (Omarchy installed) and in CI
# (no Omarchy, no Quickshell). Environment knobs, all optional:
#   OMARCHY_PATH  Omarchy source/install root (default /usr/share/omarchy).
#                 CI points this at a shallow clone of omacom/omarchy to get
#                 the manifest validator and the qs.* QML modules.
#   FONT          Path to the Nerd Font TTF for the glyph check (default:
#                 fc-match monospace).
#   PYTHON        Python with fonttools available (default python3).
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
S="$ROOT/scripts"
OMARCHY_PATH="${OMARCHY_PATH:-/usr/share/omarchy}"
fails=0
step() { printf '\n\033[1m== %s\033[0m\n' "$1"; }

step "shell script syntax"
for f in "$S"/*.sh "$S"/lib/*.sh "$S/portal" "$HERE"/*.sh; do
  bash -n "$f" && echo "  ok   $(basename "$f")" || { echo "  FAIL $(basename "$f")"; fails=$((fails+1)); }
done

step "manifest schema"
# Prefer the installed CLI; fall back to the validator script inside an Omarchy
# checkout — it is self-contained bash + jq, which is how CI runs this.
if command -v omarchy >/dev/null 2>&1; then
  omarchy plugin validate "$ROOT" && echo "  ok   manifest.json" || fails=$((fails+1))
elif [[ -x "$OMARCHY_PATH/bin/omarchy-plugin-validate" ]]; then
  "$OMARCHY_PATH/bin/omarchy-plugin-validate" "$ROOT" && echo "  ok   manifest.json (validator from $OMARCHY_PATH)" || fails=$((fails+1))
else
  echo "  FAIL no validator: install Omarchy or set OMARCHY_PATH to a checkout"; fails=$((fails+1))
fi

step "detection unit tests"
for f in "$HERE"/*.test.mjs; do
  node "$f" || fails=$((fails+1))
done

step "shell library unit tests"
for f in "$HERE"/*.test.sh; do
  bash "$f" || fails=$((fails+1))
done

step "port scan produces valid JSON"
if "$S/scan-ports.sh" | jq -e '.version == 1 and (.ports | type == "array")' >/dev/null; then
  echo "  ok   scan-ports.sh"
else
  echo "  FAIL scan-ports.sh"; fails=$((fails+1))
fi

step "setup engine produces a valid report"
if "$S/portless-setup.sh" status | jq -e '.ok == true and (.checks | has("proxy")) and (.remaining | type == "array")' >/dev/null; then
  echo "  ok   portless-setup.sh"
else
  echo "  FAIL portless-setup.sh"; fails=$((fails+1))
fi

step "provider detection produces valid JSON"
# The expected count comes from the PROVIDERS roster itself, so adding a
# provider is not a third place to edit.
want=$(grep -cE '^\s*"[a-z-]+:[^:]*:(public|local)"' "$S/tunnels.sh")
if ! [[ $want =~ ^[1-9][0-9]*$ ]]; then
  echo "  FAIL could not read the PROVIDERS roster out of tunnels.sh"; fails=$((fails+1))
elif "$S/tunnels.sh" providers | jq -e --argjson n "$want" '.ok == true and (.providers | length == $n)' >/dev/null; then
  echo "  ok   tunnels.sh providers ($want providers)"
else
  echo "  FAIL tunnels.sh providers"; fails=$((fails+1))
fi

step "qmllint"
if command -v qmllint >/dev/null 2>&1; then QMLLINT=qmllint
elif [[ -x /usr/lib/qt6/bin/qmllint ]]; then QMLLINT=/usr/lib/qt6/bin/qmllint
else QMLLINT=""; fi
if [[ -n $QMLLINT && -d "$OMARCHY_PATH/shell" ]]; then
  # qmllint cannot resolve Quickshell's `qs.*` module rooting, so build a shim
  # tree where qs/Ui and qs/Commons exist as real paths. Kept outside the
  # plugin folder: the validator refuses symlinks inside it.
  SHIM=$(mktemp -d)
  mkdir -p "$SHIM/qs"
  ln -s "$OMARCHY_PATH/shell/Ui" "$SHIM/qs/Ui"
  ln -s "$OMARCHY_PATH/shell/Commons" "$SHIM/qs/Commons"

  # Two warning classes are unavoidable and also present in Omarchy's own
  # first-party plugins: qmllint cannot introspect Style's nested QtObject
  # singletons, and Quickshell's Process exposes a type it cannot resolve.
  FILTER='not found on type "QObject"|QProcess::ExitStatus'

  # CI has no Quickshell QML modules. Without them, import failures cascade
  # into unresolved-type noise, so lint degrades to syntax-and-error-only
  # rather than pretending the noise is signal. Detection is a filesystem
  # check — qmllint's missing-import message wording varies too much across
  # Qt versions to parse. Override with QMLLINT_STRICT=1/0 if needed.
  if [[ -n ${QMLLINT_STRICT:-} ]]; then
    STRICT="$QMLLINT_STRICT"
  else
    QTPATHS=$(command -v qtpaths6 || command -v qtpaths || echo /usr/lib/qt6/bin/qtpaths)
    QML_ROOT=$("$QTPATHS" --query QT_INSTALL_QML 2>/dev/null || true)
    if [[ -n $QML_ROOT && -d "$QML_ROOT/Quickshell" ]]; then
      STRICT=1
    else
      echo "  (Quickshell QML modules not found under ${QML_ROOT:-the Qt QML root} — checking syntax and errors only)"
      STRICT=0
    fi
  fi

  for f in "$ROOT"/*.qml; do
    if [[ $STRICT == 1 ]]; then
      out=$("$QMLLINT" -I "$SHIM" -I "$OMARCHY_PATH/shell" "$f" 2>&1 \
        | grep -E '^(Warning|Error)' | grep -vE "$FILTER")
    else
      # Older qmllint has no [syntax] tag; match the messages themselves.
      out=$("$QMLLINT" -I "$SHIM" -I "$OMARCHY_PATH/shell" "$f" 2>&1 \
        | grep -E '^Error|Expected token|Could not parse|Syntax error')
    fi
    if [[ -z $out ]]; then echo "  ok   $(basename "$f")"
    else echo "  FAIL $(basename "$f")"; echo "$out" | sed 's/^/       /'; fails=$((fails+1)); fi
  done
  rm -rf "$SHIM"
else
  echo "  FAIL qmllint or Omarchy shell sources missing (set OMARCHY_PATH)"; fails=$((fails+1))
fi

step "glyph coverage"
if out=$("$HERE/check-glyphs.sh" 2>&1); then
  echo "  ok   all glyphs present, name-verified, no raw private-use chars"
else
  case $? in
    2) echo "  skip (fonttools not available — pip install fonttools)" ;;
    *) echo "  FAIL check-glyphs.sh"; printf '%s\n' "$out" | sed 's/^/       /'; fails=$((fails+1)) ;;
  esac
fi

printf '\n'
if [[ $fails -eq 0 ]]; then echo "all checks passed"; else echo "$fails check(s) failed"; fi
exit $((fails > 0))
