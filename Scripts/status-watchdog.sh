#!/bin/bash
# LaunchBetter 状态监控 watchdog
#
# 职责(每 INTERVAL 秒,默认 600 = 10 分钟):
#  1. 上下文窗口使用率估算(opencode.db 文本 → token 估算 → 模型 context 上限)
#     - 达到 50%: 写状态文件 + 日志预警,并检查 MEMORY.md 是否新鲜(压缩安全)
#     - 说明: session.compact 是 TUI 命令,无 HTTP 端点;自动压缩由 opencode
#       在上下文满时执行,本 watchdog 保证压缩前持久状态是新鲜的
#  2. subagent 检查: opencode run 进程(视觉评审等独立会话)
#     - 存活但长时间无活动 → 视为卡死: 记录并中断(杀掉)该进程
#  3. 卡死的构建进程: xcodebuild/swiftc/swift 运行超过阈值 → 中断并记录
#  4. API/网络可用性: opencode.go 端点探测,失败记录(不中断本地开发)
#  5. 心跳: git 最近提交 + 最近会话活动,写入状态文件
#
# 用法: nohup ./Scripts/status-watchdog.sh [interval_seconds] &
# 状态: /tmp/launchbetter-watchdog/state.json + watchdog.log

INTERVAL="${1:-600}"
PROJECT_DIR="${LAUNCHBETTER_PROJECT_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
DB="$HOME/.local/share/opencode/opencode.db"
STATE_DIR="/tmp/launchbetter-watchdog"
LOG="$STATE_DIR/watchdog.log"
STATE="$STATE_DIR/state.json"
CONTEXT_WARN_PCT="${CONTEXT_WARN_PCT:-50}"
STUCK_SUBAGENT_MIN="${STUCK_SUBAGENT_MIN:-20}"
STUCK_BUILD_MIN="${STUCK_BUILD_MIN:-25}"
API_URL="https://opencode.ai/zen/go/v1"

mkdir -p "$STATE_DIR"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

write_state() {
  # $1 = JSON 片段
  echo "{ $(date '+%s') $1 }" | python3 -c "
import sys, json
raw = sys.stdin.read()
# 时间戳由 bash 注入,这里组装
ts, rest = raw.split(' ', 1)
state = json.loads(rest)
state['timestamp'] = int(ts)
with open('$STATE', 'w') as f:
    json.dump(state, f, ensure_ascii=False, indent=1)
"
}

check_context() {
  [ -f "$DB" ] || { log "CONTEXT skip: db not found"; return; }
  local usage
  usage=$(python3 - "$DB" "$PROJECT_DIR" <<'PYEOF'
import json, sqlite3, sys, subprocess

db, project = sys.argv[1], sys.argv[2]

def model_context_limit():
    try:
        out = subprocess.run(
            ["opencode", "models", "--verbose"],
            capture_output=True, text=True, timeout=30,
        ).stdout
        # 查找默认模型 deepseek-v4-flash 的 context limit
        import re
        blocks = re.split(r'\n(?=\{\n  "id")', out)
        for b in blocks:
            if '"deepseek-v4-flash"' in b.split("\n", 2)[1] if len(b.split("\n")) > 1 else False:
                m = re.search(r'"context": (\d+)', b)
                if m:
                    return int(m.group(1))
    except Exception:
        pass
    return 1_000_000  # 回退: 100 万 token

def estimate_tokens(text):
    ascii_chars = sum(1 for c in text if ord(c) < 128)
    other = len(text) - ascii_chars
    return int(ascii_chars / 4 + other * 0.75)  # 混合中英文启发式

conn = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
cur = conn.cursor()
cur.execute("""
    SELECT id FROM session
    WHERE directory = ?
    ORDER BY (SELECT MAX(time_created) FROM part WHERE part.session_id = session.id) DESC
    LIMIT 1
""", (project,))
row = cur.fetchone()
if not row:
    print("NO_SESSION")
    sys.exit(0)
sid = row[0]
cur.execute("SELECT data FROM part WHERE session_id = ?", (sid,))
tokens = 0
chars = 0
for (data,) in cur.fetchall():
    try:
        d = json.loads(data)
    except Exception:
        continue
    text = d.get("text", "") if isinstance(d, dict) else ""
    if text:
        chars += len(text)
        tokens += estimate_tokens(text)
limit = model_context_limit()
pct = tokens * 100.0 / limit if limit else 0
print(f"{sid} {tokens} {limit} {pct:.1f} {chars}")
PYEOF
)
  if [ "$usage" = "NO_SESSION" ]; then
    log "CONTEXT no-active-session"
    return
  fi
  local sid tokens limit pct chars
  read -r sid tokens limit pct chars <<< "$usage"
  log "CONTEXT session=$sid estTokens=$tokens limit=$limit usage=${pct}% chars=$chars"

  local warn="false"
  if python3 -c "exit(0 if float('$pct') >= float('$CONTEXT_WARN_PCT') else 1)" 2>/dev/null; then
    warn="true"
    log "CONTEXT WARN usage>=${CONTEXT_WARN_PCT}% (${pct}%) — 尝试自动压缩"
    # 压缩前持久状态新鲜性检查
    if [ -f "$PROJECT_DIR/MEMORY.md" ]; then
      local mem_age
      mem_age=$(python3 -c "import os,time; print(int(time.time()-os.path.getmtime('$PROJECT_DIR/MEMORY.md')))")
      if [ "$mem_age" -gt 1800 ]; then
        log "CONTEXT WARN MEMORY.md 已 $mem_age 秒未更新 — 压缩可能丢失状态,需先更新 MEMORY"
      fi
    fi
    # 自动压缩(最佳努力): 有 server 则执行 session.compact; 无则记录
    node "$PROJECT_DIR/Scripts/compact-session.mjs" "$sid" >> "$LOG" 2>&1 || log "compact attempt failed/unsupported"
  fi
  write_state "\"context\": {\"session\": \"$sid\", \"estimatedTokens\": $tokens, \"limit\": $limit, \"usagePct\": $pct, \"warn50\": $warn}"
}

