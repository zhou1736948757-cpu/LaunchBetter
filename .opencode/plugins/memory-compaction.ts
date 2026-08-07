import type { Plugin } from "@opencode-ai/plugin"
import { readFileSync } from "node:fs"
import { join } from "node:path"

/**
 * LaunchBetter 上下文压缩连续性插件。
 *
 * 在 session 压缩前,把最高价值的连续性信息注入压缩 prompt:
 * 当前阶段 / 当前任务 / 不可协商决策 / 下一步动作 / 重读 MEMORY 提醒。
 * 不复制整个 MEMORY.md,只注入高价值摘要。
 */
const memoryCompaction: Plugin = async ({ directory, $ }) => {
  return {
    "experimental.session.compacting": async (input, output) => {
      const memoryPath = join(directory, "MEMORY.md")
      let memory: string | null = null
      try {
        memory = readFileSync(memoryPath, "utf8")
      } catch {
        // MEMORY.md 尚不存在(引导期),跳过
      }

      const lines: string[] = []
      lines.push(
        "--- LaunchBetter compaction continuity (plugin-injected) ---",
        "压缩后、下一次写操作前,必须:",
        "1. 重读 MEMORY.md 与 AGENTS.md",
        "2. git status && git branch --show-current && git log --oneline -10",
        "3. 重新确认 Current Phase / Current Task / Last Known Good Commit",
        "4. 以 Git/代码/测试为准,冲突时更新 MEMORY.md",
      )

      if (memory) {
        const headers = memory
          .split("\n")
          .filter((l) => l.startsWith("## "))
          .join("\n")
        if (headers) {
          lines.push("--- MEMORY.md 目录(详见文件) ---", headers)
        }
      } else {
        lines.push("(MEMORY.md 不存在,项目仍在引导期,从 Phase 0 规则继续)")
      }

      output.context.push(...lines)
    },
  }
}

export default memoryCompaction
