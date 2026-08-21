using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Orca.Core;

namespace Orca.Cli;

/// <summary>
/// 命令行工具（替代 plugin.js 里内嵌的 PowerShell 调用 + 各种 .ps1 脚本）。
/// 一切逻辑都走 Orca.Core，保证托盘 / 控制台 / 聊天命令行为完全一致。
/// </summary>
public static class Program
{
    private static bool _json;

    /// <summary>入口。</summary>
    public static int Main(string[] args)
    {
        var list = new List<string>(args);
        _json = list.RemoveAll(a => string.Equals(a, "--json", StringComparison.OrdinalIgnoreCase)) > 0;

        var command = list.Count > 0 ? list[0].TrimStart('-', '/').ToLowerInvariant() : "help";
        var rest = list.Skip(1).ToList();

        // 输出编码：
        //   结构化输出（JSON）固定 UTF-8，方便 plugin.js 用 utf8 解析；
        //   人看的文本沿用控制台默认编码（中文 Windows 是 GBK），直接双击 .cmd 也不乱码。
        bool jsonOutput = _json || command is "quick-check" or "quickcheck" or "update-check";
        if (jsonOutput)
        {
            try
            {
                Console.OutputEncoding = new UTF8Encoding(false);
            }
            catch
            {
                // 某些宿主不允许改编码，忽略
            }
        }

        try
        {
            switch (command)
            {
                case "run":
                    return RunOrcaSubcommand(rest.Count > 0 ? rest[0] : string.Empty);

                case "quick-check":
                case "quickcheck":
                    return QuickCheck();

                case "update-check":
                    return UpdateCheckJson();

                case "install-plugin":
                    return InstallPlugin(rest);

                case "uninstall-plugin":
                    return UninstallPlugin(rest);

                case "selftest":
                    return SelfTest();

                case "version":
                case "--version":
                    Console.WriteLine(AppInfo.VersionDisplay);
                    return 0;

                case "help":
                case "":
                    return Emit(true, HelpText());

                default:
                    // 允许直接 orca-cli status / orca-cli 状态
                    return RunOrcaSubcommand(command);
            }
        }
        catch (Exception ex)
        {
            return Emit(false, "命令执行出错：" + ex.Message);
        }
    }

    // ============================================================
    //  /orca 子命令（与旧版 plugin.js 的文案逐条对齐）
    // ============================================================
    private static int RunOrcaSubcommand(string sub)
    {
        var cfg = OrcaConfig.Load();
        sub = (sub ?? string.Empty).Trim().ToLowerInvariant();

        switch (sub)
        {
            case "status":
            case "状态":
                return CmdStatus(cfg);

            case "check":
            case "update":
            case "检查":
                return CmdCheck(cfg);

            case "start":
            case "启动":
                return CmdStart(cfg);

            case "stop":
            case "关闭":
                return CmdStop(cfg);

            case "restart":
            case "重启":
                return CmdRestart(cfg);

            case "open":
            case "打开":
                return CmdOpen(cfg);

            case "log":
            case "日志":
                return CmdLog();

            case "port":
            case "端口":
                return CmdPort(cfg);

            case "config":
            case "配置":
                return CmdConfig(cfg);

            case "health":
            case "diagnose":
            case "诊断":
            case "体检":
                return CmdHealth(cfg);

            case "tray":
            case "托盘":
                return ProcessRunner.StartAppMode("--tray")
                    ? Emit(true, "已拉起 Orca 托盘（右下角虎鲸图标）。")
                    : Emit(false, "启动 Orca 托盘失败（程序文件缺失？）。");

            case "console":
            case "控制台":
                if (OrcaSignals.Signal(OrcaSignals.ConsoleShowEventName))
                {
                    return Emit(true, "已把 Orca 控制台窗口调到前台。");
                }
                return ProcessRunner.StartAppMode("--console")
                    ? Emit(true, "已打开 Orca 控制台窗口（独立管理界面）。")
                    : Emit(false, "打开控制台失败（程序文件缺失？）。");

            case "tray-stop":
            case "trayoff":
            case "关闭托盘":
                return CmdTrayStop();

            case "setup":
            case "安装":
                return ProcessRunner.StartAppMode("--setup")
                    ? Emit(true, "已打开一键安装向导。")
                    : Emit(false, "打开安装向导失败（程序文件缺失？）。");

            case "":
            case "help":
            case "帮助":
                return Emit(true, HelpText());

            default:
                return Emit(true, $"未知子命令「{sub}」。\n\n{HelpText()}");
        }
    }

