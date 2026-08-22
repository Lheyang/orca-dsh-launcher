using System.Diagnostics;

namespace Orca.Core;

/// <summary>
/// DSH 服务器启停与界面打开（对应旧版 Start-DshServer / Stop-DshServer /
/// Wait-ServerUp / Open-DshUi / Update-Dsh）。
/// 全部保留原有安全纪律：端口被别的程序占用时既不强启也不误杀。
/// </summary>
public static class DshServer
{
    /// <summary>DSH 完整版是否已安装（目录存在 + 有 package.json + 是 git 仓库）。</summary>
    public static bool IsDshInstalled(string dshDir)
    {
        if (string.IsNullOrWhiteSpace(dshDir) || !Directory.Exists(dshDir)) return false;
        if (!File.Exists(Path.Combine(dshDir, "package.json"))) return false;
        if (!Directory.Exists(Path.Combine(dshDir, ".git"))) return false;
        return true;
    }

    /// <summary>只看有没有 package.json（启动前的最低要求，与旧版 Start-DshServer 判断一致）。</summary>
    public static bool HasPackageJson(string dshDir)
        => !string.IsNullOrWhiteSpace(dshDir) && File.Exists(Path.Combine(dshDir, "package.json"));

    /// <summary>服务器是否在运行（端口是否有人监听）。</summary>
    public static bool IsRunning(OrcaConfig cfg) => PortInspector.IsPortListening(cfg.Port);

    /// <summary>等待服务器就绪（默认最多 60 秒）。</summary>
    public static bool WaitUp(OrcaConfig cfg, int timeoutSeconds = 60)
        => PortInspector.WaitPortReady(cfg.Port, timeoutSeconds);

    /// <summary>
    /// 启动服务器（隐藏窗口跑 pnpm dsh web，输出重定向到日志）。
    /// 已在运行 → 直接算成功；端口被别的程序占用 / 未安装 DSH / 构建失败 → 返回明确原因。
    /// </summary>
    public static OpResult Start(OrcaConfig cfg)
    {
        var (status, owner) = PortInspector.GetStatusWithOwner(cfg.Port);
        if (status == PortStatus.Running) return OpResult.Success();
        if (status == PortStatus.Occupied)
        {
            var name = owner?.DisplayName ?? "未知程序";
            return OpResult.Fail($"端口 {cfg.Port} 被 {name} 占用（非 DSH），不能启动");
        }

        if (!HasPackageJson(cfg.DshDir))
        {
            return OpResult.Fail($"未安装 DSH（找不到 {cfg.DshDir}）。请到控制台「安装」页一键安装，或直接启动官方 Web 版。");
        }

        // 构建检查：源码更新（HEAD 变化）或缺构建产物时先构建，成功才启动
        var build = DshBuild.EnsureBuilt(cfg.DshDir);
        if (!build.Ok) return OpResult.Fail(build.Error ?? "构建检查失败");

        try
        {
            OrcaLog.RotateServerLog();
            OrcaStats.AddServerStart();
            var proc = ProcessRunner.StartHiddenCmdToLog("pnpm dsh web", OrcaLog.ServerLogFile, cfg.DshDir);
            if (proc == null) return OpResult.Fail("无法启动 DSH 进程（pnpm 是否已安装？）");
            proc.Dispose();
            return OpResult.Success(rebuilt: build.Rebuilt);
        }
        catch (Exception ex)
        {
            return OpResult.Fail(ex.Message);
        }
    }

    /// <summary>
    /// 关闭服务器（连子进程一起结束）。
    /// 端口被别的程序占用时不误杀，返回失败并说明原因。
    /// </summary>
    public static OpResult Stop(OrcaConfig cfg)
    {
        var (status, owner) = PortInspector.GetStatusWithOwner(cfg.Port);
        if (status == PortStatus.Occupied)
        {
            return OpResult.Fail("端口被其他程序占用，已取消关闭");
        }
        if (status == PortStatus.Free || owner == null)
        {
            // 本来就没开：也算成功（与旧版一致）
            OrcaStats.AccumulateRunTimeOnStop();
            return OpResult.Success();
        }

        ProcessRunner.KillTree(owner.ProcessId);
        OrcaStats.AccumulateRunTimeOnStop();
        return OpResult.Success();
    }

