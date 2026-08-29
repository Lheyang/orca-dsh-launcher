using System.Diagnostics;
using System.Text;

namespace Orca.Core;

/// <summary>一次外部命令的执行结果。</summary>
public sealed class CommandResult
{
    /// <summary>退出码（超时或启动失败为 -1）。</summary>
    public int ExitCode { get; init; } = -1;

    /// <summary>标准输出（已 Trim）。</summary>
    public string StdOut { get; init; } = string.Empty;

    /// <summary>标准错误（已 Trim）。</summary>
    public string StdErr { get; init; } = string.Empty;

    /// <summary>是否成功（退出码 0）。</summary>
    public bool Ok => ExitCode == 0;

    /// <summary>输出合并文本（stdout + stderr，用于日志/弹窗展示）。</summary>
    public string Combined
    {
        get
        {
            if (string.IsNullOrEmpty(StdErr)) return StdOut;
            if (string.IsNullOrEmpty(StdOut)) return StdErr;
            return StdOut + "\n" + StdErr;
        }
    }
}

/// <summary>
/// 进程启动 / 结束 / 采集输出的统一入口
/// （替代原 PowerShell 的 Start-Process -WindowStyle Hidden、taskkill、&amp; git … 调用）。
/// 全部隐藏窗口运行，绝不弹黑框。
/// </summary>
public static class ProcessRunner
{
    /// <summary>
    /// 用 cmd.exe 后台跑一条命令（隐藏窗口），返回进程对象供轮询 HasExited。
    /// 命令里可以自带 &gt;&gt; 重定向，与原 PowerShell 版行为一致。
    ///
    /// 注意：这里**必须**用 Arguments 单字符串，不能走 ArgumentList。
    /// ArgumentList 会按 C 运行时规则把参数里的 " 转义成 \"，而 cmd.exe 不认
    /// \" 转义（它把反斜杠当普通字符、把 " 当引号开关），于是带空格的路径
    /// （如 "D:\deepseek harness"）会被拆断，重启/安装时 cd 进错误目录、命令
    /// 静默失败。Arguments 不做任何转义、原样传给 cmd.exe，由 cmd 按自己的
    /// 规则解析——与旧版 PowerShell Start-Process 的拼接行为一致。
    /// </summary>
    public static Process? StartHiddenCmd(string command, string? workingDirectory = null)
    {
        try
        {
            var psi = new ProcessStartInfo
            {
                FileName = "cmd.exe",
                UseShellExecute = false,
                CreateNoWindow = true,
                WindowStyle = ProcessWindowStyle.Hidden,
                Arguments = "/c " + command,
            };
            if (!string.IsNullOrWhiteSpace(workingDirectory) && Directory.Exists(workingDirectory))
            {
                psi.WorkingDirectory = workingDirectory;
            }
            // 关闭 corepack 的严格校验：DSH 的 package.json 声明了固定 pnpm 版本，
            // 若 registry 的签名校验网络超时会 "Refusing to run pnpm@X"，导致启动/
            // 构建被卡死。COREPACK_ENABLE_STRICT=0 让它用本机已有 pnpm、跳过严格
            // 签名校验，保证能起来（签名问题只警告，不中断）。
            psi.Environment["COREPACK_ENABLE_STRICT"] = "0";
            return Process.Start(psi);
        }
        catch
        {
            return null;
        }
    }

    /// <summary>
    /// 后台跑命令并把 stdout+stderr 追加到日志文件（DSH 服务器 / 安装步骤都用这条路径）。
    /// </summary>
    public static Process? StartHiddenCmdToLog(string command, string logFile, string? workingDirectory = null)
    {
        OrcaPaths.EnsureParentDir(logFile);
        var full = command + " >> \"" + logFile + "\" 2>&1";
        return StartHiddenCmd(full, workingDirectory);
    }

    /// <summary>
    /// 同步执行一个程序并采集输出（git 查提交号之类的短命令用）。
    /// 超时会杀掉整棵进程树并返回 ExitCode = -1。
    /// </summary>
    public static CommandResult Run(string fileName, IEnumerable<string> arguments, int timeoutMs = 10000, string? workingDirectory = null)
    {
        var psi = new ProcessStartInfo
        {
            FileName = fileName,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
        };
        // 传参方式：普通程序按 C 运行时规则转义（git 等用 msvcrt 解析，ArgumentList
        // 的 \" 转义是正确的）；唯独 cmd.exe 用自己的引号规则，\” 转义会把带空格的
        // 路径拆坏，所以 cmd.exe 一律改用 Arguments 单字符串原样拼接。
        if (fileName.Equals("cmd.exe", StringComparison.OrdinalIgnoreCase))
        {
            psi.Arguments = string.Join(" ", arguments);
        }
        else
        {
            foreach (var a in arguments) psi.ArgumentList.Add(a);
        }
        if (!string.IsNullOrWhiteSpace(workingDirectory) && Directory.Exists(workingDirectory))
        {
            psi.WorkingDirectory = workingDirectory;
        }

        try
        {
            using var proc = Process.Start(psi);
            if (proc == null) return new CommandResult();

            var stdout = new StringBuilder();
            var stderr = new StringBuilder();
            proc.OutputDataReceived += (_, e) => { if (e.Data != null) stdout.AppendLine(e.Data); };
            proc.ErrorDataReceived += (_, e) => { if (e.Data != null) stderr.AppendLine(e.Data); };
            proc.BeginOutputReadLine();
            proc.BeginErrorReadLine();

            if (!proc.WaitForExit(timeoutMs))
            {
                TryKillTree(proc);
                return new CommandResult { StdErr = "命令执行超时" };
            }
            // 等异步读取收尾
            proc.WaitForExit();

            return new CommandResult
            {
                ExitCode = proc.ExitCode,
                StdOut = stdout.ToString().Trim(),
                StdErr = stderr.ToString().Trim(),
            };
        }
        catch (Exception ex)
        {
            return new CommandResult { StdErr = ex.Message };
        }
    }

