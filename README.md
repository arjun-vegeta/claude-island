# Claude Island

A Dynamic Island for Claude Code on a notched MacBook. Hover over the notch to see every Claude Code session, your plan usage, and a button that puts running sessions first, two per desktop.

## What it shows

- **Sessions**, grouped into three sections, each shown only when it has sessions:
  - **Working:** sessions Claude is busy in, as cards with Claude Code's spinning ✻. One that's waiting on you gets a clay border and "Needs your permission".
  - **Done:** finished but not opened yet, with a check (or a waving Clawd right after its pop-up). They stay here, however long ago they finished, until you open them.
  - **Recent:** finished within the last 6 hours and already seen: the ones you're in the middle of.
  - **Idle:** untouched for more than 6 hours, as slim rows with how long it's been.
- **Type to search** while the island is open: sessions narrow to those whose name or folder matches. Enter opens the selected one (the top match unless you've moved the selection), arrows move the selection, Esc clears the search, then closes the island. Typing goes back to Terminal when the island closes.
- **Click a session** to jump to its window. A session with no window open ("hidden") gets a new window.
- **Usage:** your 5-hour and weekly limits, with reset times. Same numbers as `/usage`.
- **Pop-up when something finishes:** the notch opens briefly with "✓ <session> finished · took 4m", plus a chime. It does the same when a session needs your input. Click the pop-up to go there.
- **Clawd:**
  - Lurks beside the notch while the island is closed. Between loops he sometimes walks behind the notch to the other side, and now and then slides out to dance or wave.
  - Drives his racing car right of the notch when you press New chat.
  - Waves in place of a session's blue dot after its "finished" pop-up, until you click that session or close the island.
  - Types on his laptop in the top-left corner when it's open, and dances there after a Reorganise.
  - Jumps when a session finishes, and waves when one needs you.
  - Crab-walks while sessions move into tmux.
  - The animations live in `Resources/clawd`; `swift scripts/make-sprites.swift` rebuilds them from `assets/clawd`.
- **Settings** (the gear, bottom left) open in the island itself: pop-ups, sound, Clawd beside the notch, plan usage, whether Reorganise opens windows, desktop-switching permission, open at login, checking usage now, and Quit. Esc or Done goes back, and the island always reopens on the sessions.
- **New chat:** opens a new Terminal window on the current desktop, running Claude Code in your home folder, inside tmux. If that desktop has room in its layout, the new window takes the next free slot.

## Reorganise

Each Claude session runs inside its own tmux session, and each Terminal window shows one of them. Settings › Windows per desktop picks the layout: 2 side by side (the default), 4 in a 2 × 2 grid, or 6 in 2 rows of 3. First, Reorganise makes sure every chat has a window, filling each desktop's layout:

- A chat with no window gets one, and a desktop with more windows than its layout gives up the extras.
- They go onto desktops with room first, then onto empty desktops (ones with no app windows at all). It walks to an empty desktop by pressing Ctrl+→, so it needs Claude Island allowed under Accessibility; macOS asks the first time. If there aren't enough empty desktops, it says how many to add in Mission Control.
- You're taken back to the desktop you started on.

Then it changes which session each window shows:

- Running sessions (and ones waiting on you) go to the first desktops that hold at least two windows.
- With an odd number of running sessions, one desktop gets one running and one idle.
- Sessions that finished since you last looked come next, then idle ones.
- Windows are tiled to the layout: left and right halves, a 2 × 2 grid, or 2 rows of 3.

When every chat already has a window, it's instant: nothing slides, and the mouse is never touched.

## Setup (already done on this Mac)

- **tmux:** `brew install tmux`.
- **Shell:** `~/.zshrc` sources `shell/claude-island.zsh`, so typing `claude` in a new Terminal window starts the session inside tmux. Subcommands (`claude mcp`, `claude update`, ...) and `claude -p` run as before. To go back to plain claude, delete that line.
- **tmux settings** (`shell/tmux.conf`, on its own server, `tmux -L claude-island`):
  - No status bar.
  - No prefix key, so Ctrl+B still reaches Claude.
  - Trackpad scrolling through history.
  - Drag-to-select copies to the clipboard.
  - Claude's titles, bells and notifications reach Terminal.

### Sessions started before the setup

Sessions that were already running aren't in tmux, so Reorganise can't move them. **Move into tmux** in the island restarts the idle ones inside tmux, in the same window, continuing the same chat (`claude --resume <id>`). Anything those sessions were running in the background (dev servers, monitors) stops. Busy sessions are skipped; move them once they're idle.

Most sessions live in your home folder, which Claude Code only trusts for one session at a time. Without the step below, every restarted session stops at "Is this a project you trust?". To trust it once and for all (git repos inside still ask separately), run:

```sh
python3 -c "import json,os;p=os.path.expanduser('~/.claude.json');c=json.load(open(p));c.setdefault('projects',{}).setdefault(os.path.expanduser('~'),{})['hasTrustDialogAccepted']=True;t=p+'.tmp';json.dump(c,open(t,'w'),indent=2);os.chmod(t,0o600);os.replace(t,p)"
```

## How it gets its data (no account)

Everything comes from the `claude` binary and tools on this Mac:

- **Sessions and their status:** `~/.claude/sessions/<pid>.json`, which Claude Code keeps up to date itself.
- **Usage:** `claude -p` started in SDK mode and sent a `get_usage` control request, the same data `/usage` shows. No prompt is sent, so it uses no tokens.
- **Windows:**
  - Terminal's AppleScript gives the windows, tabs and ttys.
  - tmux says which window shows which session.
  - Desktop numbers come from macOS's window server.

## Permissions

- **Automation → Terminal:** to read your Terminal windows. macOS asks the first time the app starts.
- **Accessibility:** only so Reorganise can press Ctrl+→ to reach an empty desktop. macOS asks the first time it needs to.
- **Desktop, Downloads, Music and other folders:** the app doesn't open these itself. The `claude` process it starts to read your usage counts as Claude Island, so macOS asks on its behalf. Allowing once is enough: `build.sh` signs the app with a fixed identity, so permissions survive rebuilds.

## Good to know

- **Closing a window ends its session**, as it did before tmux. A session can still end up without a window when there are more sessions than windows after a Reorganise. The island shows it as "hidden"; click it to open a window for it.
- **Screenshots dragged from the preview** (the thumbnail after ⌘⇧4) reach Claude through a small relay between each Terminal window and tmux (`shell/relay.c`, built as `shell/relay/tmux`). macOS lets only Terminal read that preview file, and the Claude sessions inside tmux don't count as Terminal. The relay does count as Terminal, so it copies the file to `~/Library/Caches/claude-island-drops` (cleared after a week) and passes Claude that path. For the same reason, Claude Island opens its windows as `.command` files rather than through AppleScript, which macOS wouldn't count as Terminal.
- **Scrolling is tmux's.** After scrolling up, scroll back down or press Esc to return to the prompt.
- **Keep desktop order fixed.** macOS has "Automatically rearrange Spaces based on most recent use" (System Settings › Desktop & Dock › Mission Control), and it's on by default. It shuffles which desktop is Desktop 1 as you switch apps. Turning it off keeps running sessions on the first desktops.
- Only Terminal.app is supported.

## Build

```sh
./build.sh          # builds, signs and installs ~/Applications/Claude Island.app
open ~/Applications/Claude\ Island.app
```

Turn on "Open at login" in the island's settings (the gear, bottom left).

Command-line checks:

```sh
.build/release/ClaudeIsland --cli list               # sessions, status, tmux session, desktop
.build/release/ClaudeIsland --cli usage              # plan usage from the claude binary
.build/release/ClaudeIsland --cli plan               # what Reorganise would do, without doing it
.build/release/ClaudeIsland --cli desktops           # each desktop: empty or in use, and its chats
.build/release/ClaudeIsland --cli reorganise
.build/release/ClaudeIsland --cli move-to-tmux <pid> # restart one idle session inside tmux
.build/release/ClaudeIsland --cli new-chat           # same as the New chat button
.build/release/ClaudeIsland --cli demo [dance|wave|race]  # show a "finished" pop-up now, or bring Clawd out
```