    /// <summary>
    /// 延迟关闭服务器（命令行工具专用）。
    /// orca-cli 是 DSH 服务器进程的子进程，直接杀进程树会把自己也杀掉、
    /// 导致命令回复发不出去；所以这里派一个"脱钩"的后台小任务延迟执行：
    /// 本进程立刻退出后，它的父子关系断开，就不会被 /T 连带杀掉。
    /// </summary>
    public static OpResult StopDetached(OrcaConfig cfg, int delaySeconds = 1)
    {
        var (status, owner) = PortInspector.GetStatusWithOwner(cfg.Port);
        if (status == PortStatus.Occupied)
        {
            return OpResult.Fail("端口被其他程序占用，已取消关闭");
        }
        if (status == PortStatus.Free || owner == null)
        {
            OrcaStats.AccumulateRunTimeOnStop();
            return OpResult.Success();
        }

        // 先把运行时长记进统计，再安排延迟关闭
        OrcaStats.AccumulateRunTimeOnStop();
        var cmd = $"timeout /t {delaySeconds} /nobreak >nul & taskkill /PID {owner.ProcessId} /T /F >nul 2>&1";
        var proc = ProcessRunner.StartHiddenCmd(cmd);
        if (proc == null) return OpResult.Fail("无法安排关闭任务");
        proc.Dispose();
        return OpResult.Success(owner.ProcessId.ToString());
    }

    /// <summary>
    /// 延迟重启服务器（命令行工具专用）。
    /// 构建检查在当前进程同步做完（此时服务器还活着），
    /// 然后用一条脱钩的后台命令串完成"关旧 → 等端口释放 → 起新"。
    /// </summary>
    public static OpResult RestartDetached(OrcaConfig cfg)
    {
        var (status, owner) = PortInspector.GetStatusWithOwner(cfg.Port);
        if (status == PortStatus.Occupied)
        {
            var name = owner?.DisplayName ?? "未知程序";
            return OpResult.Fail($"端口 {cfg.Port} 被 {name} 占用，不是 DSH，不能重启");
        }
        if (!HasPackageJson(cfg.DshDir))
        {
            return OpResult.Fail($"未安装 DSH（找不到 {cfg.DshDir}）。");
        }

        var build = DshBuild.EnsureBuilt(cfg.DshDir);
        if (!build.Ok) return OpResult.Fail(build.Error ?? "构建检查失败");

        OrcaLog.RotateServerLog();
        OrcaStats.AccumulateRunTimeOnStop();
        OrcaStats.AddServerStart();

        var parts = new List<string>();
        if (owner != null)
        {
            parts.Add("timeout /t 1 /nobreak >nul");
            parts.Add($"taskkill /PID {owner.ProcessId} /T /F >nul 2>&1");
            parts.Add("timeout /t 2 /nobreak >nul");
        }
        parts.Add($"cd /d \"{cfg.DshDir}\"");
        parts.Add($"pnpm dsh web >> \"{OrcaLog.ServerLogFile}\" 2>&1");

        var proc = ProcessRunner.StartHiddenCmd(string.Join(" & ", parts));
        if (proc == null) return OpResult.Fail("无法安排重启任务");
        proc.Dispose();
        return OpResult.Success(rebuilt: build.Rebuilt);
    }

    /// <summary>
    /// 一键更新 DSH 本体（在 DSH 目录执行 git pull）。
    /// 拉取成功后立即重新构建（HEAD 已变，不构建下次启动会失败）。
    /// </summary>
    public static OpResult UpdateDsh(OrcaConfig cfg)
    {
        try
        {
            var r = ProcessRunner.Run("git", new[] { "-C", cfg.DshDir, "pull" }, 180000);
            var pullText = r.Combined.Trim();
            if (!r.Ok)
            {
                return OpResult.Fail("git pull 失败", pullText);
            }

            var build = DshBuild.EnsureBuilt(cfg.DshDir);
            if (!build.Ok)
            {
                return OpResult.Fail(build.Error ?? "构建失败", pullText + "\n\n[构建] " + build.Error);
            }
            if (build.Rebuilt)
            {
                return OpResult.Success(pullText + "\n\n[构建] DSH 已重新构建完成（pnpm run build）", rebuilt: true);
            }
            return OpResult.Success(pullText);
        }
        catch (Exception ex)
        {
            return OpResult.Fail(ex.Message, ex.Message);
        }
    }

