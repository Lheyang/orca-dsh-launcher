using System.Diagnostics;
using System.IO.Compression;
using System.Reflection;

namespace Orca.Core;

/// <summary>环境检测结果（Node.js / Git / pnpm）。</summary>
public sealed class EnvCheckResult
{
    /// <summary>三样齐全才为 true。</summary>
    public bool Ok => Missing.Count == 0;

    /// <summary>node 版本（没装为 null）。</summary>
    public string? Node { get; init; }

    /// <summary>git 版本（没装为 null）。</summary>
    public string? Git { get; init; }

    /// <summary>pnpm 版本（没装为 null）。</summary>
    public string? Pnpm { get; init; }

    /// <summary>缺失项的人话说明（含下载地址）。</summary>
    public List<string> Missing { get; init; } = new();
}

/// <summary>GitHub 网络体检结果。</summary>
public sealed class NetworkCheckResult
{
    /// <summary>网络是否足够好（3 个地址至少通 2 个且主站可访问）。</summary>
    public bool GithubOk { get; init; }

    /// <summary>主站 HTTP 是否正常。</summary>
    public bool HttpOk { get; init; }

    /// <summary>github.com:443 是否通。</summary>
    public bool Github { get; init; }

    /// <summary>codeload.github.com:443 是否通。</summary>
    public bool Codeload { get; init; }

    /// <summary>api.github.com:443 是否通。</summary>
    public bool Api { get; init; }

    /// <summary>一行明细文本（界面直接显示）。</summary>
    public string Detail { get; init; } = string.Empty;
}

/// <summary>一个后台安装步骤（进程 + 是否被跳过）。</summary>
public sealed class StepResult
{
    /// <summary>这一步是否成功发起。</summary>
    public bool Ok { get; init; }

    /// <summary>失败原因。</summary>
    public string? Error { get; init; }

    /// <summary>后台进程（调用方轮询 HasExited；为 null 表示无需等待）。</summary>
    public Process? Proc { get; init; }

    /// <summary>是否因已存在而跳过（clone 时目录已是 DSH）。</summary>
    public bool Skipped { get; init; }

    /// <summary>构造成功。</summary>
    public static StepResult Success(Process? proc = null, bool skipped = false)
        => new() { Ok = true, Proc = proc, Skipped = skipped };

    /// <summary>构造失败。</summary>
    public static StepResult Fail(string error) => new() { Ok = false, Error = error };
}

/// <summary>
/// 安装核心逻辑（替代 orca-install.ps1）：环境检测、网络体检、git clone、
/// pnpm install / build、官方 Web 版启动、插件安装、桌面图标。
/// 控制台「安装」页与独立安装向导共用这一份，改逻辑只改这里。
/// </summary>
public sealed class InstallService
{
    /// <summary>官方仓库。</summary>
    public const string DshRepo = "deepseek-ai/deepseek-harness";

    /// <summary>官方分支。</summary>
    public const string DshBranch = "master";

    /// <summary>本次安装写日志用的日志器。</summary>
    public InstallLog Log { get; }

    /// <summary>用指定日志器创建安装服务。</summary>
    public InstallService(InstallLog log)
    {
        Log = log;
    }

    // ============================================================
    //  一、检测
    // ============================================================

    /// <summary>环境检测：node / git / pnpm；有 Node 没 pnpm 时尝试 corepack 自动启用。</summary>
    public static EnvCheckResult CheckEnvironment()
    {
        var node = ProcessRunner.GetCommandVersion("node");
        var git = ProcessRunner.GetCommandVersion("git");
        var pnpm = ProcessRunner.GetCommandVersion("pnpm");

        if (node != null && pnpm == null)
        {
            // Node 自带 corepack，可以一键启用 pnpm
            ProcessRunner.Run("cmd.exe", new[] { "/c", "corepack enable pnpm" }, 30000);
            pnpm = ProcessRunner.GetCommandVersion("pnpm");
        }

        var missing = new List<string>();
        if (node == null) missing.Add("Node.js（https://nodejs.org/zh-cn）");
        if (git == null) missing.Add("Git（https://git-scm.com/download/win）");
        if (pnpm == null) missing.Add("pnpm（装好 Node 后运行：npm install -g pnpm）");

        return new EnvCheckResult { Node = node, Git = git, Pnpm = pnpm, Missing = missing };
    }

