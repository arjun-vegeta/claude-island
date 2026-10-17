# Claude Island: interactive `claude` runs inside tmux, so the notch app can rearrange sessions.
# Sourced from ~/.zshrc. Remove that line to go back to plain claude.
_claude_island_dir=${${(%):-%x}:A:h}

claude() {
  if [[ -z $TMUX && -t 0 && -t 1 ]] && ! _claude_island_passthrough "$@"; then
    $_claude_island_dir/claude-tmux "$@"
  else
    command claude "$@"
  fi
}

# Subcommands and one-shot modes run as usual, outside tmux.
_claude_island_passthrough() {
  case $1 in
    agents|attach|auth|auto-mode|config|doctor|gateway|import|install|logs|mcp|migrate-installer|plugin|purge|respawn|rm|setup-token|stop|ultrareview|update) return 0 ;;
  esac
  local arg
  for arg in "$@"; do
    case $arg in
      -p|--print|-h|--help|-v|--version|--bg|--background|--cloud|--cloud=*|--desktop) return 0 ;;
    esac
  done
  return 1
}
