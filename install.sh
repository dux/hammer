#!/usr/bin/env bash
# lux-hammer installer
#
#   curl -fsSL https://raw.githubusercontent.com/dux/hammer/main/install.sh | bash
#
# Clones the repo into $LUX_HAMMER_DIR (default ~/.local/share/lux-hammer),
# builds the gem, and installs it. Re-running pulls the latest main and
# reinstalls - same code path as `hammer --update`.

set -euo pipefail

REPO="${LUX_HAMMER_REPO:-https://github.com/dux/hammer.git}"
DIR="${LUX_HAMMER_DIR:-$HOME/.local/share/lux-hammer}"

command -v git  >/dev/null || { echo "error: git not found in PATH"  >&2; exit 1; }
command -v gem  >/dev/null || { echo "error: ruby/gem not found in PATH" >&2; exit 1; }

mkdir -p "$(dirname "$DIR")"

if [ -d "$DIR/.git" ]; then
  echo "* updating lux-hammer at $DIR"
  git -C "$DIR" fetch --quiet origin main
  git -C "$DIR" reset --quiet --hard origin/main
else
  echo "* cloning lux-hammer into $DIR"
  git clone --quiet --depth 1 "$REPO" "$DIR"
fi

cd "$DIR"
version=$(sed -n 's/^version: *\([^ #]*\).*/\1/p' .version)
gem build lux-hammer.gemspec >/dev/null
gem install --quiet "lux-hammer-${version}.gem"
rm -f "lux-hammer-${version}.gem"

echo "* installed lux-hammer ${version}"
echo "* run: hammer --help"