    /// <summary>GitHub 网络体检：测三个域名 + 主站 HTTP。</summary>
    public static NetworkCheckResult CheckGithubNetwork()
    {
        bool github = PortInspector.IsHostPortOpen("github.com", 443);
        bool codeload = PortInspector.IsHostPortOpen("codeload.github.com", 443);
        bool api = PortInspector.IsHostPortOpen("api.github.com", 443);

        bool httpOk = false;
        if (github)
        {
            try
            {
                using var client = new System.Net.Http.HttpClient { Timeout = TimeSpan.FromSeconds(8) };
                client.DefaultRequestHeaders.UserAgent.ParseAdd("orca-dsh-launcher");
                using var req = new System.Net.Http.HttpRequestMessage(System.Net.Http.HttpMethod.Head, "https://github.com");
                using var resp = client.Send(req);
                var code = (int)resp.StatusCode;
                httpOk = code is >= 200 and < 400;
            }
            catch
            {
                httpOk = false;
            }
        }

        int okCount = (github ? 1 : 0) + (codeload ? 1 : 0) + (api ? 1 : 0);
        string T(bool b) => b ? "通" : "不通";
        var detail = $"github.com={T(github)}，codeload={T(codeload)}，api={T(api)}，主站访问={(httpOk ? "正常" : "异常")}";

        return new NetworkCheckResult
        {
            GithubOk = okCount >= 2 && httpOk,
            HttpOk = httpOk,
            Github = github,
            Codeload = codeload,
            Api = api,
            Detail = detail,
        };
    }

    /// <summary>DSH 完整版是否已安装。</summary>
    public static bool IsDshInstalled(string dshDir) => DshServer.IsDshInstalled(dshDir);

    // ============================================================
    //  二、安装执行（每步返回后台进程，界面轮询 HasExited 推进状态机）
    // ============================================================

    /// <summary>
    /// 第 1 步：git clone 最新版 DSH（--depth 1）。
    /// 目录已是 DSH（有 .git）→ 跳过；目录非空且不是 DSH → 报错要求换位置。
    /// </summary>
    public StepResult StartClone(string dshDir)
    {
        try
        {
            if (Directory.Exists(dshDir))
            {
                if (Directory.Exists(Path.Combine(dshDir, ".git")))
                {
                    Log.Write("检测到该目录已装过 DSH（有 .git），跳过下载。");
                    return StepResult.Success(null, skipped: true);
                }
                bool notEmpty = Directory.EnumerateFileSystemEntries(dshDir).Any();
                if (notEmpty)
                {
                    Log.Write("[错误] 目标文件夹非空且不是 DSH：" + dshDir);
                    return StepResult.Fail("目标文件夹非空且不是 DSH，请换一个位置。");
                }
            }
            Directory.CreateDirectory(dshDir);

            Log.Write("========================================");
            Log.Write("第 1 步：下载 DSH 源码（git clone）");
            Log.Write("========================================");
            Log.Write("目标目录：" + dshDir);

            var cmd = $"git clone --depth 1 https://github.com/{DshRepo}.git \"{dshDir}\"";
            var proc = ProcessRunner.StartHiddenCmdToLog(cmd, Log.FilePath);
            if (proc == null) return StepResult.Fail("无法启动 git（是否已安装 Git？）");
            return StepResult.Success(proc);
        }
        catch (Exception ex)
        {
            Log.Write("[错误] 准备下载失败：" + ex.Message);
            return StepResult.Fail("准备下载失败：" + ex.Message);
        }
    }

    /// <summary>第 2 步：pnpm install 安装依赖。</summary>
    public StepResult StartDeps(string dshDir)
    {
        if (!File.Exists(Path.Combine(dshDir, "package.json")))
        {
            return StepResult.Fail("目录里没有 package.json，DSH 源码不完整。");
        }
        Log.WriteSection("第 2 步：安装依赖（pnpm install）");
        Log.Write("下载量较大，时间取决于网速，请耐心等待（通常 10~30 分钟）。");

        var proc = ProcessRunner.StartHiddenCmdToLog("pnpm install", Log.FilePath, dshDir);
        if (proc == null) return StepResult.Fail("无法启动 pnpm（是否已安装 pnpm？）");
        return StepResult.Success(proc);
    }

    /// <summary>第 3 步：pnpm run build 构建。</summary>
    public StepResult StartBuild(string dshDir)
    {
        Log.WriteSection("第 3 步：构建 DSH（pnpm run build）");
        var proc = ProcessRunner.StartHiddenCmdToLog("pnpm run build", Log.FilePath, dshDir);
        if (proc == null) return StepResult.Fail("无法启动构建进程");
        return StepResult.Success(proc);
    }