    private static int CmdStatus(OrcaConfig cfg)
    {
        var (status, owner) = PortInspector.GetStatusWithOwner(cfg.Port);
        var lines = new List<string> { "🐋 Orca DSH Launcher 状态", string.Empty };

        switch (status)
        {
            case PortStatus.Running:
                lines.Add($"● DSH 服务器：运行中（{cfg.ServerUrl}）");
                break;
            case PortStatus.Occupied:
                lines.Add($"⚠️ 端口 {cfg.Port} 被其他程序占用：{owner?.DisplayName ?? "未知程序"}");
                lines.Add("   当前不是 DSH 在运行，请先处理占用。");
                break;
            default:
                if (!DshServer.HasPackageJson(cfg.DshDir))
                {
                    lines.Add($"○ DSH 服务器：未运行（电脑上未安装 DSH：{cfg.DshDir}）");
                    lines.Add("   请打开 Orca 控制台「安装」页一键安装，或直接启动官方 Web 版：npx @deepseek-ai/dsh web");
                }
                else
                {
                    lines.Add("○ DSH 服务器：未运行");
                }
                break;
        }

        var state = UpdateState.Load();
        if (state != null)
        {
            lines.Add(state.HasUpdate
                ? $"🎉 更新：有新版本（官方 {UpdateState.Short(state.RemoteCommit)} / 本地 {UpdateState.Short(state.LocalCommit)}）"
                : $"✅ 更新：当前已是最新版本（{UpdateState.Short(state.LocalCommit)}）");
            lines.Add("检查时间：" + state.CheckedAt);
        }
        else
        {
            lines.Add("更新：还没有检查结果（DSH 刚启动可稍后重试，或 /orca 检查）");
        }

        lines.Add("托盘：" + (OrcaSignals.IsTrayRunning() ? "运行中" : "未运行（/orca 托盘 可拉起）"));
        return Emit(true, string.Join("\n", lines));
    }

