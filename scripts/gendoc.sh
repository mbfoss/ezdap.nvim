#!/usr/bin/env sh
# Generate doc/ezdap.txt from README.md with panvimdoc.
#
#   scripts/gendoc.sh           # rewrite doc/ezdap.txt and doc/tags
#   scripts/gendoc.sh --check   # exit 1 when the help file is out of date
#
# Needs pandoc (brew install pandoc). panvimdoc itself is fetched on first run
# and cached, pinned to the commit in PANVIMDOC_COMMIT below -- a tag can be
# moved, a commit cannot -- so the help file is reproducible. Point
# PANVIMDOC_DIR at a checkout of your own to use that instead. nvim is only
# used to refresh doc/tags, and is optional.

set -eu

PANVIMDOC_COMMIT=662fb20304d20c539fb48a0bda628f5165507de7 # v4.0.1
PANVIMDOC_URL=https://github.com/kdheepak/panvimdoc.git

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
project=ezdap
description="A Debug Adapter Protocol client for Neovim"
vimversion="Neovim >= 0.10"

# README constraints the generator cannot paper over: headings must be ASCII
# (panvimdoc byte-uppercases them) and short, code blocks stay under 74 columns,
# and table widths follow the header separator row.

out="$root/doc/$project.txt"
work="${TMPDIR:-/tmp}/$project-doc.$$"
trap 'rm -rf "$work"' EXIT INT TERM

command -v pandoc >/dev/null || {
    echo "gendoc: pandoc not found (brew install pandoc)" >&2
    exit 1
}

# Fetch panvimdoc at the pinned commit, once, into the user's cache. A plain
# clone cannot name a commit, so fetch that object and check it out directly.
cache="${XDG_CACHE_HOME:-$HOME/.cache}/panvimdoc-$PANVIMDOC_COMMIT"
panvimdoc="${PANVIMDOC_DIR:-$cache}"
if [ -n "${PANVIMDOC_DIR:-}" ]; then
    [ -f "$panvimdoc/panvimdoc.sh" ] || {
        echo "gendoc: no panvimdoc.sh in PANVIMDOC_DIR=$PANVIMDOC_DIR" >&2
        exit 1
    }
elif [ ! -f "$cache/panvimdoc.sh" ]; then
    echo "fetching panvimdoc $PANVIMDOC_COMMIT into $cache"
    rm -rf "$cache"
    mkdir -p "$cache"
    git -C "$cache" init --quiet
    git -C "$cache" fetch --quiet --depth 1 "$PANVIMDOC_URL" "$PANVIMDOC_COMMIT"
    git -c advice.detachedHead=false -C "$cache" checkout --quiet FETCH_HEAD
fi

# Make sure a reused cache really is the pinned commit.
if [ -z "${PANVIMDOC_DIR:-}" ]; then
    have=$(git -C "$cache" rev-parse HEAD)
    [ "$have" = "$PANVIMDOC_COMMIT" ] || {
        echo "gendoc: $cache is at $have, expected $PANVIMDOC_COMMIT" >&2
        echo "gendoc: remove that directory and re-run" >&2
        exit 1
    }
fi

# panvimdoc writes to doc/<project>.txt relative to the working directory, so
# run it in a scratch tree and compare from there.
mkdir -p "$work/doc"
(
    cd "$work"
    sh "$panvimdoc/panvimdoc.sh" \
        --project-name "$project" \
        --input-file "$root/README.md" \
        --vim-version "$vimversion" \
        --description "$description" \
        --toc true \
        --dedup-subheadings false \
        --shift-heading-level-by -1 \
        --demojify true \
        --treesitter true
) >/dev/null

# Tags are built from the heading text, so punctuation such as ":", "(" or "&"
# ends up inside them. Strip it from every tag and link, then right-align the
# heading and contents lines again.
awk -v proj="$project" -v width=78 '
function clean(t,   s) {
    s = tolower(t)
    gsub(/[^a-z0-9_.-]/, "", s)
    gsub(/-+/, "-", s)
    sub(/^-/, "", s)
    sub(/-$/, "", s)
    sub("^" proj "-the-", proj "-", s)   # a leading article adds nothing
    return s
}
BEGIN { tag = "[*|]" proj "-[^*|]*[*|]" }
{
    line = $0
    out = ""
    while (match(line, tag)) {
        t = substr(line, RSTART, RLENGTH)
        d = substr(t, 1, 1)
        out = out substr(line, 1, RSTART - 1) d clean(substr(t, 2, length(t) - 2)) d
        line = substr(line, RSTART + RLENGTH)
    }
    out = out line
    # Re-pad only the plain-ASCII lines that end in a right-aligned tag.
    if (out ~ ("  +" tag "$") && out !~ /[^ -~]/) {
        match(out, tag "$")
        t = substr(out, RSTART)
        left = substr(out, 1, RSTART - 1)
        sub(/ +$/, "", left)
        pad = width - length(left) - length(t)
        if (pad < 1)
            pad = 1
        out = left sprintf("%" pad "s", "") t
    }
    print out
}' "$work/doc/$project.txt" > "$work/doc/$project.tagged"
mv "$work/doc/$project.tagged" "$work/doc/$project.txt"

if [ "${1:-}" = "--check" ]; then
    if cmp -s "$work/doc/$project.txt" "$out"; then
        echo "$out is up to date"
        exit 0
    fi
    echo "$out is out of date; run: scripts/gendoc.sh" >&2
    [ "${2:-}" = "--diff" ] && diff -u "$out" "$work/doc/$project.txt" || true
    exit 1
fi

mkdir -p "$root/doc"
cp "$work/doc/$project.txt" "$out"
echo "wrote $out"

# helptags reports duplicate or malformed tags on stderr but still exits 0, so
# treat any output as a failure -- a silent one leaves doc/tags stale.
if command -v nvim >/dev/null; then
    err=$(nvim --clean --headless -c "helptags $root/doc" -c qa 2>&1 >/dev/null)
    if [ -n "$err" ]; then
        echo "gendoc: helptags failed, doc/tags not updated:" >&2
        echo "$err" >&2
        exit 1
    fi
    echo "wrote $root/doc/tags"
else
    echo "nvim not found; run :helptags doc to refresh tags" >&2
fi