    /// <summary>启动官方 Web 版（npx @deepseek-ai/dsh web，只需 Node.js）。</summary>
    public OpResult StartWebNpx(int port)
    {
        var node = ProcessRunner.GetCommandVersion("node");
        if (node == null)
        {
            return OpResult.Fail("电脑上没有 Node.js，无法启动官方 Web 版。请先安装 Node.js（https://nodejs.org/zh-cn）。");
        }
        Log.WriteSection("启动官方 Web 版：npx @deepseek-ai/dsh web");
        Log.Write("首次运行会自动下载官方包（需要网络），之后秒开。");

        var proc = ProcessRunner.StartHiddenCmdToLog($"npx --yes @deepseek-ai/dsh web --port {port}", OrcaLog.ServerLogFile);
        if (proc == null) return OpResult.Fail("无法启动 npx（Node.js 是否安装正确？）");
        proc.Dispose();
        Log.Write("已在后台启动，等待就绪…");
        return OpResult.Success();
    }

    /// <summary>从已安装目录启动完整版（pnpm dsh web --port N）。</summary>
    public OpResult StartFromDir(string dshDir, int port)
    {
        if (!IsDshInstalled(dshDir))
        {
            return OpResult.Fail($"DSH 未安装（找不到 {dshDir}），请先一键安装或改用官方 Web 版。");
        }
        Log.Write(string.Empty);
        Log.Write("启动 DSH（完整版）…");
        var proc = ProcessRunner.StartHiddenCmdToLog($"pnpm dsh web --port {port}", OrcaLog.ServerLogFile, dshDir);
        if (proc == null) return OpResult.Fail("无法启动 pnpm");
        proc.Dispose();
        return OpResult.Success();
    }

    // ============================================================
    //  三、插件安装
    // ============================================================