    private static int CmdCheck(OrcaConfig cfg)
    {
        var r = UpdateChecker.CheckAndSave(cfg);
        if (!r.Ok)
        {
            return Emit(true, "检查完成，但没拿到结果（网络或本地版本读取失败），请稍后再试。");
        }
        if (r.HasUpdate)
        {
            var checkedAt = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture);
            return Emit(true,
                $"🎉 有更新！\n官方最新版本：{r.RemoteShort}\n你当前版本：{r.LocalShort}\n检查时间：{checkedAt}\n\n"
                + "（提示：是否更新、怎么更新，请咨询懂技术的人，本插件不自动更新）");
        }
        return Emit(true, $"✅ 当前已是最新版本（{r.LocalShort}），检查时间：{DateTime.Now:yyyy-MM-dd HH:mm:ss}");
    }

    private static int CmdStart(OrcaConfig cfg)
    {
        var (status, owner) = PortInspector.GetStatusWithOwner(cfg.Port);
        if (status == PortStatus.Running)
        {
            return Emit(true, $"DSH 服务器已经在运行中（{cfg.ServerUrl}）。");
        }
        if (status == PortStatus.Occupied)
        {
            return Emit(false, $"端口 {cfg.Port} 被 {owner?.DisplayName ?? "未知程序"} 占用，不能启动 DSH。请先关闭占用程序或修改端口。");
        }
        var r = DshServer.Start(cfg);
        return r.Ok
            ? Emit(true, $"已启动 DSH 服务器（后台运行），稍后可在浏览器打开 {cfg.ServerUrl}")
            : Emit(false, "启动 DSH 服务器失败：" + (r.Error ?? "未知原因"));
    }

    private static int CmdStop(OrcaConfig cfg)
    {
        var (status, owner) = PortInspector.GetStatusWithOwner(cfg.Port);
        if (status == PortStatus.Free || owner == null)
        {
            return Emit(true, "DSH 服务器当前未运行，无需关闭。");
        }
        if (status == PortStatus.Occupied)
        {
            return Emit(false, $"端口 {cfg.Port} 被 {owner.DisplayName} 占用，不是 DSH，已取消关闭。");
        }
        var r = DshServer.StopDetached(cfg);
        return r.Ok
            ? Emit(true, $"已请求关闭 DSH 服务器（PID {owner.ProcessId}），界面稍后会断开。")
            : Emit(false, r.Error ?? "关闭失败");
    }

    private static int CmdRestart(OrcaConfig cfg)
    {
        var r = DshServer.RestartDetached(cfg);
        if (!r.Ok) return Emit(false, "重启失败：" + (r.Error ?? "未知原因"));
        var extra = r.Rebuilt ? "（已先重新构建）" : string.Empty;
        return Emit(true, $"已重启 DSH 服务器{extra}（后台运行），稍后可在浏览器打开 {cfg.ServerUrl}");
    }

    private static int CmdOpen(OrcaConfig cfg)
    {
        var (status, owner) = PortInspector.GetStatusWithOwner(cfg.Port);
        if (status == PortStatus.Occupied)
        {
            return Emit(false, $"端口 {cfg.Port} 被 {owner?.DisplayName ?? "未知程序"} 占用，不能打开 DSH 界面。");
        }
        if (status != PortStatus.Running)
        {
            var start = DshServer.Start(cfg);
            if (!start.Ok) return Emit(false, "启动 DSH 服务器失败：" + (start.Error ?? "未知原因"));
            // 构建可能需要 1-2 分钟，等待放宽到 3 分钟
            if (!PortInspector.WaitPortReady(cfg.Port, 180))
            {
                return Emit(false, "DSH 服务器启动超时，请到控制台查看日志。");
            }
        }
        return ProcessRunner.OpenUrl(cfg.ServerUrl)
            ? Emit(true, $"已尝试在浏览器打开 DSH 界面（{cfg.ServerUrl}）。")
            : Emit(false, "打开界面失败。");
    }

    private static int CmdLog()
    {
        var lines = OrcaLog.ReadServerLogTail(30).Where(l => l.Length > 0).ToArray();
        if (lines.Length == 0)
        {
            return Emit(true, "还没有日志（服务器可能从未启动过，或日志文件不存在）。");
        }
        return Emit(true, $"📄 最近 DSH 日志（最后 {lines.Length} 行）：\n" + string.Join("\n", lines));
    }

    private static int CmdPort(OrcaConfig cfg)
    {
        var (status, owner) = PortInspector.GetStatusWithOwner(cfg.Port);
        if (owner == null)
        {
            return Emit(true, $"端口 {cfg.Port} 空闲，DSH 服务器未运行。");
        }
        if (status == PortStatus.Running)
        {
            return Emit(true, $"端口 {cfg.Port} 由 DSH 占用（PID {owner.ProcessId}，{owner.Name}）。");
        }
        return Emit(true, $"⚠️ 端口 {cfg.Port} 被其他程序占用：{(string.IsNullOrEmpty(owner.Name) ? "未知程序" : owner.Name)}（PID {owner.ProcessId}）。");
    }

    private static int CmdConfig(OrcaConfig cfg)
    {
        var text = "🐋 当前配置\n"
                   + "· DSH 目录：" + cfg.DshDir + "\n"
                   + "· 端口：" + cfg.Port + "\n"
                   + "· 仓库：" + cfg.Repo + "\n"
                   + "· 分支：" + cfg.Branch + "\n"
                   + "· 网络超时：" + cfg.CheckTimeoutMs + "ms\n"
                   + "· 界面主题：" + (cfg.IsDark ? "深色" : "浅色") + " / 强调色：" + AccentPresets.Get(cfg.Accent).Name + "\n"
                   + "· DSH 启动时自动拉起托盘：" + (cfg.TrayAutoStart ? "开" : "关") + "\n"
                   + "· 配置文件：" + OrcaPaths.ConfigFile;
        return Emit(true, text);
    }

    private static int CmdHealth(OrcaConfig cfg)
    {
        var lines = new List<string> { "🐋 Orca DSH Launcher 诊断", string.Empty };
        lines.Add("· DSH 目录：" + cfg.DshDir + (Directory.Exists(cfg.DshDir) ? "  ✅ 存在" : "  ❌ 不存在"));

        var (status, owner) = PortInspector.GetStatusWithOwner(cfg.Port);
        lines.Add(status switch
        {
            PortStatus.Running => $"· 端口 {cfg.Port}：✅ DSH 正在运行",
            PortStatus.Occupied => $"· 端口 {cfg.Port}：⚠️ 被 {owner?.DisplayName ?? "未知程序"} 占用（不是 DSH）",
            _ => $"· 端口 {cfg.Port}：○ 空闲（DSH 未运行）",
        });

        var pnpm = ProcessRunner.GetCommandVersion("pnpm");
        var git = ProcessRunner.GetCommandVersion("git");
        var node = ProcessRunner.GetCommandVersion("node");
        lines.Add("· node：" + (node != null ? "✅ " + node : "❌ 未找到（启动 DSH 需要）"));
        lines.Add("· pnpm：" + (pnpm != null ? "✅ " + pnpm : "❌ 未找到（启动 DSH 需要）"));
        lines.Add("· git：" + (git != null ? "✅ " + git : "❌ 未找到（更新检查需要）"));

        var local = UpdateChecker.GetLocalCommit(cfg);
        lines.Add("· 本地 DSH 版本：" + (local != null ? UpdateState.Short(local) : "❌ 读取失败（目录不是 git 仓库？）"));

        var built = DshBuild.ArtifactsPresent(cfg.DshDir);
        lines.Add("· 构建产物：" + (built ? "✅ 齐全" : "⚠️ 缺失（启动时会自动重新构建）"));
        lines.Add("· Orca 托盘：" + (OrcaSignals.IsTrayRunning() ? "✅ 运行中" : "○ 未运行"));
        lines.Add("· 桌面端版本：" + AppInfo.VersionDisplay + "（C# / .NET " + Environment.Version + "）");

        return Emit(true, string.Join("\n", lines));
    }

    private static int CmdTrayStop()
    {
        // 优先用信号让托盘自己优雅退出（会清掉托盘图标）
        if (OrcaSignals.Signal(OrcaSignals.TrayCloseEventName))
        {
            return Emit(true, "已关闭 Orca 托盘。");
        }
        // 信号发不出去说明托盘没在跑
        return Emit(true, "没有找到正在运行的 Orca 托盘（或已关闭）。");
    }

    private static string HelpText() => string.Join("\n", new[]
    {
        "🐋 Orca DSH Launcher 命令帮助",
        string.Empty,
        "  /orca 状态        查看服务器、端口与更新状态",
        "  /orca 检查        立即检查更新",
        "  /orca 启动        启动 DSH 服务器",
        "  /orca 关闭        关闭 DSH 服务器",
        "  /orca 重启        重启 DSH 服务器",
        "  /orca 打开        打开 DSH 界面（未启动会自动启动）",
        "  /orca 日志        查看最近 DSH 运行日志",
        "  /orca 端口        查看端口占用详情",
        "  /orca 配置        查看当前生效配置",
        "  /orca 诊断        一键检查 DSH 环境是否健康",
        "  /orca 控制台      打开控制台管理窗口",
        "  /orca 托盘        启动 Orca 托盘",
        "  /orca 关闭托盘    关闭 Orca 托盘",
        "  /orca 安装        打开一键安装向导",
        "  /orca 帮助        显示本帮助",
        string.Empty,
        "也可用英文：status / check / start / stop / restart / open / log / port / config / health / console / tray / tray-stop / setup / help",
    });

    // ============================================================
    //  quick-check：状态自检（输出 JSON，供测试脚本与外部工具用）
    // ============================================================
    private static int QuickCheck()
    {
        try
        {
            var cfg = OrcaConfig.Load();
            var check = UpdateChecker.Check(cfg);
            var obj = new JsonObject
            {
                ["ok"] = true,
                ["version"] = AppInfo.Version,
                ["runtime"] = ".NET " + Environment.Version,
                ["serverRunning"] = DshServer.IsRunning(cfg),
                ["trayRunning"] = OrcaSignals.IsTrayRunning(),
                ["portStatus"] = PortInspector.ToText(PortInspector.GetStatus(cfg.Port)),
                ["port"] = cfg.Port,
                ["dshDir"] = cfg.DshDir,
                ["trayAutoStart"] = cfg.TrayAutoStart,
                ["theme"] = cfg.Theme,
                ["accent"] = cfg.Accent,
                ["dshAutoStart"] = ShortcutManager.IsServerAutoStartEnabled(),
                ["trayStartupEnabled"] = ShortcutManager.IsTrayAutoStartEnabled(),
                ["dshInstalled"] = DshServer.IsDshInstalled(cfg.DshDir),
                ["buildArtifacts"] = DshBuild.ArtifactsPresent(cfg.DshDir),
                ["updateOk"] = check.Ok,
                ["hasUpdate"] = check.HasUpdate,
                ["localCommit"] = check.LocalCommit,
                ["remoteCommit"] = check.RemoteCommit,
            };
            Console.WriteLine(obj.ToJsonString(JsonOutPretty));
            return 0;
        }
        catch (Exception ex)
        {
            var obj = new JsonObject { ["ok"] = false, ["error"] = ex.Message };
            Console.WriteLine(obj.ToJsonString(JsonOut));
            return 1;
        }
    }

    // ============================================================
    //  update-check：执行一次更新检查并写入状态文件（插件启动时调用）
    // ============================================================
    private static int UpdateCheckJson()
    {
        try
        {
            var cfg = OrcaConfig.Load();
            var r = UpdateChecker.CheckAndSave(cfg);
            var obj = new JsonObject
            {
                ["ok"] = r.Ok,
                ["hasUpdate"] = r.HasUpdate,
                ["localCommit"] = r.LocalCommit,
                ["remoteCommit"] = r.RemoteCommit,
                ["localShort"] = r.LocalShort,
                ["remoteShort"] = r.RemoteShort,
                ["error"] = r.Error,
            };
            Console.WriteLine(obj.ToJsonString(JsonOut));
            return 0;
        }
        catch (Exception ex)
        {
            Console.WriteLine(new JsonObject { ["ok"] = false, ["error"] = ex.Message }.ToJsonString(JsonOut));
            return 1;
        }
    }

    // ============================================================
    //  install-plugin / uninstall-plugin（替代 install.ps1 / uninstall.ps1）
    // ============================================================
    private static int InstallPlugin(List<string> args)
    {
        var source = TakeOption(args, "--source") ?? FindRepoRoot();
        var dshDir = TakeOption(args, "--dsh-dir");
        bool skipStartup = args.Any(a => a.Equals("--skip-startup", StringComparison.OrdinalIgnoreCase));
        bool skipDesktop = args.Any(a => a.Equals("--skip-desktop", StringComparison.OrdinalIgnoreCase));

        Console.WriteLine();
        Console.WriteLine("======================================");
        Console.WriteLine("  Orca DSH Launcher - 安装到 DSH");
        Console.WriteLine("======================================");
        Console.WriteLine();

        if (source == null || !File.Exists(Path.Combine(source, "plugin.js")))
        {
            Console.WriteLine("[错误] 找不到插件文件（plugin.js）。请用 --source 指定插件包目录。");
            return 1;
        }
        if (!File.Exists(Path.Combine(source, "bin", "orca.exe")))
        {
            Console.WriteLine("[错误] 找不到 bin\\orca.exe，请先运行 build.cmd 编译。");
            return 1;
        }

        var cfg = OrcaConfig.Load();
        var targetDshDir = dshDir ?? cfg.DshDir;

        // 1) 备份现有插件与登记文件
        var backupDir = OrcaPaths.BackupDir;
        var stamp = DateTime.Now.ToString("yyyyMMdd-HHmmss", CultureInfo.InvariantCulture);
        OrcaPaths.EnsureDir(backupDir);
        try
        {
            if (File.Exists(OrcaPaths.CordisPatchFile))
            {
                File.Copy(OrcaPaths.CordisPatchFile, Path.Combine(backupDir, $"cordis.patch.yml.bak-{stamp}"), true);
            }
            if (Directory.Exists(OrcaPaths.PluginInstallDir))
            {
                CopyDir(OrcaPaths.PluginInstallDir, Path.Combine(backupDir, $"orca-dsh-launcher.old-{stamp}"));
            }
            Console.WriteLine("[1/4] 已备份原有插件与配置 -> " + backupDir);
        }
        catch (Exception ex)
        {
            Console.WriteLine("[1/4] 备份失败（继续安装）：" + ex.Message);
        }

        // 2) 复制文件 + 登记 + 写配置
        var log = new InstallLog(Path.Combine(Path.GetTempPath(), "orca-install-plugin.log"));
        var service = new InstallService(log);
        if (!service.InstallPlugin(source, targetDshDir))
        {
            Console.WriteLine("[2/4] 安装失败，详情见：" + log.FilePath);
            return 1;
        }
        Console.WriteLine("[2/4] 插件文件已复制并登记到 DSH");

        // 3) 开机自启托盘快捷方式
        var exe = Path.Combine(OrcaPaths.PluginInstallDir, "bin", "orca.exe");
        if (skipStartup)
        {
            Console.WriteLine("[3/4] 已按参数跳过开机自启快捷方式");
        }
        else
        {
            Console.WriteLine(ShortcutManager.SetTrayAutoStart(true, exe)
                ? "[3/4] 已创建开机自启托盘快捷方式（取消：重跑并加 --skip-startup）"
                : "[3/4] 创建开机自启快捷方式失败（不影响插件安装）");
        }

        // 4) 桌面图标
        if (skipDesktop)
        {
            Console.WriteLine("[4/4] 已按参数跳过桌面图标");
        }
        else
        {
            Console.WriteLine(ShortcutManager.CreateDesktopShortcut(exe)
                ? "[4/4] 已创建桌面图标「Orca DSH Launcher」"
                : "[4/4] 创建桌面图标失败（不影响插件安装）");
        }

        Console.WriteLine();
        Console.WriteLine("======================================");
        Console.WriteLine("  安装完成！重启 DSH 即可生效");
        Console.WriteLine("  · 插件位置：" + OrcaPaths.PluginInstallDir);
        Console.WriteLine("  · 双击桌面「Orca DSH Launcher」打开控制台");
        Console.WriteLine("  · 在 DSH 输入框敲 /orca 查看所有命令");
        Console.WriteLine("======================================");
        Console.WriteLine();
        return 0;
    }

    private static int UninstallPlugin(List<string> args)
    {
        bool killTray = args.Any(a => a.Equals("--kill-tray", StringComparison.OrdinalIgnoreCase));
        bool keepShortcut = args.Any(a => a.Equals("--keep-shortcut", StringComparison.OrdinalIgnoreCase));

        Console.WriteLine();
        Console.WriteLine("======================================");
        Console.WriteLine("  Orca DSH Launcher - 卸载");
        Console.WriteLine("======================================");
        Console.WriteLine();

        // 1) 备份
        var backupDir = OrcaPaths.BackupDir;
        var stamp = DateTime.Now.ToString("yyyyMMdd-HHmmss", CultureInfo.InvariantCulture);
        OrcaPaths.EnsureDir(backupDir);
        try
        {
            if (Directory.Exists(OrcaPaths.PluginInstallDir))
            {
                CopyDir(OrcaPaths.PluginInstallDir, Path.Combine(backupDir, $"orca-dsh-launcher.uninstalled-{stamp}"));
            }
            if (File.Exists(OrcaPaths.CordisPatchFile))
            {
                File.Copy(OrcaPaths.CordisPatchFile, Path.Combine(backupDir, $"cordis.patch.yml.before-uninstall-{stamp}"), true);
            }
            Console.WriteLine("[1/5] 已备份到 " + backupDir);
        }
        catch (Exception ex)
        {
            Console.WriteLine("[1/5] 备份失败（继续卸载）：" + ex.Message);
        }

        // 2) 关闭托盘（可选）
        if (killTray)
        {
            Console.WriteLine(OrcaSignals.Signal(OrcaSignals.TrayCloseEventName)
                ? "[2/5] 已按参数关闭运行中的 Orca 托盘"
                : "[2/5] 没有运行中的 Orca 托盘");
        }
        else
        {
            Console.WriteLine("[2/5] 未主动结束托盘/控制台（uninstall.cmd 已先请它们退出；加 --kill-tray 可强制关闭）");
        }

        // 3) 删除插件目录
        //    注意：本程序自己可能就跑在这个目录里（卸载时用的是已安装的 orca-cli.exe），
        //    自己的 exe/dll 删不掉是正常的 —— 那就逐个删能删的，剩下的交给一条
        //    "本进程退出后再执行" 的后台命令收尾。
        Console.WriteLine(RemoveInstallDir());

        // 4) 移除登记
        Console.WriteLine(CordisPatch.Unregister()
            ? "[4/5] 已从 DSH 配置移除插件登记"
            : "[4/5] 配置里没有插件登记，跳过");

        // 5) 快捷方式
        if (keepShortcut)
        {
            Console.WriteLine("[5/5] 已按参数保留开机自启快捷方式");
        }
        else
        {
            ShortcutManager.SetTrayAutoStart(false);
            ShortcutManager.SetServerAutoStart(false);
            ShortcutManager.RemoveDesktopShortcut();
            Console.WriteLine("[5/5] 已删除开机自启与桌面快捷方式");
        }

        Console.WriteLine();
        Console.WriteLine("卸载完成！重启 DSH 后插件将不再运行。");
        Console.WriteLine("备份保留在：" + backupDir + "（需要时可原样拷回）");
        Console.WriteLine();
        return 0;
    }

    /// <summary>
    /// 删除插件安装目录。删不掉的（本程序自身占用）安排一条脱钩的后台命令，
    /// 等本进程退出后再清理，并把情况如实告诉用户。
    /// </summary>
    private static string RemoveInstallDir()
    {
        var dir = OrcaPaths.PluginInstallDir;
        if (!Directory.Exists(dir)) return "[3/5] 插件目录不存在（可能之前已卸载），跳过";

        // 先逐个删文件，能删多少删多少（不因为一个失败就整体放弃）
        foreach (var file in Directory.EnumerateFiles(dir, "*", SearchOption.AllDirectories))
        {
            try { File.Delete(file); } catch { /* 占用中，留给后台清理 */ }
        }
        try
        {
            Directory.Delete(dir, recursive: true);
            return "[3/5] 已从 DSH 插件目录删除";
        }
        catch
        {
            // 还有文件被占用（通常就是正在运行的 orca-cli.exe 自己）
            var cmd = $"timeout /t 3 /nobreak >nul & rmdir /s /q \"{dir}\" >nul 2>&1";
            var proc = ProcessRunner.StartHiddenCmd(cmd);
            proc?.Dispose();
            return "[3/5] 插件目录里还有正在使用的文件（就是本卸载程序自己），已安排在几秒后自动清理";
        }
    }
    // ============================================================
    //  selftest：全量自检（替代 test-all.ps1 的核心检查项）
    // ============================================================
    private static int SelfTest()
    {
        int pass = 0, fail = 0;

        void Check(string name, Func<string?> body)
        {
            try
            {
                var err = body();
                if (err == null)
                {
                    Console.WriteLine($"-- {name} ... [OK]");
                    pass++;
                }
                else
                {
                    Console.WriteLine($"-- {name} ... [失败] {err}");
                    fail++;
                }
            }
            catch (Exception ex)
            {
                Console.WriteLine($"-- {name} ... [失败] {ex.Message}");
                fail++;
            }
        }

        Console.WriteLine();
        Console.WriteLine("======================================");
        Console.WriteLine("  Orca DSH Launcher 全量自检");
        Console.WriteLine("======================================");
        Console.WriteLine();

        Check("1/9 版本号可读（package.json 单一来源）", () =>
            AppInfo.Version == "0.0.0" ? "读不到版本号" : null);

        Check("2/9 配置读写往返（UTF-8 无 BOM）", () =>
        {
            var cfg = OrcaConfig.Load();
            var port = cfg.Port;
            if (!cfg.Save()) return "写配置失败";
            var again = OrcaConfig.Load();
            return again.Port == port ? null : "读回的端口与写入不一致";
        });

        Check("3/9 端口探测与归属判断", () =>
        {
            var cfg = OrcaConfig.Load();
            var status = PortInspector.GetStatus(cfg.Port);
            return Enum.IsDefined(status) ? null : "端口状态异常";
        });

        Check("4/9 使用统计原子写入", () =>
        {
            var s = OrcaStats.Load();
            return s.Save() ? null : "统计写入失败";
        });

        Check("5/9 虎鲸图标资源存在", () =>
            AppInfo.TrayIconPath != null ? null : "找不到 dsh-tray.ico");

        Check("6/9 快捷方式创建 / 删除", () =>
        {
            var tmp = Path.Combine(Path.GetTempPath(), "orca-selftest-" + Guid.NewGuid().ToString("N") + ".lnk");
            if (!ShellShortcut.Create(tmp, AppInfo.ExecutablePath, "--console", AppInfo.BaseDir, "自检用快捷方式")) return "创建 .lnk 失败";
            var exists = File.Exists(tmp);
            ShellShortcut.Delete(tmp);
            return exists ? null : ".lnk 未生成";
        });

        Check("7/9 cordis.patch.yml 登记 / 反登记", () =>
        {
            var tmp = Path.Combine(Path.GetTempPath(), "orca-selftest-patch-" + Guid.NewGuid().ToString("N") + ".yml");
            try
            {
                Utf8Files.WriteAllText(tmp, "# test\n");
                if (!CordisPatch.Register(tmp)) return "登记失败";
                if (!CordisPatch.IsRegistered(tmp)) return "登记后读不到";
                if (!CordisPatch.Unregister(tmp)) return "反登记失败";
                if (CordisPatch.IsRegistered(tmp)) return "反登记后仍有残留";
                return null;
            }
            finally
            {
                try { File.Delete(tmp); } catch { /* 忽略 */ }
            }
        });

        Check("8/9 日志读写与轮转判定", () =>
        {
            var log = new InstallLog(Path.Combine(Path.GetTempPath(), "orca-selftest-log.txt"));
            log.Clear();
            log.Write("自检写入一行");
            var lines = log.ReadTail(5);
            try { File.Delete(log.FilePath); } catch { /* 忽略 */ }
            return lines.Any(l => l.Contains("自检写入一行")) ? null : "日志读回失败";
        });

        Check("9/9 环境探测（node / git / pnpm）", () =>
        {
            var node = ProcessRunner.GetCommandVersion("node");
            var git = ProcessRunner.GetCommandVersion("git");
            // pnpm 缺失只提示不算失败（用户可能只用官方 Web 版）
            if (node == null && git == null) return "node 与 git 都探测不到（外部命令调用异常？）";
            return null;
        });

        Console.WriteLine();
        Console.WriteLine("======================================");
        Console.WriteLine($"  结果：通过 {pass} 项 / 失败 {fail} 项");
        Console.WriteLine("  " + (fail == 0 ? "全部通过，可以放心使用！" : "有失败项，请查看上面的 [失败] 信息"));
        Console.WriteLine("======================================");
        Console.WriteLine();
        return fail == 0 ? 0 : 1;
    }

    // ============================================================
    //  小工具
    // ============================================================

    /// <summary>输出结果：--json 时输出 {kind,text}，否则输出纯文本。</summary>
    private static int Emit(bool success, string text)
    {
        if (_json)
        {
            var obj = new JsonObject
            {
                ["kind"] = success ? "success" : "error",
                ["text"] = text,
            };
            Console.WriteLine(obj.ToJsonString(JsonOut));
        }
        else
        {
            Console.WriteLine(text);
        }
        // 命令级失败也返回 0：调用方按 kind 判断，避免 execFile 抛异常丢消息
        return 0;
    }

    /// <summary>JSON 输出选项：中文直接输出，不转成 \uXXXX（日志更好读）。</summary>
    private static readonly JsonSerializerOptions JsonOut = new()
    {
        WriteIndented = false,
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    /// <summary>JSON 输出选项（带缩进版，quick-check 用）。</summary>
    private static readonly JsonSerializerOptions JsonOutPretty = new()
    {
        WriteIndented = true,
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    /// <summary>取出 --key value 形式的参数。</summary>
    private static string? TakeOption(List<string> args, string key)
    {
        for (int i = 0; i < args.Count - 1; i++)
        {
            if (string.Equals(args[i], key, StringComparison.OrdinalIgnoreCase))
            {
                return args[i + 1];
            }
        }
        return null;
    }

    /// <summary>从当前 exe 位置往上找仓库根（含 plugin.js 的目录）。</summary>
    private static string? FindRepoRoot()
    {
        var dir = new DirectoryInfo(AppInfo.BaseDir);
        for (int i = 0; i < 6 && dir != null; i++)
        {
            if (File.Exists(Path.Combine(dir.FullName, "plugin.js"))) return dir.FullName;
            dir = dir.Parent;
        }
        return null;
    }

    private static void CopyDir(string src, string dst)
    {
        Directory.CreateDirectory(dst);
        foreach (var file in Directory.EnumerateFiles(src, "*", SearchOption.AllDirectories))
        {
            var rel = Path.GetRelativePath(src, file);
            var target = Path.Combine(dst, rel);
            OrcaPaths.EnsureParentDir(target);
            File.Copy(file, target, true);
        }
    }
}