check_subagents() {
  # opencode run 独立会话(视觉评审等): 存活但长时间无活动 → 卡死
  local now
  now=$(date +%s)
  local active
  active=$(python3 -c "
import sqlite3, sys, time
db = '$DB'
if not __import__('os').path.exists(db):
    sys.exit(1)
conn = sqlite3.connect(f'file:{db}?mode=ro', uri=True)
cur = conn.cursor()
cur.execute('SELECT MAX(time_created) FROM part')
row = cur.fetchone()
print(int(row[0]) if row and row[0] else 0)
")
  ps aux | grep "opencode run" | grep -v grep | while read -r line; do
    local pid etime
    pid=$(echo "$line" | awk '{print $2}')
    # 进程年龄(秒)
    local start
    start=$(ps -o lstart= -p "$pid" 2>/dev/null | python3 -c "
import sys, datetime
s = sys.stdin.read().strip()
if not s: sys.exit(0)
try:
    t = datetime.datetime.strptime(s, '%a %b %d %H:%M:%S %Y')
    import time
    print(int(time.time() - t.timestamp()))
except Exception:
    sys.exit(0)
")
    [ -n "$start" ] || continue
    local idle=$(( now - active ))
    if [ "$start" -gt $((STUCK_SUBAGENT_MIN * 60)) ] && [ "$idle" -gt $((8 * 60)) ]; then
      log "SUBAGENT STUCK pid=$pid age=${start}s idle=${idle}s — 中断并继续"
      kill "$pid" 2>/dev/null && log "SUBAGENT killed pid=$pid"
    else
      log "SUBAGENT OK pid=$pid age=${start}s activityAge=${idle}s"
    fi
  done
  # in-process Task 子代理不可从外部观察,记录说明
  local run_count
  run_count=$(ps aux | grep "opencode run" | grep -v grep | wc -l | tr -d ' ')
  write_state "\"subagents\": {\"opencodeRunProcesses\": $run_count, \"note\": \"in-process task subagents not externally observable\"}"
}

check_builds() {
  local now
  now=$(date +%s)
  ps aux | grep -E "xcodebuild|swiftc|swift-frontend|swift test" | grep -v grep | while read -r line; do
    local pid start
    pid=$(echo "$line" | awk '{print $2}')
    start=$(ps -o lstart= -p "$pid" 2>/dev/null | python3 -c "
import sys, datetime, time
s = sys.stdin.read().strip()
if not s: sys.exit(0)
try:
    t = datetime.datetime.strptime(s, '%a %b %d %H:%M:%S %Y')
    print(int(time.time() - t.timestamp()))
except Exception:
    sys.exit(0)
")
    [ -n "$start" ] || continue
    if [ "$start" -gt $((STUCK_BUILD_MIN * 60)) ]; then
      log "BUILD STUCK pid=$pid age=${start}s — 中断"
      kill "$pid" 2>/dev/null && log "BUILD killed pid=$pid"
    fi
  done
}

check_network() {
  local code
  code=$(curl -m 8 -s -o /dev/null -w "%{http_code}" "$API_URL" 2>/dev/null)
  if [ "$code" = "000" ] || [ -z "$code" ]; then
    log "NETWORK FAIL api=$API_URL unreachable"
    write_state "\"network\": {\"ok\": false}"
  else
    log "NETWORK OK api=$API_URL http=$code"
    write_state "\"network\": {\"ok\": true, \"http\": \"$code\"}"
  fi
}

check_memory_freshness() {
  # 规则(AGENTS.md §31): 几个有意义的提交内必须刷新 MEMORY.md
  local last_mem_ts last_code_ts commits_since last_mem_sha
  last_mem_sha=$(git -C "$PROJECT_DIR" log -1 --format=%H -- MEMORY.md 2>/dev/null)
  last_mem_ts=$(git -C "$PROJECT_DIR" log -1 --format=%ct -- MEMORY.md 2>/dev/null || echo 0)
  last_code_ts=$(git -C "$PROJECT_DIR" log -1 --format=%ct 2>/dev/null || echo 0)
  if [ -z "$last_mem_sha" ]; then
    log "MEMORY MISSING: MEMORY.md 不存在(或未提交)"
    write_state "\"memory\": {\"stale\": true, \"detail\": \"missing\"}"
    return
  fi
  if [ "$last_code_ts" -gt "$last_mem_ts" ]; then
    commits_since=$(git -C "$PROJECT_DIR" log --oneline --format=%h "$last_mem_sha"..HEAD 2>/dev/null | wc -l | tr -d ' ')
    local pending
    pending=$(git -C "$PROJECT_DIR" log --oneline -5 --format="%h %s" "$last_mem_sha"..HEAD 2>/dev/null | head -5 | tr '\n' ';')
    log "MEMORY STALE: MEMORY 更新后又有 $commits_since 个提交未同步: $pending"
    write_state "\"memory\": {\"stale\": true, \"commitsSinceUpdate\": $commits_since, \"pending\": \"$pending\"}"
    return
  fi
  log "MEMORY FRESH"
  write_state "\"memory\": {\"stale\": false}"
}

check_memory_structure() {
  # 规则(主提示 §24): MEMORY.md 必须包含的章节(多词名称, 用 | 分隔迭代)
  local missing=""
  local IFS='|'
  for s in "North Star" "Non-Negotiable Decisions" "Current Phase" "Current Task" "Current Branch" "Last Known Good Commit" "Completed Milestones" "Verified Technical Facts" "Current Performance Measurements" "Known Issues / Blockers" "Architecture Changes" "Rejected Approaches" "GitHub / Release Status" "Next Actions" "Last Updated"; do
    grep -q "^## $s$" "$PROJECT_DIR/MEMORY.md" 2>/dev/null || missing="$missing | $s"
  done
  if [ -n "$missing" ]; then
    log "MEMORY STRUCTURE MISSING:$missing"
    write_state "\"memory_structure\": {\"ok\": false, \"missing\": \"$missing\"}"
  else
    log "MEMORY STRUCTURE OK"
    write_state "\"memory_structure\": {\"ok\": true}"
  fi
}

check_forbidden_patterns() {
  # 规则(AGENTS.md §禁止模式): 全仓库 DispatchQueue.main.sync 数量 = 0
  local hits
  hits=$(rg -n "DispatchQueue\.main\.sync" --glob '*.swift' "$PROJECT_DIR" 2>/dev/null | head -3)
  if [ -n "$hits" ]; then
    log "RULE VIOLATION main.sync 出现: $hits"
    write_state "\"forbidden\": {\"mainSyncCount\": $(rg -c "DispatchQueue\.main\.sync" --glob '*.swift' "$PROJECT_DIR" 2>/dev/null | awk -F: '{s+=$2} END{print s+0}')}"
  else
    log "RULES OK (main.sync=0)"
    write_state "\"forbidden\": {\"mainSyncCount\": 0}"
  fi
}

check_heartbeat() {
  local last_commit last_activity
  last_commit=$(cd "$PROJECT_DIR" && git log -1 --format=%ct 2>/dev/null || echo 0)
  last_activity=$(python3 -c "
import sqlite3, os
db = '$DB'
if not os.path.exists(db):
    print(0); sys.exit(0)
conn = sqlite3.connect(f'file:{db}?mode=ro', uri=True)
cur = conn.cursor()
cur.execute('SELECT MAX(time_created) FROM part WHERE session_id IN (SELECT id FROM session WHERE directory = ?)', ('$PROJECT_DIR',))
row = cur.fetchone()
print(int(row[0]) if row and row[0] else 0)
")
  local now
  now=$(date +%s)
  write_state "\"heartbeat\": {\"lastCommitTs\": $last_commit, \"lastSessionActivityTs\": $last_activity, \"nowTs\": $now}"
}

log "WATCHDOG started interval=${INTERVAL}s pid=$$"
while true; do
  check_heartbeat
  check_context
  check_memory_freshness
  check_memory_structure
  check_forbidden_patterns
  check_subagents
  check_builds
  check_network
  log "CYCLE done"
  sleep "$INTERVAL"
done