    /// <summary>
    /// 把插件装进 DSH：复制文件 → 登记 cordis.patch.yml → 写共享配置。
    /// pluginSource 目录里应包含 plugin.js / package.json / lib / bin。
    /// </summary>
    public bool InstallPlugin(string pluginSource, string dshDir)
    {
        var nodeModules = OrcaPaths.DshNodeModulesDir;
        var targetDir = OrcaPaths.PluginInstallDir;

        if (!Directory.Exists(nodeModules))
        {
            // DSH 还没运行过时这个目录不存在；主动建出来，DSH 启动后即可加载插件
            try
            {
                Directory.CreateDirectory(nodeModules);
                Log.Write("[插件] 已创建 DSH 插件目录：" + nodeModules);
            }
            catch
            {
                Log.Write("[插件] 找不到也建不出 DSH 插件目录：" + nodeModules);
                return false;
            }
        }

        try
        {
            // 0) 托盘/控制台正在运行时会锁住 bin 里的 dll，先请它们优雅退出
            bool trayWasRunning = OrcaSignals.IsTrayRunning();
            StopRunningApps(trayWasRunning || OrcaSignals.IsConsoleRunning());

            // 1) 复制插件文件（plugin.js / package.json / lib / bin）
            Directory.CreateDirectory(targetDir);
            CopyFileIfExists(Path.Combine(pluginSource, "plugin.js"), Path.Combine(targetDir, "plugin.js"));
            CopyFileIfExists(Path.Combine(pluginSource, "package.json"), Path.Combine(targetDir, "package.json"));
            CopyFileIfExists(Path.Combine(pluginSource, "cordis.patch.yml"), Path.Combine(targetDir, "cordis.patch.yml"));
            CopyDirIfExists(Path.Combine(pluginSource, "lib"), Path.Combine(targetDir, "lib"));
            CopyDirIfExists(Path.Combine(pluginSource, "bin"), Path.Combine(targetDir, "bin"));
            Log.Write("[插件] 文件已复制到 DSH 插件目录");

            // 1.5) 清掉 v1.x 留下的 PowerShell / VBS 资产（已被 bin\orca.exe 取代）
            RemoveLegacyPowerShellAssets(targetDir);

            // 2) 迁移旧版更新检查插件（备份不在这里做，仅解除登记，避免两套并存）
            if (CordisPatch.UnregisterLegacy())
            {
                Log.Write("[插件] 已移除旧版 dsh-update-checker 的登记");
            }

            // 3) 登记 cordis.patch.yml
            if (CordisPatch.Register())
            {
                Log.Write("[插件] 已在 DSH 配置中登记");
            }
            else
            {
                Log.Write("[插件] 登记失败（请检查 " + OrcaPaths.CordisPatchFile + "）");
            }

            // 4) 写共享配置（dshDir 指向实际安装位置，保留用户其它字段）
            var cfg = OrcaConfig.Load();
            cfg.DshDir = dshDir;
            cfg.Save();
            Log.Write("[插件] 配置已写入（DSH 目录：" + dshDir + "）");

            // 5) 之前托盘在跑的话，用新装好的程序重新拉起来（用户无感升级）
            if (trayWasRunning)
            {
                var exe = Path.Combine(targetDir, "bin", "orca.exe");
                if (File.Exists(exe))
                {
                    try
                    {
                        System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
                        {
                            FileName = exe,
                            Arguments = "--tray",
                            UseShellExecute = true,
                            WindowStyle = System.Diagnostics.ProcessWindowStyle.Hidden,
                            WorkingDirectory = Path.GetDirectoryName(exe)!,
                        });
                        Log.Write("[插件] 已用新版本重新拉起托盘");
                    }
                    catch
                    {
                        Log.Write("[插件] 托盘未能自动拉起（可双击桌面图标或用 /orca 托盘）");
                    }
                }
            }
            return true;
        }
        catch (Exception ex)
        {
            Log.Write("[插件] 安装失败：" + ex.Message);
            return false;
        }
    }

    /// <summary>创建桌面图标（打开控制台）。</summary>
    public bool CreateDesktopShortcut()
    {
        var exe = Path.Combine(OrcaPaths.PluginInstallDir, "bin", "orca.exe");
        var ok = ShortcutManager.CreateDesktopShortcut(File.Exists(exe) ? exe : null);
        Log.Write(ok ? "[插件] 桌面图标已创建" : "[插件] 桌面图标创建失败（不影响使用）");
        return ok;
    }

    private static void CopyFileIfExists(string src, string dst)
    {
        if (!File.Exists(src)) return;
        OrcaPaths.EnsureParentDir(dst);
        CopyWithRetry(src, dst);
    }

    /// <summary>
    /// 带重试的复制：刚退出的程序可能还没完全释放文件句柄，
    /// 失败后等一会儿重试几次，避免升级时偶发"文件被占用"。
    /// </summary>
    private static void CopyWithRetry(string src, string dst, int attempts = 5)
    {
        for (int i = 1; ; i++)
        {
            try
            {
                File.Copy(src, dst, overwrite: true);
                return;
            }
            catch (IOException) when (i < attempts)
            {
                Thread.Sleep(600);
            }
            catch (UnauthorizedAccessException) when (i < attempts)
            {
                Thread.Sleep(600);
            }
        }
    }

    /// <summary>
    /// 让正在运行的托盘 / 控制台退出，好让安装程序能替换 bin 里的文件。
    /// 先发优雅退出信号，等不动了再按"只杀我们自己插件目录里的 orca.exe"兜底。
    /// </summary>
    private void StopRunningApps(bool anyRunning)
    {
        if (!anyRunning) return;
        Log.Write("[插件] 检测到托盘/控制台正在运行，先请它们退出以便替换程序文件…");
        OrcaSignals.Signal(OrcaSignals.ConsoleCloseEventName);
        OrcaSignals.Signal(OrcaSignals.TrayCloseEventName);

        // 控制台每 4 秒轮询一次信号，这里最多等 12 秒
        for (int i = 0; i < 24; i++)
        {
            if (!OrcaSignals.IsTrayRunning() && !OrcaSignals.IsConsoleRunning())
            {
                Thread.Sleep(500);   // 再等半秒让文件句柄彻底释放
                Log.Write("[插件] 托盘/控制台已退出");
                return;
            }
            Thread.Sleep(500);
        }

        // 兜底：只结束运行在本插件目录里的 orca.exe，绝不动其它程序
        try
        {
            var binDir = Path.Combine(OrcaPaths.PluginInstallDir, "bin");
            foreach (var proc in System.Diagnostics.Process.GetProcessesByName("orca"))
            {
                try
                {
                    var path = proc.MainModule?.FileName;
                    if (path != null && path.StartsWith(binDir, StringComparison.OrdinalIgnoreCase))
                    {
                        proc.Kill(entireProcessTree: true);
                        proc.WaitForExit(3000);
                        Log.Write("[插件] 已结束占用文件的旧程序（PID " + proc.Id + "）");
                    }
                }
                catch
                {
                    // 读不到路径/杀不掉就跳过
                }
                finally
                {
                    proc.Dispose();
                }
            }
            Thread.Sleep(500);
        }
        catch
        {
            // 兜底失败就让复制重试逻辑去处理
        }
    }

    /// <summary>
    /// 从升级目标里清掉 v1.x 的 PowerShell / VBS 资产（orca\ 目录）。
    /// 先整目录备份到 ~/.dsh/orca-backup，再删除，出问题可随时找回。
    /// </summary>
    private void RemoveLegacyPowerShellAssets(string targetDir)
    {
        var legacyDir = Path.Combine(targetDir, "orca");
        if (!Directory.Exists(legacyDir)) return;
        // 只在确认是我们自己的老资产时才动手
        if (!File.Exists(Path.Combine(legacyDir, "dsh-tray.ps1")) &&
            !File.Exists(Path.Combine(legacyDir, "dsh-console.ps1")))
        {
            return;
        }
        try
        {
            var stamp = DateTime.Now.ToString("yyyyMMdd-HHmmss", System.Globalization.CultureInfo.InvariantCulture);
            var backup = Path.Combine(OrcaPaths.BackupDir, $"legacy-powershell-{stamp}");
            OrcaPaths.EnsureDir(OrcaPaths.BackupDir);
            CopyDirIfExists(legacyDir, backup);
            Directory.Delete(legacyDir, recursive: true);
            Log.Write("[插件] 已清理 v1.x 的 PowerShell 资产（已备份到 " + backup + "）");
        }
        catch (Exception ex)
        {
            Log.Write("[插件] 清理旧 PowerShell 资产失败（不影响使用）：" + ex.Message);
        }
    }

    private static void CopyDirIfExists(string srcDir, string dstDir)
    {
        if (!Directory.Exists(srcDir)) return;
        Directory.CreateDirectory(dstDir);
        foreach (var file in Directory.EnumerateFiles(srcDir, "*", SearchOption.AllDirectories))
        {
            var rel = Path.GetRelativePath(srcDir, file);
            var target = Path.Combine(dstDir, rel);
            OrcaPaths.EnsureParentDir(target);
            CopyWithRetry(file, target);
        }
    }
}

