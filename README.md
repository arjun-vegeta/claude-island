# Claude Island

A Dynamic Island for Claude Code on a MacBook with a notch. Hover over the notch to see all your Claude Code chats, how much of your plan you've used, and buttons to tidy up your Terminal windows.

## What you get

- **Every chat at a glance**, grouped into Working, Done, Recent and Idle. Click one to jump to its window.
- **Model, effort and context** under each chat, for example "Opus 5.5 · high · 38% of 1M".
- **Your plan usage**: the 5-hour and weekly limits, the same numbers as `/usage`. It shows the last known numbers when you're offline.
- **A pop-up and a chime** when a chat finishes or needs you.
- **Reorganise**: running chats first, laid out 2, 4 or 6 to a desktop. Chats without a window get one.
- **New chat**: a new Terminal window with Claude Code, placed in the next free spot.
- **Type to search** while the island is open. Press Enter to open the top match, or Esc to clear the search.
- **Clawd**, the Claude Code mascot, hangs around the notch.
- **Settings**: click the gear at the bottom left.

It needs no account or login. Everything comes from Claude Code itself on your Mac.

## Install

You need a MacBook with a notch, macOS 14 or later, and [Claude Code](https://code.claude.com). Paste this into Terminal:

```sh
curl -fsSL https://raw.githubusercontent.com/arjun-vegeta/claude-island/main/install.sh | sh
```

Then open a new Terminal window, type `claude`, and hover over the notch.

The installer:
- puts **Claude Island** in `~/Applications`
- adds one line to `~/.zshrc`, so `claude` starts inside Claude Island
- opens the app

To start it automatically, turn on **Open at login** in its settings.

## Permissions macOS will ask for

- **Terminal (Automation):** to see your Terminal windows and bring them forward. Asked the first time it starts.
- **Accessibility:** only so Reorganise can switch to an empty desktop for you. Asked the first time it needs to.
- **Folders such as Desktop and Downloads:** the `claude` process that checks your plan usage can trigger these. Allowing once is enough.

## Good to know

- **Only Terminal.app is supported.**
- **Each chat runs inside tmux**, a tool that keeps it running apart from its window. That's how Reorganise can swap chats between windows instantly. You won't see tmux: there's no status bar, and your keys go straight to Claude.
- **Closing a window ends its chat**, just like before.
- **Scrolling:** after scrolling up, scroll back down or press Esc to get back to the prompt.
- **Links:** click a link to open it.
- **Screenshots:** you can drag the preview that appears after ⌘⇧4 straight into a chat.
- **Desktop order:** turn off "Automatically rearrange Spaces based on most recent use" in System Settings › Desktop & Dock. Otherwise macOS keeps reshuffling your desktops.
- **Chats started before you installed it** aren't in tmux yet. The island offers **Move into tmux**, which restarts them in place and keeps the conversation.

## Updating

Run the install command again.

## Uninstalling

1. Quit Claude Island from its settings.
2. Delete `~/Applications/Claude Island.app` and the `~/.claude-island` folder.
3. Remove the Claude Island line from `~/.zshrc`.

## For developers

To build it yourself, you need Apple's command-line tools (`xcode-select --install`):

```sh
git clone https://github.com/arjun-vegeta/claude-island.git && cd claude-island
./scripts/build-tmux.sh   # optional: puts tmux inside the app (otherwise it uses Homebrew's)
./build.sh                # builds and installs ~/Applications/Claude Island.app
```

- `Sources/ClaudeIsland` is the app, written in Swift with SwiftUI.
- `shell/` holds the tmux setup and the launcher. The app copies them to `~/.claude-island` when it starts.
- `assets/clawd` has the original Clawd animations. `swift scripts/make-sprites.swift` turns them into the sprite sheets in `Resources/clawd`.
- **Releases:** pushing a tag such as `v1.1` builds the app with tmux inside and publishes it, which is what the install command downloads.

The app also has a few commands for checking things from Terminal:

```sh
.build/release/ClaudeIsland --cli list       # chats, their status and details
.build/release/ClaudeIsland --cli plan       # what Reorganise would do, without doing it
.build/release/ClaudeIsland --cli desktops   # which desktops are empty
.build/release/ClaudeIsland --cli usage      # plan usage
```
