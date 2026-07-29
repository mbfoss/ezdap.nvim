#!/usr/bin/env bash
set -euo pipefail

REPO="https://github.com/mbfoss/neotoolkit.nvim"
DEST="lua/ezdap/util"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Only the neotoolkit modules ezdap actually needs (transitive closure).
# ezdap ships its own TreeBuffer/extmarks/etc. under lua/ezdap/ui, so those
# neotoolkit files are deliberately not vendored.
FILES=(
    Signal
    Tree
    TreeBuffer
    fileextmarks
    fixedwin
    floatwin
    fsutil
    inputwin
    strutil
    term
    throttle
    timer
    ui
    usercmd
)

cd "$(dirname "$0")/.."

if [[ -n "${LOCAL:-}" ]]; then
    echo "Using local repo: $LOCAL"
    cp -r "$LOCAL" "$TMP/neotoolkit"
else
    echo "Cloning $REPO..."
    git clone --depth=1 "$REPO" "$TMP/neotoolkit"
fi

SRC="$TMP/neotoolkit/lua/neotoolkit"

echo "Copying ${#FILES[@]} files into $DEST..."
mkdir -p "$DEST"
for f in "${FILES[@]}"; do
    if [[ ! -f "$SRC/$f.lua" ]]; then
        echo "error: $f.lua not found in neotoolkit source" >&2
        exit 1
    fi
    cp "$SRC/$f.lua" "$DEST/$f.lua"
done

echo "Rewriting require paths and type annotations (neotoolkit. -> ezdap.util.)..."
for f in "${FILES[@]}"; do
    sed -i '' 's/neotoolkit\./ezdap.util./g' "$DEST/$f.lua"
done

echo "Done. Vendored ${#FILES[@]} modules into $DEST; ezdap's own util files are untouched."
