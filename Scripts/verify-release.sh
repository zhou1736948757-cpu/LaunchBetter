#!/bin/bash
# =============================================================================
# verify-release.sh — LaunchBetter 发布验证门（T-024，v0.7.2 事故固化）
#
# 用法:
#   scripts/verify-release.sh <tag>
#   例: scripts/verify-release.sh v0.7.3
#
# 按顺序执行 6 道门，全部通过打印 PASS 摘要；任一步失败打印 FAIL + 步骤号并
# 以非零退出。可在任意 cwd 调用（脚本自行定位仓库根）。
#
#   1. working tree clean —— git status --porcelain 仅允许白名单条目
#   2. tag exists —— 本地 rev-parse 成功 + origin ls-remote 已推送 + SHA 一致
#   3. fresh checkout —— git clone --branch <tag> --depth 1 到 /tmp 唯一目录
#   4. version == tag —— clone 内 project.pbxproj 的 MARKETING_VERSION == <tag 去 v>
#   5. Release build —— xcodebuild ... -configuration Release → BUILD SUCCEEDED
#   6. tests —— LaunchUI + LaunchCore + LaunchPlatform 全量，exit 0 且 executed > 0
#
# 白名单（发布提交边界外 / 运行时状态，可按需调整）:
#   ALLOWED_TRACKED_MODS —— 允许"已跟踪文件被修改"的精确路径
#   ALLOWED_UNTRACKED    —— 允许"未跟踪"的路径前缀
# 白名单之外的任何 M/D/A/R/C/?? 条目 → 门 1 大声失败。
#
# 纪律（事故根因，见 Workflow/incidents/2026-08-27-v0.7.2-release.md）:
#   - 禁止吞掉 stderr（不得丢弃错误输出）；错误输出原样保留
#   - set -euo pipefail + 每门显式 exit code 检查
#   - trap EXIT 删除自己的 /tmp 目录（VERIFY_RELEASE_KEEP_TMP=1 保留，调试用）
# =============================================================================

set -euo pipefail

# --- 白名单 ----------------------------------------------------------------
# 已跟踪文件允许被修改（工作流运行时状态，非生产/测试代码）
ALLOWED_TRACKED_MODS=(
  'Workflow/STATE.json'
  'Workflow/events.jsonl'
  'Workflow/heartbeats.json'
)
# 未跟踪路径允许存在（隐私目录 / 进行中工作流产物 / 本验证门自身）
ALLOWED_UNTRACKED=(
  'Workflow/evidence/'
  'Docs/aegis/'
  'Workflow/tasks/'
  'Workflow/results/'
  'Workflow/reviews/'
  'Workflow/decisions/'
  'Workflow/incidents/'
  'Workflow/review-bundles/'
  'Workflow/watchdog.json'
  'Workflow/watchdog-alerts.jsonl'
  'Scripts/verify-release.sh'
  'Workflow/RELEASE-CHECKLIST.md'
)

# --- 参数校验 --------------------------------------------------------------
usage() {
  echo "usage: $0 <tag>" >&2
  echo "  e.g. $0 v0.7.3" >&2
}
if [ "$#" -ne 1 ]; then
  usage
  exit 2
fi
case "$1" in
  -h|--help) usage; exit 0 ;;
esac
TAG="$1"
if [[ ! "$TAG" =~ ^[A-Za-z0-9._/-]+$ ]]; then
  echo "FAIL [args] tag '$TAG' 含非法字符（仅允许 [A-Za-z0-9._/-]）" >&2
  exit 2
fi

# --- 定位仓库根 ------------------------------------------------------------
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# --- 临时目录与清理 --------------------------------------------------------
TMPDIR="/tmp/lb-release-verify-${TAG}-$$"
if [ -e "$TMPDIR" ]; then
  rm -rf "$TMPDIR"   # 仅可能来自同 PID 被杀残留；路径完全由本脚本命名决定
fi
mkdir -p "$TMPDIR"

cleanup() {
  if [ "${VERIFY_RELEASE_KEEP_TMP:-0}" = "1" ]; then
    echo "  (VERIFY_RELEASE_KEEP_TMP=1: 保留 $TMPDIR)" >&2
  else
    rm -rf "$TMPDIR"
  fi
}
trap cleanup EXIT