    /// <summary>
    /// 生成"更新内容预览"：在真正 git pull 之前，先让用户看看会拉进来哪些提交。
    /// 只做 git fetch（把远端引用拉下来用于对比），不改工作区、不合并、不停服务器，
    /// 纯只读预览。网络不通 / 不是 git 仓库时返回 Ok=false，调用方降级提示。
    /// </summary>
    /// <param name="cfg">配置。</param>
    /// <param name="maxCommits">最多列出多少条提交标题。</param>
    public static UpdatePreview PreviewUpdate(OrcaConfig cfg, int maxCommits = 10)
    {
        try
        {
            // 1) 拉一次远端引用，供对比（安全：仅更新 .git 引用，不动工作区）
            var fetch = ProcessRunner.Run("git", new[] { "-C", cfg.DshDir, "fetch", "--quiet" }, 60000);
            if (!fetch.Ok)
            {
                var reason = string.IsNullOrWhiteSpace(fetch.StdErr) ? "git fetch 失败" : fetch.StdErr;
                return new UpdatePreview { Ok = false, Error = reason };
            }

            // 2) 找当前分支的上游引用（git pull 实际就是合并 @{u}；找不到就退回 origin/<branch>）
            var upstream = ProcessRunner.Run("git", new[] { "-C", cfg.DshDir, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}" }, 10000);
            var refName = upstream.Ok && !string.IsNullOrWhiteSpace(upstream.StdOut.Trim())
                ? upstream.StdOut.Trim()
                : "origin/" + cfg.Branch;

            // 3) 统计并列出将要合并进来的提交（HEAD..上游就是 pull 会带来的内容）
            var count = ProcessRunner.Run("git", new[] { "-C", cfg.DshDir, "rev-list", "--count", "HEAD.." + refName }, 20000);
            int incoming = 0;
            if (count.Ok && int.TryParse(count.StdOut.Trim(), out var n)) incoming = n;

            if (incoming <= 0)
            {
                return new UpdatePreview { Ok = true, IncomingCount = 0 };
            }

            var log = ProcessRunner.Run("git", new[] { "-C", cfg.DshDir, "log", "--oneline", "--max-count=" + maxCommits, "HEAD.." + refName }, 20000);
            var commits = (log.Ok ? log.StdOut : string.Empty)
                .Split('\n')
                .Select(l => l.Trim())
                .Where(l => l.Length > 0)
                .ToArray();

            return new UpdatePreview { Ok = true, IncomingCount = incoming, Commits = commits };
        }
        catch (Exception ex)
        {
            return new UpdatePreview { Ok = false, Error = ex.Message };
        }
    }

    /// <summary>
    /// 打开 DSH 界面：
    ///   1. 未运行 → 先启动服务器
    ///   2. 等待就绪（默认最多 60 秒；刚更新过要构建时可以传更长）
    ///   3. 浏览器已有 DSH 页面 → 激活并最大化；没有 → 新开一个并等它最大化
    /// </summary>
    public static OpResult OpenUi(OrcaConfig cfg, int waitSeconds = 60)
    {
        var (status, owner) = PortInspector.GetStatusWithOwner(cfg.Port);
        if (status == PortStatus.Occupied)
        {
            var name = owner?.DisplayName ?? "未知程序";
            return OpResult.Fail($"端口 {cfg.Port} 被 {name} 占用，不能打开 DSH 界面");
        }
        if (status != PortStatus.Running)
        {
            var start = Start(cfg);
            if (!start.Ok) return start;
            if (!WaitUp(cfg, waitSeconds))
            {
                return OpResult.Fail("DSH 服务器启动超时，请到控制台查看日志");
            }
        }

        // 浏览器里已经有 DSH 页面 → 直接激活它，避免重复开标签
        if (TryActivateExistingBrowser()) return OpResult.Success();

        ProcessRunner.OpenUrl(cfg.ServerUrl);
        for (int i = 0; i < 20; i++)
        {
            Thread.Sleep(500);
            if (TryActivateExistingBrowser()) return OpResult.Success();
        }
        return OpResult.Success();
    }

    /// <summary>把已打开 DSH 页面的浏览器窗口最大化并置前（找不到返回 false）。</summary>
    private static bool TryActivateExistingBrowser()
    {
        // 常见浏览器都试一遍（旧版只找 msedge，这里顺带支持 Chrome / Firefox）
        foreach (var name in new[] { "msedge", "chrome", "firefox", "brave", "opera" })
        {
            Process[] procs;
            try
            {
                procs = Process.GetProcessesByName(name);
            }
            catch
            {
                continue;
            }
            try
            {
                foreach (var p in procs)
                {
                    try
                    {
                        if (p.MainWindowHandle == IntPtr.Zero) continue;
                        var title = p.MainWindowTitle ?? string.Empty;
                        if (title.IndexOf("DeepSeek Harness", StringComparison.OrdinalIgnoreCase) < 0) continue;
                        NativeMethods.ShowWindow(p.MainWindowHandle, NativeMethods.SW_MAXIMIZE);
                        NativeMethods.SetForegroundWindow(p.MainWindowHandle);
                        return true;
                    }
                    catch
                    {
                        // 单个进程读不到就换下一个
                    }
                }
            }
            finally
            {
                foreach (var p in procs)
                {
                    try { p.Dispose(); } catch { /* 忽略 */ }
                }
            }
        }
        return false;
    }
}

/// <summary>一次"更新内容预览"的结果（在真正 git pull 之前先给用户看）。</summary>
public sealed class UpdatePreview
{
    /// <summary>能否生成预览（git fetch 是否成功 / 仓库是否可读）。</summary>
    public bool Ok { get; init; }

    /// <summary>失败原因（Ok=false 时）。</summary>
    public string? Error { get; init; }

    /// <summary>将要拉取的提交数（0 = 已是最新）。</summary>
    public int IncomingCount { get; init; }

    /// <summary>提交标题列表（oneline，最多显示 maxCommits 条；IncomingCount 为 0 时为空）。</summary>
    public string[]? Commits { get; init; }
}
