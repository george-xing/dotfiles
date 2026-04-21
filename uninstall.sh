#!/bin/bash
# uninstall.sh — remove symlinks that install.sh created for a given package.
#
# Usage:  ./uninstall.sh <package>
#
# Only removes paths in $HOME that are symlinks pointing into this repo — never touches
# real files or unrelated symlinks.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
TARGET="${HOME}"

[ $# -eq 1 ] || { echo "usage: $0 <package>" >&2; exit 2; }

pkg_path="$REPO_ROOT/$1"
[ -d "$pkg_path" ] || { echo "no such package: $1" >&2; exit 1; }

find "$pkg_path" -type f -print | while read -r src; do
  rel="${src#$pkg_path/}"
  dst="${TARGET}/${rel}"
  if [ -L "$dst" ]; then
    # Only remove if the symlink actually points into this package.
    tgt="$(readlink "$dst")"
    if [ "$tgt" = "$src" ]; then
      rm "$dst"
      echo "  unlinked $dst"
    fi
  fi
done