CURRENT_GATE=0
LOCAL_SHA=""
TEST_SUMMARY=""
die() {
  echo "FAIL [gate ${CURRENT_GATE:-?}] $*" >&2
  exit 1
}
# 失败时打印日志末尾（trap EXIT 会删除日志，关键错误信息必须当场可见）
show_tail() {
  if [ -s "$1" ]; then
    echo "  --- $1 末尾 ---" >&2
    tail -n 15 "$1" >&2
  fi
}
trap 'echo "FAIL [gate ${CURRENT_GATE:-?}] 意外错误 (exit $?)" >&2' ERR

# --- 门 1: working tree clean ----------------------------------------------
gate_1_clean() {
  CURRENT_GATE=1
  echo "[1/6] working tree clean ..."
  local porcelain line xy path ok p old new
  local violations=()
  porcelain="$(git status --porcelain)" || die "git status --porcelain 失败"
  if [ -z "$porcelain" ]; then
    echo "  ✓ clean（无任何改动）"
    return 0
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    xy="${line:0:2}"
    path="${line:3}"
    ok=0
    if [ "$xy" = "??" ]; then
      for p in "${ALLOWED_UNTRACKED[@]}"; do
        if [[ "$path" == "$p"* ]]; then ok=1; break; fi
      done
    else
      # 已跟踪改动：精确匹配（rename 形如 "old -> new"，两侧都查）
      if [[ "$path" == *" -> "* ]]; then
        old="${path%% -> *}"
        new="${path##* -> }"
        for p in "${ALLOWED_TRACKED_MODS[@]}"; do
          if [ "$old" = "$p" ] || [ "$new" = "$p" ]; then ok=1; break; fi
        done
      else
        for p in "${ALLOWED_TRACKED_MODS[@]}"; do
          if [ "$path" = "$p" ]; then ok=1; break; fi
        done
      fi
    fi
    if [ "$ok" -ne 1 ]; then
      violations+=("$line")
    fi
  done <<< "$porcelain"
  if [ "${#violations[@]}" -gt 0 ]; then
    echo "  ✗ 工作树不干净，以下条目不在白名单:" >&2
    printf '    %s\n' "${violations[@]}" >&2
    die "working tree 含白名单外改动 —— 发布前必须提交或还原"
  fi
  echo "  ✓ clean（仅白名单条目）"
}

# --- 门 2: tag exists（本地 + origin 已推送 + SHA 一致） --------------------
gate_2_tag() {
  CURRENT_GATE=2
  echo "[2/6] tag exists (local + origin) ..."
  local remote_out remote_sha
  LOCAL_SHA="$(git rev-parse --verify "$TAG")" || die "tag '$TAG' 本地不存在（rev-parse 失败）"
  echo "  ✓ 本地 tag: $TAG -> $LOCAL_SHA"
  remote_out="$(git ls-remote --tags origin "$TAG" | awk -v t="refs/tags/$TAG" '$2 == t || $2 == t "^{}"')" \
    || die "git ls-remote --tags origin '$TAG' 失败（网络/remote 问题）"
  if [ -z "$remote_out" ]; then
    die "tag '$TAG' 未在 origin 找到 —— 尚未 push？"
  fi
  remote_sha="$(printf '%s\n' "$remote_out" | awk '{print $1}' | tail -1)"
  echo "  ✓ origin 已推送: $(printf '%s\n' "$remote_out" | tail -1 | awk '{print $2}')"
  # 门 2 按轻量 tag 语义比对 tag SHA；注解 tag 的 SHA 指向 tag 对象而非 commit，
  # 需 `git rev-parse <tag>^{}` 解引用后再比对
  if [ "$remote_sha" != "$LOCAL_SHA" ]; then
    die "本地 tag SHA ($LOCAL_SHA) 与 origin ($remote_sha) 不一致 —— 本地未推送或 tag 被移动"
  fi
  echo "  ✓ 本地与 origin SHA 一致"
}

# --- 门 3: fresh checkout ---------------------------------------------------
gate_3_clone() {
  CURRENT_GATE=3
  echo "[3/6] fresh checkout ..."
  local origin_url
  origin_url="$(git remote get-url origin)" || die "无法获取 origin URL"
  echo "  → git clone --branch $TAG --depth 1 $origin_url $TMPDIR/checkout"
  if git clone --branch "$TAG" --depth 1 "$origin_url" "$TMPDIR/checkout" 2>&1 | tee "$TMPDIR/clone.log"; then
    :
  else
    rc=$?
    show_tail "$TMPDIR/clone.log"
    die "fresh clone 失败（exit $rc，见 $TMPDIR/clone.log）"
  fi
  echo "  ✓ clone 完成: $TMPDIR/checkout"
  cd "$TMPDIR/checkout"
}

