#!/bin/bash
# Installs Photo Sentinel from https://github.com/andrewbakercloudscale/photo-sentinel
set -euo pipefail
DIR="$HOME/Desktop/github/iphone-image-manager"   # the app runs its engine from here
if ! xcode-select -p >/dev/null 2>&1; then
  xcode-select --install
  echo "Finish installing the command line tools in the window that opened, then paste this again."
  exit 1
fi
if ! command -v brew >/dev/null 2>&1; then
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv)"
fi
brew install python@3.14 exiftool ffmpeg rclone
if [ -d "$DIR/.git" ]; then
  git -C "$DIR" pull --ff-only
else
  mkdir -p "$(dirname "$DIR")"
  git clone https://github.com/andrewbakercloudscale/photo-sentinel.git "$DIR"
fi
cd "$DIR"
"$(brew --prefix python@3.14)/bin/python3.14" -m venv .venv
.venv/bin/pip install --quiet -e .
(cd spikes/iimphotos && swift build -c release)
bash app/scripts/build-app.sh
echo "Photo Sentinel is installed in your Applications folder and open."
