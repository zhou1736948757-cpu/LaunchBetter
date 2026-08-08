#!/usr/bin/env node
// LaunchBetter watchdog — 尝试触发 opencode 会话压缩(session.compact)
//
// 背景: session.compact 是 TUI 命令, 需要 opencode server 的 HTTP 端点。
// 本脚本: 1) 从环境/进程探测运行中的 opencode server; 2) 若可达,
// 调用 /tui/execute/command 执行 session.compact; 3) 否则记录建议
// (上下文满时 opencode 会自动压缩, 50% 预警为最佳努力)。
import { execSync } from "node:child_process"

const log = (msg) => console.log(`[compact] ${new Date().toISOString()} ${msg}`)

function findServerUrl() {
  if (process.env.OPENCODE_SERVER_URL) return process.env.OPENCODE_SERVER_URL
  try {
    // 扫描监听端口中属于 opencode 的进程
    const lsof = execSync("lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null", {
      encoding: "utf8",
      timeout: 5000,
    })
    for (const line of lsof.split("\n")) {
      if (/opencode/.test(line)) {
        const m = line.match(/(\d+\.\d+\.\d+\.\d+|\*):(\d+)/)
        if (m) {
          const port = m[2]
          const host = m[1] === "*" ? "127.0.0.1" : m[1]
          return `http://${host}:${port}`
        }
      }
    }
  } catch {
    // lsof 不可用
  }
  return null
}

async function tryCompact(sessionID) {
  const url = findServerUrl()
  if (!url) {
    log("no opencode server reachable — compact 需人工触发或等上下文满自动压缩")
    return false
  }
  try {
    const res = await fetch(`${url}/tui/execute/command`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ command: "session.compact", sessionID }),
    })
    if (res.ok) {
      log(`compact triggered via ${url}`)
      return true
    }
    log(`server responded ${res.status}`)
  } catch (e) {
    log(`server unreachable: ${e.message}`)
  }
  return false
}

const sessionID = process.argv[2]
if (!sessionID) {
  log("usage: compact-session.mjs <sessionID>")
  process.exit(1)
}
tryCompact(sessionID).then((ok) => process.exit(ok ? 0 : 1))
