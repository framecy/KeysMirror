#!/bin/bash
#
# macOS 26/27 闪退防线的唯一门禁。build.sh / CI / Release 三处共用这一份，
# 避免「本地拦得住、CI 拦不住」——那正是这道防线过去的漏洞。
#
# 背景：swift_task_isCurrentExecutor 在 macOS 26/27 上必然走到
# swift_task_isMainExecutorImpl，那里会把 main executor 的 identity（新编码，带标记位，
# 实测 0x40）当裸 HeapObject* 解引用 → EXC_BAD_ACCESS。编译器内联的 stdlib 和系统运行时
# ABI 对不上，app 侧无解，只能一次都不调。
#
# 两个来源都堵掉了，但都堵得很脆：
#   1) Swift 6 语言模式给每个 ViewBuilder 闭包插的隔离检查（曾 436 处）
#      —— 靠 project.yml 里未公开的 `-Xfrontend -disable-dynamic-actor-isolation`，
#         工具链换代后可能被静默忽略；
#   2) MainActor.assumeIsolated（曾 11 处调用点）
#      —— 已全部换成 Utilities/MainActorAssumption.swift 里的 assumingMainActor，
#         但谁都可能顺手写回 assumeIsolated。
# 任何一条漏了，闪退就无声复活，且只在用户的 macOS 26/27 上炸。所以两项都要求严格为 0。
#
# 用法：
#   verify_crash_guard.sh <可执行文件路径>   # 源码 + 二进制都查
#   verify_crash_guard.sh                    # 只查源码（不需要先构建）

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BINARY="${1:-}"
FAILED=0

# ── 门禁 1：源码里不允许出现 MainActor.assumeIsolated ────────────────────────
echo "▶ 检查源码：不得出现 MainActor.assumeIsolated"
# 排除 MainActorAssumption.swift 本身——它的注释里要解释为什么不能用这个 API。
ASSUME_HITS=$(grep -rn "MainActor\.assumeIsolated" "$REPO_ROOT/KeysMirror" "$REPO_ROOT/KeysMirrorTests" \
  --include="*.swift" 2>/dev/null \
  | grep -v "MainActorAssumption.swift" || true)
if [ -n "$ASSUME_HITS" ]; then
  echo "✗ 发现 MainActor.assumeIsolated，必须改用 assumingMainActor："
  echo "$ASSUME_HITS" | sed 's/^/    /'
  FAILED=1
else
  echo "  ✓ 0 处"
fi

# ── 门禁 2：二进制里不允许出现 swift_task_isCurrentExecutor ──────────────────
if [ -n "$BINARY" ]; then
  if [ ! -f "$BINARY" ]; then
    echo "✗ 找不到可执行文件：$BINARY"
    exit 1
  fi
  echo "▶ 检查二进制：不得出现 swift_task_isCurrentExecutor"
  ARCH=$(uname -m)
  SITES=$(otool -tV -arch "$ARCH" "$BINARY" 2>/dev/null | grep -c swift_task_isCurrentExecutor || true)
  if [ "$SITES" -gt 0 ]; then
    echo "✗ swift_task_isCurrentExecutor 出现 $SITES 处，必须为 0。"
    echo "  排查：project.yml 的 OTHER_SWIFT_FLAGS 里的"
    echo "        -Xfrontend -disable-dynamic-actor-isolation 是否仍被当前工具链接受。"
    FAILED=1
  else
    echo "  ✓ 0 处"
  fi
else
  echo "▶ 跳过二进制检查（未传入可执行文件路径）"
fi

if [ "$FAILED" -ne 0 ]; then
  echo ""
  echo "✗ 崩溃防线校验未通过。带着它发版 = macOS 26/27 上必然闪退。"
  exit 1
fi

echo "✓ 崩溃防线校验通过"
