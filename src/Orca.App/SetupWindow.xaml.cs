using System.Windows;
using System.Windows.Input;
using System.Windows.Threading;
using Orca.Core;
using Orca.Core.Ui;

namespace Orca.App;

/// <summary>
/// 一键安装向导（替代 orca-setup.ps1）。
/// 给"完全没装过 DSH 的电脑"用：环境检测 → 网络检测 → 选位置 →
/// 下载安装 DSH → 装 Orca 插件 → 启动并打开界面。
/// </summary>
public partial class SetupWindow : Window
{
    private enum Phase { Idle, Cloning, Installing, Building, Finishing, Done, Failed }

    private readonly InstallLog _log = InstallLog.ForSetup();
    private readonly InstallService _install;
    private readonly DispatcherTimer _tick = new();

    private Phase _phase = Phase.Idle;
    private System.Diagnostics.Process? _proc;
    private string _dshDir = string.Empty;
    private bool _dirExistedBefore;
    private bool _envOk;
    private string? _pluginSource;

    /// <summary>构造安装向导窗口。</summary>
    public SetupWindow()
    {
        InitializeComponent();
        _install = new InstallService(_log);

        HookEvents();
        SourceInitialized += (_, _) => Win32Helper.ApplyWindowClassIcon(this);
        Loaded += (_, _) =>
        {
            var logo = IconLoader.LoadImage();
            if (logo != null)
            {
                imgLogo.Source = logo;
                Icon = logo;
            }
            ThemeApplier.Apply(this, OrcaConfig.Load().IsDark, AccentPresets.Current());
            ShowPage("welcome");
            lblStatus.Text = "欢迎使用";
        };
        Closed += (_, _) => _tick.Stop();
    }

