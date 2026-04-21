#!/bin/bash
# install.sh — symlink a package's tree into $HOME.
#
# Usage:
#   ./install.sh <package>           # install one package
#   ./install.sh --all               # install every directory that looks like a package
#
# A "package" is any top-level directory whose contents mirror the layout under $HOME.
# For each file inside the package, we create a symlink at the corresponding path in $HOME
# pointing back at the real file in the repo. Directories are created as needed (never
# symlinked whole — that would capture future siblings we didn't mean to track).
#
# Safety: this script will NOT overwrite existing real files in $HOME. It skips and prints
# a WARN. To replace an existing real file, rm or mv it first, then rerun.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
TARGET="${HOME}"

is_package_dir() {
  # A package dir is a regular directory at the top level, excluding dotfiles and scripts.
  [ -d "$1" ] || return 1
  case "$(basename "$1")" in
    .git|.*) return 1 ;;
  esac
  return 0
}

install_package() {
  local pkg_path="$1"
  local pkg_name; pkg_name="$(basename "$pkg_path")"
  echo "==> installing $pkg_name"

  # Walk every real file under the package; compute the matching target path.
  find "$pkg_path" -type f -print | while read -r src; do
    local rel="${src#$pkg_path/}"
    local dst="${TARGET}/${rel}"
    mkdir -p "$(dirname "$dst")"
    if [ -L "$dst" ]; then
      # Existing symlink — replace it (idempotent re-install).
      ln -sfn "$src" "$dst"
      echo "  linked  $dst"
    elif [ -e "$dst" ]; then
      echo "  WARN    $dst exists and is not a symlink — skipping (move it aside and rerun)"
    else
      ln -s "$src" "$dst"
      echo "  linked  $dst"
    fi
  done
}

main() {
  if [ $# -eq 0 ]; then
    echo "usage: $0 <package> | --all" >&2
    exit 2
  fi
  if [ "$1" = "--all" ]; then
    for d in "$REPO_ROOT"/*/; do
      d="${d%/}"
      is_package_dir "$d" && install_package "$d"
    done
  else
    local pkg="$REPO_ROOT/$1"
    if ! is_package_dir "$pkg"; then
      echo "no such package: $1" >&2
      exit 1
    fi
    install_package "$pkg"
  fi
}

main "$@"
