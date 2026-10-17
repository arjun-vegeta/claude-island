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

You need a MacBook with a notch, macOS 14 or later, [Claude Code](https://code.claude.com), and Homebrew.

1. Install the tools:

   ```sh
   xcode-select --install   # Apple's developer tools, if you don't have them
   brew install tmux
   ```

2. Download Claude Island into your home folder. It has to live at `~/claude-island`:

   ```sh
   git clone https://github.com/arjun-vegeta/claude-island.git ~/claude-island
   ```

3. Build it. This puts **Claude Island** in `~/Applications`:

   ```sh
   ~/claude-island/build.sh
   open ~/Applications/Claude\ Island.app
   ```

4. Make `claude` start inside Claude Island, so it can move your chats around. Add this line to `~/.zshrc`, then open a new Terminal window:

   ```sh
   source ~/claude-island/shell/claude-island.zsh
   ```

5. Start chatting: type `claude` in Terminal as usual, then hover over the notch.

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
- **To stop using it:** remove the `source` line from `~/.zshrc` and quit the app from its settings.

## Updating

```sh
cd ~/claude-island && git pull && ./build.sh && open ~/Applications/Claude\ Island.app
```

## For developers

- `Sources/ClaudeIsland` is the app, written in Swift with SwiftUI.
- `shell/` holds the tmux setup and the launcher.
- `assets/clawd` has the original Clawd animations. `swift scripts/make-sprites.swift` turns them into the sprite sheets in `Resources/clawd`.

The app also has a few commands for checking things from Terminal:

```sh
.build/release/ClaudeIsland --cli list       # chats, their status and details
.build/release/ClaudeIsland --cli plan       # what Reorganise would do, without doing it
.build/release/ClaudeIsland --cli desktops   # which desktops are empty
.build/release/ClaudeIsland --cli usage      # plan usage
```