    private void HookEvents()
    {
        titleBar.MouseLeftButtonDown += (_, e) =>
        {
            if (e.LeftButton != MouseButtonState.Pressed) return;
            try { DragMove(); } catch { /* 忽略 */ }
        };
        btnMin.Click += (_, _) => WindowState = WindowState.Minimized;
        btnClose.Click += (_, _) =>
        {
            // 安装过程中不允许直接关（会打断安装）
            if (_phase is Phase.Cloning or Phase.Installing or Phase.Building or Phase.Finishing)
            {
                OrcaDialog.Show(this, "Orca DSH Launcher", "正在安装中，请先点击「取消安装」。", OrcaDialogType.Info, OrcaDialogButtons.Ok);
                return;
            }
            Close();
        };

        btnWelcomeNext.Click += async (_, _) =>
        {
            ShowPage("env");
            await RunEnvCheckAsync();
        };

        btnEnvRetry.Click += async (_, _) => await RunEnvCheckAsync();
        btnEnvNext.Click += async (_, _) =>
        {
            if (!_envOk)
            {
                OrcaDialog.Show(this, "Orca DSH Launcher", "还有东西没装好，先装好再继续哦。", OrcaDialogType.Warning, OrcaDialogButtons.Ok);
                return;
            }
            ShowPage("net");
            await RunNetCheckAsync();
        };

        btnNetRetry.Click += async (_, _) => await RunNetCheckAsync();
        btnNetNext.Click += (_, _) =>
        {
            ShowPage("dir");
            // 默认位置（可用环境变量 ORCA_SETUP_DEFAULT_DIR 覆盖，方便自动化测试）
            var envDir = Environment.GetEnvironmentVariable("ORCA_SETUP_DEFAULT_DIR");
            var defaultDir = string.IsNullOrWhiteSpace(envDir)
                ? Path.Combine(@"D:\", "deepseek-harness")
                : Path.Combine(envDir, "deepseek-harness");
            dirHint.Text = "默认位置：" + defaultDir + "（也可以点「选择文件夹…」自己定）";
            if (string.IsNullOrWhiteSpace(_dshDir)) _dshDir = defaultDir;
            dirPath.Text = _dshDir;
            dirPath.Foreground = ThemeApplier.GetBrush(this, "ColorTextPrimary");
        };

        btnBrowse.Click += (_, _) =>
        {
            var dlg = new Microsoft.Win32.OpenFolderDialog
            {
                Title = "选择 DSH 要安装到的文件夹",
                Multiselect = false,
            };
            if (dlg.ShowDialog(this) != true) return;
            _dshDir = Path.Combine(dlg.FolderName, "deepseek-harness");
            dirPath.Text = _dshDir;
            dirPath.Foreground = ThemeApplier.GetBrush(this, "ColorTextPrimary");
        };

        btnDirBack.Click += (_, _) => ShowPage("net");
        btnDirNext.Click += (_, _) =>
        {
            if (string.IsNullOrWhiteSpace(_dshDir))
            {
                OrcaDialog.Show(this, "Orca DSH Launcher", "请先选择一个安装位置。", OrcaDialogType.Warning, OrcaDialogButtons.Ok);
                return;
            }
            _pluginSource = PluginPayload.Resolve(AppInfo.PackageRootDir);
            if (_pluginSource == null)
            {
                OrcaDialog.Show(this, "Orca DSH Launcher", "找不到插件文件包，请重新下载本程序后再试。", OrcaDialogType.Error, OrcaDialogButtons.Ok);
                return;
            }
            ShowPage("install");
            StartInstall();
        };

        btnCancelInstall.Click += (_, _) =>
        {
            ProcessRunner.TryKillTree(_proc);
            _proc = null;
            _phase = Phase.Idle;
            _tick.Stop();
            installStatus.Text = "已取消安装（可点「‹ 上一步」删除残留并重新选择位置）";
            installStatus.Foreground = ThemeApplier.GetBrush(this, "ColorWarnFg");
            btnCancelInstall.IsEnabled = false;
            btnInstallNext.IsEnabled = true;
        };

        btnInstallBack.Click += (_, _) => BackFromInstall();

        btnInstallNext.Click += (_, _) => ShowPage(_phase == Phase.Done ? "done" : "dir");

        btnLaunch.Click += async (_, _) =>
        {
            btnLaunch.IsEnabled = false;
            lblStatus.Text = "正在启动 DSH 并打开界面…";
            var dir = _dshDir;
            var port = OrcaConfig.Load().Port;
            var ok = await Task.Run(() =>
            {
                var r = _install.StartFromDir(dir, port);
                if (!r.Ok) return false;
                if (!PortInspector.WaitPortReady(port, 120)) return false;
                ProcessRunner.OpenUrl("http://127.0.0.1:" + port);
                return true;
            });
            if (ok)
            {
                lblStatus.Text = "DSH 已启动，浏览器已打开";
            }
            else
            {
                lblStatus.Text = $"启动超时，请稍后手动打开：http://127.0.0.1:{port}";
                OrcaDialog.Show(this, "Orca DSH Launcher",
                    $"DSH 启动较慢，稍后手动在浏览器打开：http://127.0.0.1:{port}\n（或双击桌面「Orca DSH Launcher」打开管理窗口）",
                    OrcaDialogType.Info, OrcaDialogButtons.Ok);
                btnLaunch.IsEnabled = true;
            }
        };

        btnDoneClose.Click += (_, _) => Close();

        _tick.Interval = TimeSpan.FromMilliseconds(800);
        _tick.Tick += OnTick;
    }

    // ============================================================
    //  页面切换 + 步骤条
    // ============================================================
    private void ShowPage(string name)
    {
        var pages = new Dictionary<string, System.Windows.Controls.Panel>
        {
            ["welcome"] = pageWelcome,
            ["env"] = pageEnv,
            ["net"] = pageNet,
            ["dir"] = pageDir,
            ["install"] = pageInstall,
            ["done"] = pageDone,
        };
        foreach (var kv in pages)
        {
            kv.Value.Visibility = kv.Key == name ? Visibility.Visible : Visibility.Collapsed;
        }

        var steps = new Dictionary<string, System.Windows.Controls.TextBlock>
        {
            ["welcome"] = step1,
            ["env"] = step2,
            ["net"] = step3,
            ["dir"] = step4,
            ["install"] = step5,
            ["done"] = step5,
        };
        var accent = ThemeApplier.GetBrush(this, "ColorAccent");
        var muted = ThemeApplier.GetBrush(this, "ColorTextMuted");
        foreach (var kv in steps)
        {
            bool active = kv.Key == name;
            kv.Value.Foreground = active ? accent : muted;
            kv.Value.FontWeight = active ? FontWeights.Bold : FontWeights.Normal;
        }
    }

    // ============================================================
    //  环境检测
    // ============================================================
    private async Task RunEnvCheckAsync()
    {
        lblStatus.Text = "正在检查电脑环境…";
        envNodeTag.Text = "…"; envGitTag.Text = "…"; envPnpmTag.Text = "…";
        envNodeVer.Text = "检查中…"; envGitVer.Text = "检查中…"; envPnpmVer.Text = "检查中…";
        envHelp.Text = string.Empty;

        var env = await Task.Run(InstallService.CheckEnvironment);

        envNodeVer.Text = env.Node ?? "未安装";
        envGitVer.Text = env.Git ?? "未安装";
        envPnpmVer.Text = env.Pnpm ?? "未安装";

        var okBrush = ThemeApplier.GetBrush(this, "ColorOkFg");
        var errBrush = ThemeApplier.GetBrush(this, "ColorErrFg");
        envNodeTag.Text = env.Node != null ? "✅" : "❌";
        envNodeTag.Foreground = env.Node != null ? okBrush : errBrush;
        envGitTag.Text = env.Git != null ? "✅" : "❌";
        envGitTag.Foreground = env.Git != null ? okBrush : errBrush;
        envPnpmTag.Text = env.Pnpm != null ? "✅" : "❌";
        envPnpmTag.Foreground = env.Pnpm != null ? okBrush : errBrush;

        _envOk = env.Ok;
        if (!env.Ok)
        {
            // 向导页给更详细的安装指引（与旧版文案一致）
            var tips = new List<string>();
            if (env.Node == null) tips.Add("Node.js（下载地址：https://nodejs.org/zh-cn，装完重启本向导）");
            if (env.Git == null) tips.Add("Git（下载地址：https://git-scm.com/download/win，一路下一步装完）");
            if (env.Pnpm == null) tips.Add("pnpm（装好 Node.js 后，在命令提示符里输入：npm install -g pnpm）");
            envHelp.Text = "还需要安装：" + string.Join("；", tips);
            envHelp.Foreground = ThemeApplier.GetBrush(this, "ColorWarnFg");
        }
        else
        {
            envHelp.Text = "环境齐全，可以继续！";
            envHelp.Foreground = okBrush;
        }
        lblStatus.Text = "环境检测完成";
    }

    // ============================================================
    //  网络检测
    // ============================================================
    private async Task RunNetCheckAsync()
    {
        lblStatus.Text = "正在检测网络…（需要几秒钟）";
        netTag.Text = "检测中…";
        netTag.Foreground = ThemeApplier.GetBrush(this, "ColorTextSecondary");
        netDetail.Text = string.Empty;
        netHelp.Text = string.Empty;

        var net = await Task.Run(InstallService.CheckGithubNetwork);
        netDetail.Text = "测试结果：" + net.Detail;

        if (net.GithubOk)
        {
            netTag.Text = "✅ 网络良好";
            netTag.Foreground = ThemeApplier.GetBrush(this, "ColorOkFg");
            netHelp.Text = "可以正常下载 DSH，继续吧！";
            netHelp.Foreground = ThemeApplier.GetBrush(this, "ColorOkFg");
            btnNetNext.IsEnabled = true;
        }
        else if (net.Github || net.Codeload)
        {
            netTag.Text = "⚠️ 网络部分受限";
            netTag.Foreground = ThemeApplier.GetBrush(this, "ColorWarnFg");
            netHelp.Text = "GitHub 部分地址连不上，下载可能很慢或中途失败。建议：检查代理/VPN 设置，或换网络后重试。也可以先继续，失败了再回来处理。";
            netHelp.Foreground = ThemeApplier.GetBrush(this, "ColorWarnFg");
            btnNetNext.IsEnabled = true;
        }
        else
        {
            netTag.Text = "❌ 无法访问 GitHub";
            netTag.Foreground = ThemeApplier.GetBrush(this, "ColorErrFg");
            netHelp.Text = "当前网络访问不了 GitHub，下载会失败。建议：① 检查是否开了代理/VPN（关掉或换节点试试）；② 更换网络（如手机热点）；③ 联系网络管理员。解决后点「重新检测」。";
            netHelp.Foreground = ThemeApplier.GetBrush(this, "ColorErrFg");
            btnNetNext.IsEnabled = false;
        }
        lblStatus.Text = "网络检测完成";
    }

    // ============================================================
    //  安装状态机
    // ============================================================
    private void StartInstall()
    {
        _phase = Phase.Idle;
        installTitle.Text = "开始安装";
        installStatus.Text = "准备中…";
        installStatus.Foreground = ThemeApplier.GetBrush(this, "ColorAccent");
        btnCancelInstall.IsEnabled = true;
        btnInstallBack.IsEnabled = true;
        btnInstallNext.IsEnabled = false;
        _log.Clear();

        _dirExistedBefore = Directory.Exists(_dshDir);

        // 父目录不存在时自动创建（避免奇怪路径卡住小白用户）
        var parent = Path.GetDirectoryName(_dshDir);
        if (!string.IsNullOrWhiteSpace(parent) && !Directory.Exists(parent))
        {
            try
            {
                Directory.CreateDirectory(parent);
                _log.Write("[安装] 自动创建了文件夹：" + parent);
            }
            catch
            {
                installStatus.Text = "❌ 无法创建文件夹：" + parent;
                _phase = Phase.Failed;
                return;
            }
        }

        var clone = _install.StartClone(_dshDir);
        if (!clone.Ok)
        {
            FailPhase("❌ " + clone.Error);
            return;
        }
        if (clone.Proc != null)
        {
            _phase = Phase.Cloning;
            installStatus.Text = "正在下载 DSH 源码（git clone，取决于网速，请耐心等待）…";
            _proc = clone.Proc;
            _tick.Start();
            return;
        }
        StartDeps();
    }

    private void StartDeps()
    {
        _phase = Phase.Installing;
        installStatus.Text = "正在安装依赖（pnpm install，通常需要 10~30 分钟，请耐心等待）…";
        var deps = _install.StartDeps(_dshDir);
        if (!deps.Ok)
        {
            FailPhase("❌ " + deps.Error);
            return;
        }
        _proc = deps.Proc;
        _tick.Start();
    }

    private void StartBuild()
    {
        _phase = Phase.Building;
        installStatus.Text = "正在构建 DSH（pnpm run build，需要几分钟，请耐心等待）…";
        var build = _install.StartBuild(_dshDir);
        if (!build.Ok)
        {
            FailPhase("❌ " + build.Error);
            return;
        }
        _proc = build.Proc;
        _tick.Start();
    }

    private void FinishInstall()
    {
        _phase = Phase.Finishing;
        installStatus.Text = "正在安装 Orca 插件…";
        _log.Write(string.Empty);
        _log.Write("第 4 步：安装 Orca DSH Launcher 插件");
        try
        {
            if (_pluginSource != null)
            {
                _install.InstallPlugin(_pluginSource, _dshDir);
                _install.CreateDesktopShortcut();
                // 顺带把托盘设为开机自启（与旧版 install.ps1 默认行为一致）
                var exe = Path.Combine(OrcaPaths.PluginInstallDir, "bin", "orca.exe");
                if (File.Exists(exe)) ShortcutManager.SetTrayAutoStart(true, exe);
            }
        }
        catch (Exception ex)
        {
            _log.Write("[插件] 安装失败：" + ex.Message);
        }

        _phase = Phase.Done;
        installStatus.Text = "✅ 安装完成！";
        installStatus.Foreground = ThemeApplier.GetBrush(this, "ColorOkFg");
        btnCancelInstall.IsEnabled = false;
        btnInstallBack.IsEnabled = false;
        btnInstallNext.IsEnabled = true;
        _tick.Stop();

        doneSummary.Text = "DSH 已装好，Orca 插件也已就位。";
        doneDetail.Text = "DSH 位置：" + _dshDir + "\n"
                          + "插件位置：" + OrcaPaths.PluginInstallDir + "\n"
                          + "以后在 DSH 里输入 /orca 就能用各种命令，右下角会有虎鲸托盘。";
        lblStatus.Text = "全部完成";
    }

    private void OnTick(object? sender, EventArgs e)
    {
        var lines = _log.ReadTail(100);
        if (lines.Length > 0)
        {
            txtLog.Text = string.Join("\n", lines);
            txtLog.ScrollToEnd();
        }

        if (_proc != null && !_proc.HasExited) return;
        int exitCode = -1;
        try
        {
            if (_proc != null) exitCode = _proc.ExitCode;
        }
        catch
        {
            exitCode = -1;
        }

        switch (_phase)
        {
            case Phase.Cloning:
                if (exitCode == 0)
                {
                    installStatus.Text = "✅ DSH 源码下载完成";
                    StartDeps();
                }
                else
                {
                    FailPhase($"❌ 下载失败（退出码 {exitCode}），请查看上方日志，检查网络后重试。");
                }
                break;

            case Phase.Installing:
                if (exitCode == 0)
                {
                    installStatus.Text = "✅ 依赖安装完成";
                    StartBuild();
                }
                else
                {
                    FailPhase($"❌ 依赖安装失败（退出码 {exitCode}），请查看上方日志。常见原因：网络中断、磁盘空间不足。");
                }
                break;

            case Phase.Building:
                if (exitCode == 0)
                {
                    installStatus.Text = "✅ 构建完成";
                    FinishInstall();
                }
                else
                {
                    FailPhase($"❌ 构建 DSH 失败（退出码 {exitCode}），请查看上方日志。常见原因：磁盘空间不足、Node 版本过旧。");
                }
                break;

            default:
                _tick.Stop();
                break;
        }
    }

    private void FailPhase(string message)
    {
        _phase = Phase.Failed;
        installStatus.Text = message;
        installStatus.Foreground = ThemeApplier.GetBrush(this, "ColorErrFg");
        btnCancelInstall.IsEnabled = false;
        btnInstallNext.IsEnabled = true;
        _tick.Stop();
    }

    /// <summary>「‹ 上一步」：取消安装 + 询问删除本次残留 + 回到选择位置页。</summary>
    private void BackFromInstall()
    {
        ProcessRunner.TryKillTree(_proc);
        _proc = null;
        _tick.Stop();

        var canDelete = !_dirExistedBefore && !string.IsNullOrWhiteSpace(_dshDir) && Directory.Exists(_dshDir);
        var msg = "要回到上一步吗？";
        if (canDelete)
        {
            msg += "\n\n本次安装创建了文件夹：\n" + _dshDir + "\n\n是否删除它（包括已下载的文件）？";
        }
        else if (_dirExistedBefore)
        {
            msg += "\n\n（这个文件夹在安装前就存在，为了安全不会删除它）";
        }
        if (!OrcaDialog.Show(this, "上一步", msg, OrcaDialogType.Question, OrcaDialogButtons.YesNo)) return;

        if (canDelete)
        {
            try
            {
                Directory.Delete(_dshDir, recursive: true);
                _log.Write("[安装] 已删除残留目录：" + _dshDir);
            }
            catch
            {
                // 删不掉交给用户处理
            }
        }

        _phase = Phase.Idle;
        _dshDir = string.Empty;
        ShowPage("dir");
        installStatus.Text = string.Empty;
        installStatus.Foreground = ThemeApplier.GetBrush(this, "ColorAccent");
        btnCancelInstall.IsEnabled = true;
        btnInstallNext.IsEnabled = false;
        lblStatus.Text = "已取消安装，可重新选择位置";
    }
}
