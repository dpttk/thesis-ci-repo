#!/usr/bin/env bash
# Materialize an OCI bundle from bundles/<name>/bundle.yaml into out/<name>.
#
# Supported rootfs recipes (bundle.yaml .rootfs.kind):
#   busybox-tar   : download busybox-static tarball from .rootfs.url and extract
#   tar-url       : download a pre-made rootfs tarball from .rootfs.url
#   docker-export : docker create + docker export <image> | tar x
#   script        : run .rootfs.script <rootfs_dir> (caller script owns the contents)
#
# The bundle config.json is generated from .config.template merged with
# .config.process/* keys via jq.
#
# Usage: prepare-bundle.sh bundles/<name>

set -euo pipefail

BUNDLE_DIR="${1:?bundle directory path required}"
BUNDLE_DIR="$(realpath "$BUNDLE_DIR")"
BUNDLE_NAME="$(basename "$BUNDLE_DIR")"
MANIFEST="$BUNDLE_DIR/bundle.yaml"

if [[ ! -f "$MANIFEST" ]]; then
  echo "bundle manifest not found: $MANIFEST" >&2
  exit 1
fi

command -v yq >/dev/null 2>&1 || { echo "yq is required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_ROOT="${OUT_ROOT:-$REPO_ROOT/out}"
OUT_DIR="$OUT_ROOT/$BUNDLE_NAME"
ROOTFS_DIR="$OUT_DIR/rootfs"
GEN_DIR="$OUT_DIR/generated"

mkdir -p "$OUT_DIR" "$GEN_DIR"
rm -rf "$ROOTFS_DIR"
mkdir -p "$ROOTFS_DIR"

echo "==> preparing bundle '$BUNDLE_NAME' at $OUT_DIR"

ROOTFS_KIND="$(yq -r '.rootfs.kind' "$MANIFEST")"
case "$ROOTFS_KIND" in
  busybox-tar|tar-url)
    url="$(yq -r '.rootfs.url' "$MANIFEST")"
    [[ "$url" == "null" || -z "$url" ]] && { echo "rootfs.url required for kind=$ROOTFS_KIND" >&2; exit 2; }
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    echo "==> downloading rootfs tar: $url"
    curl --retry 3 -fsSL -o "$tmp/rootfs.tar" "$url"
    echo "==> extracting rootfs"
    case "$url" in
      *.tar.xz) tar -C "$ROOTFS_DIR" -xJf "$tmp/rootfs.tar" ;;
      *.tar.gz|*.tgz) tar -C "$ROOTFS_DIR" -xzf "$tmp/rootfs.tar" ;;
      *.tar.bz2) tar -C "$ROOTFS_DIR" -xjf "$tmp/rootfs.tar" ;;
      *) tar -C "$ROOTFS_DIR" -xf "$tmp/rootfs.tar" ;;
    esac
    if [[ "$ROOTFS_KIND" == "busybox-tar" && -x "$ROOTFS_DIR/bin/busybox" ]]; then
      mkdir -p "$ROOTFS_DIR"/{bin,sbin,etc,proc,sys,dev,tmp,root,usr/bin,usr/sbin}
      chmod 1777 "$ROOTFS_DIR/tmp"
      if "$ROOTFS_DIR/bin/busybox" --help >/dev/null 2>&1; then
        echo "==> wiring busybox applets"
        "$ROOTFS_DIR/bin/busybox" --list | while read -r applet; do
          [[ -e "$ROOTFS_DIR/bin/$applet" ]] || ln -s busybox "$ROOTFS_DIR/bin/$applet" 2>/dev/null || true
        done
      else
        echo "==> skipping busybox wiring (binary not runnable on host; assuming rootfs is pre-wired)"
      fi
      [[ -f "$ROOTFS_DIR/etc/passwd" ]] || echo "root:x:0:0:root:/root:/bin/sh" > "$ROOTFS_DIR/etc/passwd"
      [[ -f "$ROOTFS_DIR/etc/group" ]] || echo "root:x:0:" > "$ROOTFS_DIR/etc/group"
    fi
    ;;
  docker-export)
    image="$(yq -r '.rootfs.image' "$MANIFEST")"
    [[ "$image" == "null" || -z "$image" ]] && { echo "rootfs.image required for kind=docker-export" >&2; exit 2; }
    command -v docker >/dev/null 2>&1 || { echo "docker is required for kind=docker-export" >&2; exit 2; }
    echo "==> docker pull $image"
    docker pull --quiet "$image"
    cid="$(docker create "$image")"
    trap 'docker rm -f "$cid" >/dev/null 2>&1 || true' EXIT
    echo "==> docker export -> $ROOTFS_DIR"
    docker export "$cid" | tar -C "$ROOTFS_DIR" -xf -
    ;;
  script)
    script_rel="$(yq -r '.rootfs.script' "$MANIFEST")"
    [[ "$script_rel" == "null" || -z "$script_rel" ]] && { echo "rootfs.script required for kind=script" >&2; exit 2; }
    script_abs="$BUNDLE_DIR/$script_rel"
    [[ -x "$script_abs" ]] || { echo "rootfs.script '$script_abs' not executable" >&2; exit 2; }
    echo "==> running rootfs script: $script_abs $ROOTFS_DIR"
    "$script_abs" "$ROOTFS_DIR"
    ;;
  *)
    echo "unsupported rootfs.kind: $ROOTFS_KIND" >&2
    exit 2
    ;;
esac

tpl_rel="$(yq -r '.config.template' "$MANIFEST")"
[[ "$tpl_rel" == "null" || -z "$tpl_rel" ]] && tpl_rel="../templates/minimal.config.json"
tpl_abs="$(cd "$BUNDLE_DIR" && realpath "$tpl_rel")"
[[ -f "$tpl_abs" ]] || { echo "config template not found: $tpl_abs" >&2; exit 2; }

echo "==> rendering config.json from $tpl_abs"
config_json="$OUT_DIR/config.json"

yq -o=json '.config.process // {}' "$MANIFEST" > "$OUT_DIR/.process.override.json"

jq --slurpfile p "$OUT_DIR/.process.override.json" '
  .process = (.process // {}) * ($p[0] // {})
' "$tpl_abs" > "$config_json"

rm -f "$OUT_DIR/.process.override.json"

echo "==> validating config.json"
jq -e '.process.args and (.root.path | length > 0)' "$config_json" >/dev/null

echo "==> bundle ready: $OUT_DIR"
echo "    rootfs: $ROOTFS_DIR"
echo "    config: $config_json"
