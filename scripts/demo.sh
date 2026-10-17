#!/bin/zsh
# Fills the island with made-up chats and usage, for screen recordings. Your real chats, usage and
# settings aren't touched.
#   scripts/demo.sh start [session% week% model%]   e.g. scripts/demo.sh start 54 78 31
#   scripts/demo.sh stop                            back to your real island
# Two of the chats finish about 10 and 18 seconds after start, so their "finished" pop-ups play.
set -euo pipefail
cd "$(dirname "$0")/.."

DEMO=${TMPDIR:-/tmp}/claude-island-demo
APP_BIN="build/Claude Island.app/Contents/MacOS/ClaudeIsland"
INSTALLED="$HOME/Applications/Claude Island.app"

stop() {
  pkill -f "$DEMO/flip" 2>/dev/null || true
  pkill -x ClaudeIsland 2>/dev/null || true
  [[ -d $DEMO ]] && for f in $DEMO/sessions/*.json(N); do kill ${f:t:r} 2>/dev/null || true; done
  rm -rf $DEMO
}

if [[ ${1:-} == stop ]]; then
  stop
  [[ -d $INSTALLED ]] && open "$INSTALLED"
  echo "Demo stopped; your Claude Island is back."
  exit 0
fi
[[ ${1:-} == start ]] || { echo "usage: $0 start [session% week% model%] | stop"; exit 1; }
usage="${2:-54},${3:-78},${4:-31}"

[[ -x $APP_BIN ]] || ./build.sh --package >/dev/null
stop
mkdir -p $DEMO/sessions $DEMO/projects

# One made-up chat: a process to stand in for claude, its registry entry, and a transcript with
# its model, effort and context. Prints the pid.
chat() {  # name folder status minutes-in-status model effort context-tokens
  local name=$1 cwd=$2 st=$3 mins=$4 model=$5 effort=$6 tokens=$7
  sleep 86400 >/dev/null 2>&1 &
  local pid=$! id="demo-$(uuidgen)"
  python3 - "$DEMO" "$pid" "$id" "$name" "$cwd" "$st" "$mins" "$model" "$effort" "$tokens" <<'PY'
import json, os, sys, time
demo, pid, sid, name, cwd, status, mins, model, effort, tokens = sys.argv[1:]
now = int(time.time() * 1000)
entry = {"pid": int(pid), "sessionId": sid, "cwd": cwd, "kind": "interactive", "name": name, "nameSource": "user",
         "status": status, "statusUpdatedAt": now - int(float(mins) * 60000), "updatedAt": now}
if status == "waiting":
    entry["waitingFor"] = "permission prompt"
json.dump(entry, open(f"{demo}/sessions/{pid}.json", "w"))
folder = "".join(c if c.isascii() and c.isalnum() else "-" for c in cwd)
os.makedirs(f"{demo}/projects/{folder}", exist_ok=True)
reply = {"type": "assistant", "isSidechain": False, "requestedModel": model, "effort": effort,
         "message": {"model": model, "usage": {"input_tokens": 3, "cache_creation_input_tokens": 1200,
                                                 "cache_read_input_tokens": int(tokens) - 1203}}}
open(f"{demo}/projects/{folder}/{sid}.jsonl", "w").write(json.dumps(reply, separators=(",", ":")) + "\n")
PY
  echo $pid
}

H=$HOME
chat "Fix flaky checkout tests"          $H/code/storefront busy     4    claude-opus-5-5   high   384000 >/dev/null
chat "Research vector database options"  $H/research        busy     12   claude-fable-5-1  max    618000 >/dev/null
chat "Refactor auth middleware"          $H/code/api        waiting  1    claude-opus-5-5   xhigh  712000 >/dev/null
calendar=$(chat "Plan next week's calendar"  $H             busy     0.3  claude-sonnet-5-5 medium 92000)
blog=$(chat "Draft Q4 launch blog post"      $H/writing     busy     0.5  claude-opus-5-5   high   241000)
chat "Review PR #482: rate limiter"      $H/code/api        idle     25   claude-opus-5-5   high   452000 >/dev/null
chat "Summarize customer interviews"     $H/research        idle     130  claude-sonnet-5-5 high   173000 >/dev/null
chat "Set up CI cache for the monorepo"  $H/code/infra      idle     2900 claude-haiku-5-5  low    61000 >/dev/null

# The two that finish on camera: flip them from working to idle a little later.
cat > $DEMO/flip <<EOF
#!/bin/zsh
finish() { python3 -c "import json,time,sys; p=sys.argv[1]; d=json.load(open(p)); d['status']='idle'; d['statusUpdatedAt']=d['updatedAt']=int(time.time()*1000); json.dump(d,open(p,'w'))" \$1; }
sleep 10; finish $DEMO/sessions/$calendar.json
sleep 8;  finish $DEMO/sessions/$blog.json
EOF
chmod +x $DEMO/flip
nohup $DEMO/flip >/dev/null 2>&1 &

CLAUDE_ISLAND_SESSIONS_DIR=$DEMO/sessions CLAUDE_ISLAND_PROJECTS_DIR=$DEMO/projects CLAUDE_ISLAND_DEMO_USAGE=$usage \
  nohup "$APP_BIN" >/dev/null 2>&1 &
echo "Demo running: 8 chats, usage $usage. Two finish in about 10 and 18 seconds."
echo "Stop with: scripts/demo.sh stop"
