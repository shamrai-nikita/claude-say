#!/bin/sh
# Build the menu bar player and put `say` on PATH.
set -e
REPO="$(cd "$(dirname "$0")" && pwd)"

command -v swiftc >/dev/null || { echo "swiftc missing. Run: xcode-select --install"; exit 1; }
swiftc -O -o "$REPO/bin/say-menu" "$REPO/src/SayMenu.swift"

mkdir -p "$HOME/.local/bin"
ln -sf "$REPO/bin/say" "$HOME/.local/bin/say"
ln -sf "$REPO/bin/say" "$HOME/.local/bin/say-last"

case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) echo 'Add this to ~/.zshrc:  export PATH="$HOME/.local/bin:$PATH"' ;;
esac

echo "Installed. In Claude Code, run: !say"
