#!/bin/sh
# Installs Claude Island: downloads the latest release into ~/Applications, makes `claude` in Terminal
# start inside it (one line in ~/.zshrc), and opens it.
#   curl -fsSL https://raw.githubusercontent.com/arjun-vegeta/claude-island/main/install.sh | sh
set -eu

REPO="arjun-vegeta/claude-island"
APP="$HOME/Applications/Claude Island.app"
LINE='[ -f ~/.claude-island/claude-island.zsh ] && source ~/.claude-island/claude-island.zsh'

say() { printf '%s\n' "$*"; }
fail() { say "Claude Island: $*" >&2; exit 1; }

[ "$(uname -s)" = Darwin ] || fail "this is a Mac app."
[ "$(uname -m)" = arm64 ] || fail "it needs a Mac with Apple silicon (every MacBook with a notch has one)."
major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 14 ] || fail "it needs macOS 14 or later."

say "Downloading Claude Island…"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl -fsSL "https://github.com/$REPO/releases/latest/download/Claude-Island.zip" -o "$tmp/Claude-Island.zip" \
  || fail "couldn't download the latest release."
ditto -x -k "$tmp/Claude-Island.zip" "$tmp"
[ -d "$tmp/Claude Island.app" ] || fail "the download didn't contain the app."

pkill -x ClaudeIsland 2>/dev/null || true
mkdir -p "$HOME/Applications"
rm -rf "$APP"
mv "$tmp/Claude Island.app" "$APP"
say "Installed $APP"

if grep -q 'claude-island.zsh' "$HOME/.zshrc" 2>/dev/null; then
  say "~/.zshrc already starts claude inside Claude Island."
else
  printf '\n# Claude Island: run claude inside tmux, so the island can arrange your chats\n%s\n' "$LINE" >> "$HOME/.zshrc"
  say "Added one line to ~/.zshrc so typing claude starts it inside Claude Island."
fi

open "$APP"

command -v claude >/dev/null 2>&1 || [ -x "$HOME/.local/bin/claude" ] \
  || say "Claude Code isn't installed yet: get it from https://code.claude.com"
say ""
say "Done. Open a new Terminal window, type claude, then hover over the notch."