    /// <summary>查一个命令是否存在并返回版本号首行（不存在返回 null）。</summary>
    public static string? GetCommandVersion(string command, int timeoutMs = 8000)
    {
        // 走 cmd /c 才能解析 .cmd / .bat 形式的命令（pnpm、npx 在 Windows 上就是 .cmd）
        var result = Run("cmd.exe", new[] { "/c", command + " --version" }, timeoutMs);
        if (!result.Ok) return null;
        var line = result.StdOut.Split('\n').Select(s => s.Trim()).FirstOrDefault(s => s.Length > 0);
        return string.IsNullOrWhiteSpace(line) ? null : line;
    }

    /// <summary>结束整棵进程树（cmd → git / pnpm 的子进程一起结束）。</summary>
    public static bool KillTree(int processId)
    {
        try
        {
            using var proc = Process.GetProcessById(processId);
            proc.Kill(entireProcessTree: true);
            proc.WaitForExit(5000);
            return true;
        }
        catch
        {
            // 退回系统 taskkill（进程可能已退出，或权限不足）
            try
            {
                var r = Run("taskkill.exe", new[] { "/PID", processId.ToString(), "/T", "/F" }, 10000);
                return r.Ok;
            }
            catch
            {
                return false;
            }
        }
    }

    /// <summary>结束整棵进程树（进程对象版）。</summary>
    public static bool TryKillTree(Process? proc)
    {
        if (proc == null) return false;
        try
        {
            if (proc.HasExited) return true;
            return KillTree(proc.Id);
        }
        catch
        {
            return false;
        }
    }

    /// <summary>用系统默认程序打开一个 URL 或文件（浏览器打开 DSH 界面用）。</summary>
    public static bool OpenUrl(string url)
    {
        try
        {
            Process.Start(new ProcessStartInfo { FileName = url, UseShellExecute = true });
            return true;
        }
        catch
        {
            return false;
        }
    }

    /// <summary>启动一个本程序自己的新实例（托盘 / 控制台互相拉起用）。</summary>
    public static bool StartSelf(string mode)
    {
        try
        {
            var exe = AppInfo.ExecutablePath;
            // UseShellExecute = true：不继承调用方的 stdout/stderr 管道。
            // 否则 orca-cli 被 DSH 用管道调用时，拉起的常驻程序会一直占着管道，
            // 导致调用方读不到"输出结束"而一直等下去。
            var psi = new ProcessStartInfo
            {
                FileName = exe,
                UseShellExecute = true,
                WindowStyle = ProcessWindowStyle.Hidden,
                WorkingDirectory = AppInfo.BaseDir,
            };
            psi.ArgumentList.Add(mode);
            Process.Start(psi);
            return true;
        }
        catch
        {
            return false;
        }
    }

    /// <summary>
    /// 启动界面程序（orca.exe）的指定模式。安装后 exe 与 orca-cli.exe 同目录，
    /// 找不到就退回当前进程自身（开发时单 exe 调试也能跑）。
    /// </summary>
    public static bool StartAppMode(string mode)
    {
        try
        {
            var exe = Path.Combine(AppInfo.BaseDir, "orca.exe");
            if (!File.Exists(exe))
            {
                var installed = Path.Combine(OrcaPaths.PluginInstallDir, "bin", "orca.exe");
                exe = File.Exists(installed) ? installed : AppInfo.ExecutablePath;
            }
            // 同上：拉起界面程序一律走 ShellExecute，不继承管道句柄
            var psi = new ProcessStartInfo
            {
                FileName = exe,
                UseShellExecute = true,
                WindowStyle = ProcessWindowStyle.Hidden,
                WorkingDirectory = Path.GetDirectoryName(exe) ?? AppInfo.BaseDir,
            };
            psi.ArgumentList.Add(mode);
            Process.Start(psi);
            return true;
        }
        catch
        {
            return false;
        }
    }
}