/// <summary>
/// 插件包来源（替代旧版 Get-PluginSource 的 Base64 payload 机制）。
/// - 打包版 orca-setup.exe：插件包作为嵌入资源，解压到临时目录；
/// - 开发 / 已安装环境：直接用程序旁边的文件。
/// </summary>
public static class PluginPayload
{
    /// <summary>嵌入资源名（publish.cmd 打包时注入的 zip）。</summary>
    public const string ResourceName = "Orca.Payload.zip";

    /// <summary>是否带内嵌插件包（打包版为 true）。</summary>
    public static bool HasEmbeddedPayload()
    {
        try
        {
            var asm = Assembly.GetEntryAssembly() ?? Assembly.GetExecutingAssembly();
            return asm.GetManifestResourceNames().Any(n => n.EndsWith(ResourceName, StringComparison.OrdinalIgnoreCase));
        }
        catch
        {
            return false;
        }
    }

    /// <summary>
    /// 拿到插件包所在目录：
    ///   1. 内嵌资源 → 解压到临时目录返回；
    ///   2. 否则找程序附近含 plugin.js + bin 的目录（开发 / 已安装）。
    /// 都没有返回 null。
    /// </summary>
    public static string? Resolve(string? fallbackDir = null)
    {
        var extracted = TryExtractEmbedded();
        if (extracted != null) return extracted;

        foreach (var dir in CandidateDirs(fallbackDir))
        {
            if (dir == null) continue;
            if (File.Exists(Path.Combine(dir, "plugin.js")) && File.Exists(Path.Combine(dir, "package.json")))
            {
                return dir;
            }
        }
        return null;
    }

    private static IEnumerable<string?> CandidateDirs(string? fallbackDir)
    {
        yield return fallbackDir;
        yield return AppInfo.BaseDir;
        yield return AppInfo.PackageRootDir;
        yield return Directory.GetParent(AppInfo.BaseDir)?.FullName;
        yield return OrcaPaths.PluginInstallDir;
    }

    private static string? TryExtractEmbedded()
    {
        try
        {
            var asm = Assembly.GetEntryAssembly() ?? Assembly.GetExecutingAssembly();
            var name = asm.GetManifestResourceNames()
                .FirstOrDefault(n => n.EndsWith(ResourceName, StringComparison.OrdinalIgnoreCase));
            if (name == null) return null;

            using var stream = asm.GetManifestResourceStream(name);
            if (stream == null) return null;

            var tmp = Path.Combine(Path.GetTempPath(), "orca-plugin-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(tmp);
            using var zip = new ZipArchive(stream, ZipArchiveMode.Read);
            zip.ExtractToDirectory(tmp, overwriteFiles: true);
            return tmp;
        }
        catch
        {
            return null;
        }
    }
}
