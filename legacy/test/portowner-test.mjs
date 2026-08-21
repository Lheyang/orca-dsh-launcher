// 测试 plugin.js 新逻辑：getPortOwner 的 PowerShell 引号调用
import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
const execFileAsync = promisify(execFile)

async function getPortOwner(cfg) {
  try {
    const { stdout } = await execFileAsync('netstat', ['-ano'], { timeout: 8000, windowsHide: true })
    const portStr = ':' + cfg.port
    let pid = null
    for (const line of stdout.split(/\r?\n/)) {
      const m = line.trim().split(/\s+/)
      if (m.length >= 5 && m[1] && m[1].endsWith(portStr) && m[3] === 'LISTENING') {
        const n = Number(m[4])
        if (Number.isInteger(n) && n > 0) { pid = n; break }
      }
    }
    if (!pid) return null
    const ps = "Get-CimInstance Win32_Process -Filter \"ProcessId=" + pid + "\" | Select-Object -First 1 Name,CommandLine | ConvertTo-Json -Compress"
    console.log('PS 命令:', ps)
    const { stdout: info } = await execFileAsync('powershell.exe', ['-NoProfile', '-Command', ps], { timeout: 8000, windowsHide: true })
    console.log('PS 输出:', info.trim())
    const parsed = JSON.parse(info || '{}')
    return { pid, name: String(parsed.Name || ''), commandLine: String(parsed.CommandLine || '') }
  } catch (e) {
    console.log('错误:', e.message)
    return null
  }
}

const owner = await getPortOwner({ port: 3080 })
if (!owner) {
  console.log('未拿到占用者信息')
  process.exit(1)
}
console.log('占用者: name=' + owner.name + ' pid=' + owner.pid)
console.log('命令行: ' + owner.commandLine.slice(0, 80))
const isDsh = /pnpm|dsh|deepseek|harness|tsx/i.test(owner.commandLine)
console.log('isDshOwner:', isDsh)
console.log(isDsh ? '✅ 端口判断正常' : '❌ DSH 未被识别')