# --- 门 4: version == tag --------------------------------------------------
gate_4_version() {
  CURRENT_GATE=4
  echo "[4/6] version == tag ..."
  local expected versions n
  expected="${TAG#v}"
  versions="$(grep -oE 'MARKETING_VERSION[[:space:]]*=[[:space:]]*[^;]+' LaunchBetter.xcodeproj/project.pbxproj \
    | sed -E 's/.*=[[:space:]]*//' | tr -d ' \t' | sort -u)" \
    || die "clone 内未找到 MARKETING_VERSION（project.pbxproj 缺失或格式异常）"
  n="$(printf '%s\n' "$versions" | wc -l | tr -d ' ')"
  if [ "$n" -ne 1 ]; then
    die "MARKETING_VERSION 不一致（多处不同值）: $(printf '%s\n' "$versions" | tr '\n' ' ')"
  fi
  if [ "$versions" != "$expected" ]; then
    die "MARKETING_VERSION=$versions != tag 版本 $expected"
  fi
  echo "  ✓ MARKETING_VERSION=$versions == tag ${TAG#v}"
}

# --- 门 5: Release build ----------------------------------------------------
gate_5_build() {
  CURRENT_GATE=5
  echo "[5/6] Release build ..."
  local log="$TMPDIR/build.log"
  local rc
  echo "  → xcodebuild -project LaunchBetter.xcodeproj -scheme LaunchBetter -configuration Release -derivedDataPath $TMPDIR/derived build"
  if xcodebuild -project LaunchBetter.xcodeproj -scheme LaunchBetter -configuration Release \
       -derivedDataPath "$TMPDIR/derived" build > "$log" 2>&1; then
    :
  else
    rc=$?
    show_tail "$log"
    die "Release build 失败（exit $rc，见 $log）"
  fi
  if ! grep -q "BUILD SUCCEEDED" "$log"; then
    die "xcodebuild exit 0 但输出无 BUILD SUCCEEDED（见 $log）"
  fi
  echo "  ✓ BUILD SUCCEEDED"
}

# --- 门 6: tests（全量，exit 0 且 executed > 0）-----------------------------
gate_6_tests() {
  CURRENT_GATE=6
  echo "[6/6] tests (LaunchUI + LaunchCore + LaunchPlatform) ..."
  local pkg log executed rc
  TEST_SUMMARY=""
  for pkg in Packages/LaunchUI Packages/LaunchCore Packages/LaunchPlatform; do
    log="$TMPDIR/tests-$(basename "$pkg").log"
    echo "  → swift test --package-path $pkg"
    if CLANG_MODULE_CACHE_PATH=/private/tmp SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp \
         swift test --package-path "$pkg" > "$log" 2>&1; then
      :
    else
      rc=$?
      show_tail "$log"
      die "tests 失败: $pkg（exit $rc，见 $log）"
    fi
    executed="$(grep -oE 'Test run with [0-9]+ tests|Executed [0-9]+ tests' "$log" | tail -1 | grep -oE '[0-9]+' || true)"
    if [ -z "$executed" ] || [ "$executed" -eq 0 ]; then
      show_tail "$log"
      die "tests: $pkg exit 0 但 executed=${executed:-0}（无测试执行？见 $log）"
    fi
    echo "  ✓ $pkg: $executed tests, exit 0"
    TEST_SUMMARY="${TEST_SUMMARY}${pkg#Packages/} $executed, "
  done
  TEST_SUMMARY="${TEST_SUMMARY%, }"
}

# --- 执行 ------------------------------------------------------------------
echo "=== LaunchBetter release verify: $TAG ==="
echo "repo: $REPO_ROOT"
echo
gate_1_clean
gate_2_tag
gate_3_clone
gate_4_version
gate_5_build
gate_6_tests
CURRENT_GATE=7
echo
echo "PASS — $TAG 发布验证全部通过"
echo "  [1] working tree clean        ✓"
echo "  [2] tag exists (local+origin) ✓ $TAG @ ${LOCAL_SHA:0:12}"
echo "  [3] fresh checkout            ✓ $TMPDIR/checkout"
echo "  [4] version == tag            ✓ MARKETING_VERSION=${TAG#v}"
echo "  [5] Release build             ✓ BUILD SUCCEEDED"
echo "  [6] tests                     ✓ $TEST_SUMMARY"
