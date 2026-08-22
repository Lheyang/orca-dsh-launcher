using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Threading;
using Orca.Core;
using Orca.Core.Ui;

namespace Orca.App;

/// <summary>
/// 图形控制台窗口（替代 dsh-console.ps1）。
/// 界面只管展示与交互，所有业务逻辑都调用 Orca.Core。
/// 耗时操作（检查更新 / 启动服务器 / 安装）都放到后台线程，界面不卡。
/// </summary>
public partial class ConsoleWindow : Window
{
    // ---------- 界面状态 ----------
    private OrcaConfig _cfg = OrcaConfig.Load();
    private UpdateCheckResult? _lastCheck;      // 最近一次手动检查结果
    private string[]? _lastDetails;             // 最近拉到的官方提交标题
    private bool _pendingOpen;                  // 服务器就绪后自动打开浏览器
    private bool _pendingStart;                 // 正在启动服务器
    private bool _refreshBusy;                  // 定时刷新防重入

    // ---------- 安装状态机 ----------
    private enum InstallPhase { Idle, Cloning, Installing, Building, Finishing, Done, Failed }

    private InstallPhase _phase = InstallPhase.Idle;
    private System.Diagnostics.Process? _installProc;
    private string _installDshDir = string.Empty;
    private bool _dirExistedBefore;
    private bool _pendingWebOpen;               // 官方 Web 版就绪后自动打开
    private bool _pendingStartAfterInstall;     // 完整版装完后自动启动
    private readonly InstallLog _installLog = InstallLog.ForConsole();
    private readonly InstallService _install;

    // ---------- 定时器 ----------
    private readonly DispatcherTimer _refreshTimer = new();
    private readonly DispatcherTimer _installTimer = new();

    // ---------- 与托盘联动的信号 ----------
    private System.Threading.EventWaitHandle? _showEvent;
    private System.Threading.EventWaitHandle? _closeEvent;

    /// <summary>构造控制台窗口。</summary>
    public ConsoleWindow()
    {
        InitializeComponent();
        _install = new InstallService(_installLog);

        _showEvent = OrcaSignals.CreateEvent(OrcaSignals.ConsoleShowEventName);
        _closeEvent = OrcaSignals.CreateEvent(OrcaSignals.ConsoleCloseEventName);

        HookEvents();

        SourceInitialized += (_, _) => Win32Helper.ApplyWindowClassIcon(this);
        Loaded += OnWindowLoaded;
        Closed += (_, _) =>
        {
            _refreshTimer.Stop();
            _installTimer.Stop();
            _showEvent?.Dispose();
            _closeEvent?.Dispose();
        };
    }

    // ============================================================
    //  事件绑定
    // ============================================================
    private void HookEvents()
    {
        // 导航
        navOverview.Click += (_, _) => ShowPage("overview");
        navServer.Click += (_, _) => ShowPage("server");
        navInstall.Click += (_, _) => ShowPage("install");
        navLogs.Click += (_, _) => ShowPage("logs");
        navSettings.Click += (_, _) => ShowPage("settings");
        navAbout.Click += (_, _) => ShowPage("about");

        // 标题栏拖动（拖动期间暂停刷新，避免状态查询拖慢拖拽）
        titleBar.MouseLeftButtonDown += (_, e) =>
        {
            if (e.LeftButton != MouseButtonState.Pressed) return;
            try
            {
                _refreshTimer.Stop();
                DragMove();
            }
            catch
            {
                // 拖动异常忽略
            }
            finally
            {
                _refreshTimer.Start();
            }
        };

        btnMin.Click += (_, _) =>
        {
            WindowState = WindowState.Minimized;
            exitPanel.Visibility = Visibility.Collapsed;
        };

        // 关闭按钮 = 内嵌选项面板（最小化到托盘 / 退出程序）
        btnClose.Click += (_, _) =>
        {
            if (exitPanel.Visibility == Visibility.Visible)
            {
                exitPanel.Visibility = Visibility.Collapsed;
            }
            else
            {
                exitPanel.Visibility = Visibility.Visible;
                btnExitQuit.Focus();
            }
        };

        btnExitToTray.Click += (_, _) =>
        {
            exitPanel.Visibility = Visibility.Collapsed;
            // 托盘没在跑就先拉起来，否则"最小化到托盘"会找不回窗口
            if (!OrcaSignals.IsTrayRunning()) ProcessRunner.StartAppMode("--tray");
            Hide();
            lblStatus.Text = "已最小化到托盘（托盘「打开管理界面」可恢复）";
        };

        btnExitQuit.Click += (_, _) =>
        {
            exitPanel.Visibility = Visibility.Collapsed;
            OrcaSignals.Signal(OrcaSignals.TrayCloseEventName);   // 通知托盘一起退出
            Close();
        };

        // 点面板以外的地方 → 收起面板
        PreviewMouseDown += (_, e) =>
        {
            if (exitPanel.Visibility != Visibility.Visible) return;
            var el = e.OriginalSource as DependencyObject;
            while (el != null)
            {
                if (ReferenceEquals(el, exitPanel) || ReferenceEquals(el, btnClose)) return;
                el = VisualTreeHelper.GetParent(el);
            }
            exitPanel.Visibility = Visibility.Collapsed;
        };

        // 概览页
        btnStartTray.Click += (_, _) =>
        {
            if (ProcessRunner.StartAppMode("--tray"))
            {
                lblStatus.Text = "正在启动托盘…（几秒后右下角出现虎鲸图标）";
            }
            else
            {
                lblStatus.Text = "托盘程序缺失，请重装插件";
            }
        };
        btnOpenOverview.Click += async (_, _) => await OpenDshUiAsync();
        btnCheckOverview.Click += async (_, _) => await CheckUpdateAsync();
        btnUpdateDsh.Click += async (_, _) => await UpdateDshAsync();

        // 服务器页
        btnOpenServer.Click += async (_, _) => await OpenDshUiAsync();
        btnStartServer.Click += async (_, _) => await StartServerAsync();
        btnStopServer.Click += async (_, _) => await StopServerAsync();
        btnRestartServer.Click += async (_, _) => await RestartServerAsync();

        // 安装页
        btnOpenSite.Click += (_, _) => ProcessRunner.OpenUrl("https://github.com/deepseek-ai/deepseek-harness");
        btnInstallWeb.Click += async (_, _) => await StartWebVersionAsync();
        btnInstallFull.Click += async (_, _) => await StartFullInstallAsync();
        btnInstallCancel.Click += (_, _) => CancelInstall();

        // 日志页
        btnLogRefresh.Click += (_, _) =>
        {
            UpdateLogDisplay();
            lblStatus.Text = "日志已刷新";
        };
        btnLogClear.Click += (_, _) =>
        {
            if (OrcaLog.ClearServerLog())
            {
                UpdateLogDisplay();
                lblStatus.Text = "日志已清空";
            }
            else
            {
                lblStatus.Text = "清空失败（日志文件可能正被占用）";
            }
        };

        // 设置页
        btnSave.Click += (_, _) => SaveSettings();

        // 定时器
        _refreshTimer.Interval = TimeSpan.FromSeconds(4);
        _refreshTimer.Tick += async (_, _) => await OnRefreshTickAsync();
        _installTimer.Interval = TimeSpan.FromMilliseconds(800);
        _installTimer.Tick += OnInstallTick;
    }

    // ============================================================
    //  窗口加载
    // ============================================================
    private void OnWindowLoaded(object sender, RoutedEventArgs e)
    {
        Win32Helper.ApplyWindowClassIcon(this);

        // 标题栏 logo + 窗口图标
        var logo = IconLoader.LoadImage();
        if (logo != null)
        {
            imgLogo.Source = logo;
            Icon = logo;
        }

        // 主题 + 强调色
        _cfg = OrcaConfig.Load();
        ApplyThemeFromConfig();

        if (_cfg.IsDark) rdoDark.IsChecked = true; else rdoLight.IsChecked = true;
        switch (_cfg.Accent)
        {
            case "green": rdoAccentGreen.IsChecked = true; break;
            case "purple": rdoAccentPurple.IsChecked = true; break;
            case "amber": rdoAccentAmber.IsChecked = true; break;
            case "rose": rdoAccentRose.IsChecked = true; break;
            case "slate": rdoAccentSlate.IsChecked = true; break;
            default: rdoAccentBlue.IsChecked = true; break;
        }

        // 设置项回填
        txtPort.Text = _cfg.Port.ToString();
        txtDshDir.Text = _cfg.DshDir;
        chkTrayAuto.IsChecked = _cfg.TrayAutoStart;
        chkStartup.IsChecked = ShortcutManager.IsTrayAutoStartEnabled();
        chkDshAutoStart.IsChecked = ShortcutManager.IsServerAutoStartEnabled();

        // 版本号 + 使用统计
        lblVer.Text = AppInfo.VersionDisplay;
        lblVerAbout.Text = "版本 " + AppInfo.VersionDisplay;
        OrcaStats.AddLaunch();
        lblStats.Text = OrcaStats.Load().ToDisplayLine();
        lblRuntime.Text = "运行环境：.NET " + Environment.Version + " · C# / WPF 原生桌面程序";

        ShowPage("overview");
        UpdateStatusDisplay();
        _refreshTimer.Start();
        lblStatus.Text = "就绪";

        // 淡入动画
        try
        {
            Root.Opacity = 0;
            Root.BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(200)));
        }
        catch
        {
            Root.Opacity = 1;
        }
    }

    private void ApplyThemeFromConfig()
        => ThemeApplier.Apply(this, _cfg.IsDark, AccentPresets.Get(_cfg.Accent));

    // ============================================================
    //  页面切换
    // ============================================================
    private void ShowPage(string name)
    {
        var pages = new Dictionary<string, System.Windows.Controls.Panel>
        {
            ["overview"] = pageOverview,
            ["server"] = pageServer,
            ["install"] = pageInstall,
            ["logs"] = pageLogs,
            ["settings"] = pageSettings,
            ["about"] = pageAbout,
        };
        var navs = new Dictionary<string, System.Windows.Controls.Button>
        {
            ["overview"] = navOverview,
            ["server"] = navServer,
            ["install"] = navInstall,
            ["logs"] = navLogs,
            ["settings"] = navSettings,
            ["about"] = navAbout,
        };

        foreach (var kv in pages)
        {
            kv.Value.Visibility = kv.Key == name ? Visibility.Visible : Visibility.Collapsed;
        }

        var selBg = ThemeApplier.GetBrush(this, "ColorNavSelectedBg");
        var fgPrimary = ThemeApplier.GetBrush(this, "ColorTextPrimary");
        var fgSecondary = ThemeApplier.GetBrush(this, "ColorTextSecondary");
        foreach (var kv in navs)
        {
            bool active = kv.Key == name;
            kv.Value.Background = active ? selBg : Brushes.Transparent;
            kv.Value.Foreground = active ? fgPrimary : fgSecondary;
            kv.Value.FontWeight = active ? FontWeights.Bold : FontWeights.Normal;
            kv.Value.Tag = active ? "active" : null;
        }

        if (name == "logs") UpdateLogDisplay();
        if (name == "install") UpdateInstallCard();
    }

    // ============================================================
    //  状态刷新
    // ============================================================
    private void UpdateStatusDisplay()
    {
        try
        {
            _cfg = OrcaConfig.Load();
            var (status, owner) = PortInspector.GetStatusWithOwner(_cfg.Port);

            switch (status)
            {
                case PortStatus.Running:
                    SetTag(cardServerTag, cardServerTagBox, "运行中", "ok");
                    cardServerSub.Text = _cfg.ServerUrl;
                    infoStatus.Text = "running";
                    infoStatus.Foreground = ThemeApplier.GetBrush(this, "ColorTagOkFg");
                    btnStartServer.IsEnabled = false;
                    btnStartServer.Content = "服务器已运行";
                    btnStopServer.IsEnabled = true;
                    btnStopServer.Content = "关闭服务器";
                    btnRestartServer.IsEnabled = true;
                    break;

                case PortStatus.Occupied:
                    SetTag(cardServerTag, cardServerTagBox, "端口被占", "warn");
                    cardServerSub.Text = $"端口 {_cfg.Port} 被 {owner?.DisplayName ?? "未知程序"} 占用（非 DSH）";
                    infoStatus.Text = "端口被占用";
                    infoStatus.Foreground = ThemeApplier.GetBrush(this, "ColorTagWarnFg");
                    btnStartServer.IsEnabled = true;
                    btnStartServer.Content = "启动服务器";
                    btnStopServer.IsEnabled = false;
                    btnStopServer.Content = "服务器未运行";
                    btnRestartServer.IsEnabled = false;
                    break;

                default:
                    // 端口空闲：区分"已安装未运行"和"未安装"
                    if (!DshServer.IsDshInstalled(_cfg.DshDir))
                    {
                        SetTag(cardServerTag, cardServerTagBox, "未安装", "warn");
                        cardServerSub.Text = "未安装 DSH，请到「安装」页一键安装";
                        infoStatus.Text = "未安装";
                        infoStatus.Foreground = ThemeApplier.GetBrush(this, "ColorTagWarnFg");
                        btnStartServer.IsEnabled = false;
                        btnStartServer.Content = "请先安装 DSH";
                    }
                    else
                    {
                        SetTag(cardServerTag, cardServerTagBox, "未运行", "neutral");
                        cardServerSub.Text = _cfg.ServerUrl;
                        infoStatus.Text = "stopped";
                        infoStatus.Foreground = ThemeApplier.GetBrush(this, "ColorTagNeutralFg");
                        btnStartServer.IsEnabled = true;
                        btnStartServer.Content = "启动服务器";
                    }
                    btnStopServer.IsEnabled = false;
                    btnStopServer.Content = "服务器未运行";
                    btnRestartServer.IsEnabled = false;
                    break;
            }

            infoPort.Text = _cfg.Port.ToString();
            infoDir.Text = _cfg.DshDir;
            infoLog.Text = OrcaLog.ServerLogFile;

            // 托盘状态
            if (OrcaSignals.IsTrayRunning())
            {
                SetTag(cardTrayTag, cardTrayTagBox, "运行中", "ok");
                btnStartTray.Visibility = Visibility.Collapsed;
            }
            else
            {
                SetTag(cardTrayTag, cardTrayTagBox, "未运行", "neutral");
                btnStartTray.Visibility = Visibility.Visible;
            }

            // 更新状态：优先用最近一次手动检查结果，否则读插件写的状态文件
            if (_lastCheck is { Ok: true })
            {
                if (_lastCheck.HasUpdate)
                {
                    SetTag(cardUpdateTag, cardUpdateTagBox, "有新版本", "warn");
                    var text = $"官方 {_lastCheck.RemoteShort} / 本地 {_lastCheck.LocalShort}";
                    if (_lastDetails is { Length: > 0 })
                    {
                        text += "\n" + string.Join("\n", _lastDetails.Take(3).Select(d => "· " + d));
                    }
                    cardUpdateSub.Text = text;
                }
                else
                {
                    SetTag(cardUpdateTag, cardUpdateTagBox, "已是最新", "ok");
                    cardUpdateSub.Text = "版本 " + _lastCheck.LocalShort;
                }
                infoChecked.Text = DateTime.Now.ToString("yyyy-MM-dd HH:mm");
            }
            else
            {
                var state = UpdateState.Load();
                if (state != null)
                {
                    if (state.HasUpdate)
                    {
                        SetTag(cardUpdateTag, cardUpdateTagBox, "有新版本", "warn");
                        cardUpdateSub.Text = $"官方 {UpdateState.Short(state.RemoteCommit)} / 本地 {UpdateState.Short(state.LocalCommit)}";
                    }
                    else
                    {
                        SetTag(cardUpdateTag, cardUpdateTagBox, "已是最新", "ok");
                        cardUpdateSub.Text = "版本 " + UpdateState.Short(state.LocalCommit);
                    }
                    if (!string.IsNullOrWhiteSpace(state.CheckedAt) && state.CheckedAt.Length >= 16)
                    {
                        infoChecked.Text = state.CheckedAt.Replace('T', ' ')[..16];
                    }
                }
                else
                {
                    SetTag(cardUpdateTag, cardUpdateTagBox, "无结果", "neutral");
                    cardUpdateSub.Text = "点「检查更新」查看";
                    infoChecked.Text = "—";
                }
            }

            UpdateInstallCard();
        }
        catch
        {
            // 刷新失败不弹窗（与旧版一致）
        }
    }

    /// <summary>设置状态胶囊的文字与配色（ok / warn / neutral）。</summary>
    private void SetTag(System.Windows.Controls.TextBlock text, System.Windows.Controls.Border box, string label, string kind)
    {
        text.Text = label;
        switch (kind)
        {
            case "ok":
                text.Foreground = ThemeApplier.GetBrush(this, "ColorTagOkFg");
                box.Background = ThemeApplier.GetBrush(this, "ColorTagOkBg");
                break;
            case "warn":
                text.Foreground = ThemeApplier.GetBrush(this, "ColorTagWarnFg");
                box.Background = ThemeApplier.GetBrush(this, "ColorTagWarnBg");
                break;
            default:
                text.Foreground = ThemeApplier.GetBrush(this, "ColorTagNeutralFg");
                box.Background = ThemeApplier.GetBrush(this, "ColorTagNeutralBg");
                break;
        }
    }

    private void UpdateInstallCard()
    {
        try
        {
            if (DshServer.IsDshInstalled(_cfg.DshDir))
            {
                installCardIcon.Text = "✓";
                installCardIcon.Foreground = ThemeApplier.GetBrush(this, "ColorTagOkFg");
                installCardSub.Text = _cfg.DshDir;
                SetTag(installCardTag, installCardTagBox, "已安装", "ok");
                btnInstallFull.IsEnabled = false;
                btnInstallFull.Content = "已安装 ✓";
                btnInstallCancel.IsEnabled = _phase is InstallPhase.Cloning or InstallPhase.Installing or InstallPhase.Building;
            }
            else
            {
                installCardIcon.Text = "○";
                installCardIcon.Foreground = ThemeApplier.GetBrush(this, "ColorTagWarnFg");
                installCardSub.Text = "尚未安装，点下方按钮一键安装";
                SetTag(installCardTag, installCardTagBox, "未安装", "warn");
                btnInstallFull.IsEnabled = _phase is InstallPhase.Idle or InstallPhase.Failed or InstallPhase.Done;
                btnInstallFull.Content = "一键安装完整版";
                btnInstallCancel.IsEnabled = _phase is InstallPhase.Cloning or InstallPhase.Installing or InstallPhase.Building;
            }
        }
        catch
        {
            // 忽略
        }
    }

    private void UpdateLogDisplay()
    {
        try
        {
            txtLog.Text = string.Join("\n", OrcaLog.ReadServerLogTail(250));
            txtLog.ScrollToEnd();
        }
        catch
        {
            // 忽略
        }
    }

    // ============================================================
    //  定时刷新
    // ============================================================
    private async Task OnRefreshTickAsync()
    {
        if (_refreshBusy) return;
        _refreshBusy = true;
        try
        {
            UpdateStatusDisplay();

            // 托盘信号
            if (OrcaSignals.Consume(_showEvent))
            {
                Show();
                WindowState = WindowState.Normal;
                Activate();
                lblStatus.Text = "控制台已恢复";
            }
            if (OrcaSignals.Consume(_closeEvent))
            {
                Close();
                return;
            }

            if (pageLogs.Visibility == Visibility.Visible) UpdateLogDisplay();

            bool running = await Task.Run(() => DshServer.IsRunning(_cfg));

            if (_pendingStart && running)
            {
                _pendingStart = false;
                lblStatus.Text = "服务器已启动";
            }
            if (_pendingOpen && running)
            {
                _pendingOpen = false;
                lblStatus.Text = "正在打开 DSH 界面…";
                await Task.Run(() => DshServer.OpenUi(_cfg));
                lblStatus.Text = "DSH 界面已打开";
            }
            // 官方 Web 版就绪后自动打开界面
            if (_pendingWebOpen && running)
            {
                _pendingWebOpen = false;
                btnInstallWeb.IsEnabled = true;
                ProcessRunner.OpenUrl(_cfg.ServerUrl);
                installStatus.Text = "✅ 官方 Web 版已启动，已打开界面";
            }
            // 完整版安装完成后自动启动
            if (_pendingStartAfterInstall && !running)
            {
                var dir = _installDshDir;
                var port = _cfg.Port;
                var r = await Task.Run(() => _install.StartFromDir(dir, port));
                if (r.Ok)
                {
                    _pendingStartAfterInstall = false;
                    lblStatus.Text = "正在启动 DSH…";
                    _pendingOpen = true;
                }
            }
        }
        catch
        {
            // 定时刷新出错不打扰用户
        }
        finally
        {
            _refreshBusy = false;
        }
    }

    // ============================================================
    //  概览 / 服务器页动作
    // ============================================================
    private async Task OpenDshUiAsync()
    {
        try
        {
            var (status, _) = PortInspector.GetStatusWithOwner(_cfg.Port);
            if (status == PortStatus.Free && !DshServer.IsDshInstalled(_cfg.DshDir))
            {
                lblStatus.Text = "⚠️ 未安装 DSH，请到「安装」页一键安装，或直接启动官方 Web 版";
                ShowPage("install");
                return;
            }
            if (status == PortStatus.Occupied)
            {
                lblStatus.Text = $"⚠️ 端口 {_cfg.Port} 被其他程序占用，无法启动 DSH";
                return;
            }

            if (status == PortStatus.Running)
            {
                lblStatus.Text = "正在打开 DSH 界面…";
                await Task.Run(() => DshServer.OpenUi(_cfg));
                lblStatus.Text = "DSH 界面已打开";
                return;
            }

            lblStatus.Text = "正在启动 DSH…（如刚更新会先自动构建，请稍候）";
            var r = await Task.Run(() => DshServer.Start(_cfg));
            if (r.Ok)
            {
                _pendingOpen = true;
                lblStatus.Text = "正在启动 DSH…（就绪后自动打开界面）";
                UpdateStatusDisplay();
            }
            else
            {
                lblStatus.Text = "启动失败：" + r.Error;
            }
        }
        catch (Exception ex)
        {
            lblStatus.Text = "操作出错：" + ex.Message;
        }
    }

    private async Task CheckUpdateAsync()
    {
        try
        {
            btnCheckOverview.IsEnabled = false;
            lblStatus.Text = "正在检查更新…（网络查询，稍等几秒）";

            var cfg = _cfg;
            var result = await Task.Run(() => UpdateChecker.CheckAndSave(cfg));
            _lastCheck = result;
            _lastDetails = null;
            if (result.Ok && result.HasUpdate)
            {
                _lastDetails = await Task.Run(() => UpdateChecker.GetUpdateDetails(cfg, 5));
            }

            UpdateStatusDisplay();
            if (!result.Ok)
            {
                lblStatus.Text = "检查失败（网络或本地版本读不到）";
            }
            else if (result.HasUpdate)
            {
                lblStatus.Text = _lastDetails is { Length: > 0 }
                    ? "发现新版本！最近更新：" + _lastDetails[0]
                    : "发现新版本！详情见概览页";
            }
            else
            {
                lblStatus.Text = "已是最新版本";
            }
        }
        catch (Exception ex)
        {
            lblStatus.Text = "操作出错：" + ex.Message;
        }
        finally
        {
            btnCheckOverview.IsEnabled = true;
        }
    }

    private async Task UpdateDshAsync()
    {
        try
        {
            btnUpdateDsh.IsEnabled = false;
            lblStatus.Text = "正在获取更新预览…";

            var cfg = _cfg;
            var preview = await Task.Run(() => DshServer.PreviewUpdate(cfg));

            // 已是最新：直接提示，不必执行 pull
            if (preview.Ok && preview.IncomingCount == 0)
            {
                lblStatus.Text = "当前已是最新版本，无需更新";
                OrcaDialog.Show(this, "无需更新", "当前 DSH 已是最新版本，无需更新。", OrcaDialogType.Info, OrcaDialogButtons.Ok);
                return;
            }

            // 组装确认框正文：把即将拉取的提交列给用户看（预览更新内容）
            var body = $"即将更新 DSH 本体（在 {cfg.DshDir} 执行 git pull）。\n更新后需要重启 DSH 才能生效。";
            if (preview.Ok && preview.IncomingCount > 0)
            {
                body += $"\n\n本次将拉取 {preview.IncomingCount} 个新提交：";
                var commits = preview.Commits ?? Array.Empty<string>();
                foreach (var c in commits) body += "\n· " + c;
                if (preview.IncomingCount > commits.Length)
                {
                    body += $"\n…（共 {preview.IncomingCount} 个，完整内容见更新后日志）";
                }
            }
            else if (!preview.Ok)
            {
                body += $"\n\n（无法获取更新预览：{preview.Error}。点「是」仍将继续更新。）";
            }
            body += "\n\n继续吗？";

            var confirm = OrcaDialog.Show(this, "更新 DSH", body, OrcaDialogType.Question, OrcaDialogButtons.YesNo);
            if (!confirm)
            {
                lblStatus.Text = "已取消更新";
                return;
            }

            lblStatus.Text = "正在更新 DSH…（git pull + 必要时重新构建，可能需要几分钟）";

            var result = await Task.Run(() => DshServer.UpdateDsh(cfg));
            if (result.Ok)
            {
                _lastCheck = await Task.Run(() => UpdateChecker.CheckAndSave(cfg));
                _lastDetails = null;
                UpdateStatusDisplay();
                lblStatus.Text = "更新完成！请重启 DSH 生效（本窗口可点「重启服务器」）";
                OrcaDialog.Show(this, "更新完成",
                    FormatUpdateResult(result.Output, "DSH 更新成功！", "请重启 DSH 生效。"),
                    OrcaDialogType.Info, OrcaDialogButtons.Ok);
            }
            else
            {
                lblStatus.Text = "更新失败：" + (result.Error ?? "git pull 出错") + "（当前版本不受影响）";
                OrcaDialog.Show(this, "更新失败",
                    FormatUpdateResult(result.Output, "更新失败，当前版本不受影响。", null),
                    OrcaDialogType.Warning, OrcaDialogButtons.Ok);
            }
        }
        catch (Exception ex)
        {
            lblStatus.Text = "操作出错：" + ex.Message;
        }
        finally
        {
            btnUpdateDsh.IsEnabled = true;
        }
    }

    /// <summary>git 输出可能几十上百行，截断后再进弹窗（与旧版 Format-UpdateResult 一致）。</summary>
    private static string FormatUpdateResult(string? output, string prefix, string? suffix)
    {
        const int maxShow = 60;
        var text = prefix;
        var lines = (output ?? string.Empty).Replace("\r\n", "\n").Split('\n');
        if (lines.Length > maxShow)
        {
            text += $"\n…（输出共 {lines.Length} 行，仅显示最后 {maxShow} 行）\n";
            text += string.Join("\n", lines.Skip(lines.Length - maxShow));
        }
        else if (!string.IsNullOrWhiteSpace(output))
        {
            text += "\n" + output;
        }
        if (!string.IsNullOrWhiteSpace(suffix)) text += "\n" + suffix;
        return text;
    }

    private async Task StartServerAsync()
    {
        try
        {
            var (status, owner) = PortInspector.GetStatusWithOwner(_cfg.Port);
            if (status == PortStatus.Free && !DshServer.IsDshInstalled(_cfg.DshDir))
            {
                lblStatus.Text = "⚠️ 未安装 DSH，请到「安装」页一键安装，或直接启动官方 Web 版";
                ShowPage("install");
                return;
            }
            if (status == PortStatus.Occupied)
            {
                lblStatus.Text = $"⚠️ 端口 {_cfg.Port} 被 {owner?.DisplayName ?? "未知程序"} 占用，无法启动";
                return;
            }
            if (status == PortStatus.Running)
            {
                lblStatus.Text = "服务器已经在运行中";
                return;
            }

            lblStatus.Text = "正在启动服务器…（如 DSH 刚更新会先自动构建，请稍候）";
            var r = await Task.Run(() => DshServer.Start(_cfg));
            if (r.Ok)
            {
                _pendingStart = true;
                lblStatus.Text = "正在启动服务器…";
                UpdateStatusDisplay();
            }
            else
            {
                lblStatus.Text = "启动失败：" + r.Error;
            }
        }
        catch (Exception ex)
        {
            lblStatus.Text = "操作出错：" + ex.Message;
        }
    }

    private async Task StopServerAsync()
    {
        try
        {
            lblStatus.Text = "正在关闭服务器…";
            var r = await Task.Run(() => DshServer.Stop(_cfg));
            UpdateStatusDisplay();
            lblStatus.Text = r.Ok ? "服务器已关闭" : "⚠️ " + r.Error;
        }
        catch (Exception ex)
        {
            lblStatus.Text = "操作出错：" + ex.Message;
        }
    }

    private async Task RestartServerAsync()
    {
        try
        {
            var (status, owner) = PortInspector.GetStatusWithOwner(_cfg.Port);
            if (status == PortStatus.Occupied)
            {
                lblStatus.Text = $"⚠️ 端口 {_cfg.Port} 被 {owner?.DisplayName ?? "未知程序"} 占用，不能重启";
                return;
            }
            if (status != PortStatus.Running)
            {
                lblStatus.Text = "服务器未运行，直接启动…（如 DSH 刚更新会先自动构建，请稍候）";
                var r0 = await Task.Run(() => DshServer.Start(_cfg));
                if (r0.Ok)
                {
                    _pendingStart = true;
                    UpdateStatusDisplay();
                    lblStatus.Text = "服务器已启动";
                }
                else
                {
                    lblStatus.Text = "启动失败：" + r0.Error;
                }
                return;
            }

            lblStatus.Text = "正在重启服务器…";
            var stop = await Task.Run(() => DshServer.Stop(_cfg));
            if (!stop.Ok)
            {
                UpdateStatusDisplay();
                lblStatus.Text = "⚠️ " + stop.Error;
                return;
            }
            await Task.Delay(2000);

            lblStatus.Text = "重启中：正在重新构建/启动服务器…";
            var start = await Task.Run(() => DshServer.Start(_cfg));
            if (start.Ok)
            {
                _pendingStart = true;
                lblStatus.Text = "重启中：服务器正在启动…";
                UpdateStatusDisplay();
            }
            else
            {
                lblStatus.Text = "重启失败：" + start.Error;
            }
        }
        catch (Exception ex)
        {
            lblStatus.Text = "操作出错：" + ex.Message;
        }
    }

    // ============================================================
    //  安装页动作
    // ============================================================
    private async Task StartWebVersionAsync()
    {
        try
        {
            var (status, owner) = PortInspector.GetStatusWithOwner(_cfg.Port);
            if (status == PortStatus.Running)
            {
                ProcessRunner.OpenUrl(_cfg.ServerUrl);
                installStatus.Text = "DSH 已在运行，已为你打开界面";
                return;
            }
            if (status == PortStatus.Occupied)
            {
                installStatus.Text = $"⚠️ 端口 {_cfg.Port} 被 {owner?.DisplayName ?? "其他程序"} 占用，请先处理";
                return;
            }

            btnInstallWeb.IsEnabled = false;
            txtInstallLog.Visibility = Visibility.Visible;
            installStatus.Text = "正在启动官方 Web 版（首次运行会自动下载官方包，请稍候）…";

            var port = _cfg.Port;
            var r = await Task.Run(() => _install.StartWebNpx(port));
            if (!r.Ok)
            {
                installStatus.Text = "❌ " + r.Error;
                btnInstallWeb.IsEnabled = true;
                return;
            }
            _pendingWebOpen = true;
            _installTimer.Start();
        }
        catch (Exception ex)
        {
            installStatus.Text = "操作出错：" + ex.Message;
            btnInstallWeb.IsEnabled = true;
        }
    }

    private async Task StartFullInstallAsync()
    {
        try
        {
            if (_phase is InstallPhase.Cloning or InstallPhase.Installing or InstallPhase.Building or InstallPhase.Finishing)
            {
                OrcaDialog.Show(this, "Orca DSH Launcher", "安装正在进行中，请稍候。", OrcaDialogType.Info, OrcaDialogButtons.Ok);
                return;
            }

            // 1) 环境检测
            installStatus.Text = "① 正在检查电脑环境…";
            var env = await Task.Run(InstallService.CheckEnvironment);
            if (!env.Ok)
            {
                OrcaDialog.Show(this, "缺少环境",
                    "还缺少以下软件：\n" + string.Join("\n", env.Missing) + "\n\n装好后再来点「一键安装完整版」。",
                    OrcaDialogType.Warning, OrcaDialogButtons.Ok);
                installStatus.Text = "缺少环境，请先安装所需软件";
                return;
            }

            // 2) 网络检测
            installStatus.Text = "② 正在检测网络（能否访问 GitHub）…";
            var net = await Task.Run(InstallService.CheckGithubNetwork);
            if (!net.GithubOk)
            {
                var go = OrcaDialog.Show(this, "网络不可用",
                    "当前网络无法访问 GitHub，下载可能会失败。\n检查结果：" + net.Detail +
                    "\n\n建议：检查代理/VPN 设置，或更换网络后再试。\n如果确认网络没问题，可以点「是」继续尝试。",
                    OrcaDialogType.Warning, OrcaDialogButtons.YesNo);
                if (!go)
                {
                    installStatus.Text = "已取消安装";
                    return;
                }
            }

            // 3) 选择安装位置
            var dlg = new Microsoft.Win32.OpenFolderDialog
            {
                Title = "选择 DSH 要安装到的文件夹（会自动创建 deepseek-harness 子文件夹）",
                Multiselect = false,
            };
            if (dlg.ShowDialog(this) != true) return;
            _installDshDir = Path.Combine(dlg.FolderName, "deepseek-harness");
            installStatus.Text = "安装位置：" + _installDshDir;

            // 4) 开始安装
            txtInstallLog.Visibility = Visibility.Visible;
            _installLog.Clear();
            btnInstallFull.IsEnabled = false;
            _phase = InstallPhase.Idle;
            StartCloneStep();
        }
        catch (Exception ex)
        {
            installStatus.Text = "操作出错：" + ex.Message;
            btnInstallFull.IsEnabled = true;
        }
    }

    private void StartCloneStep()
    {
        // 记录"安装前目录是否存在"——不存在 = 本次创建的，取消时可安全删除
        _dirExistedBefore = Directory.Exists(_installDshDir);
        btnInstallCancel.IsEnabled = true;

        var clone = _install.StartClone(_installDshDir);
        if (!clone.Ok)
        {
            installStatus.Text = "❌ " + clone.Error;
            _phase = InstallPhase.Failed;
            btnInstallFull.IsEnabled = true;
            return;
        }
        if (clone.Proc != null)
        {
            _phase = InstallPhase.Cloning;
            installStatus.Text = "正在下载 DSH 源码（git clone，取决于网速）…";
            _installProc = clone.Proc;
            _installTimer.Start();
            return;
        }
        StartDepsStep();
    }

    private void StartDepsStep()
    {
        _phase = InstallPhase.Installing;
        installStatus.Text = "正在安装依赖（pnpm install，通常 10~30 分钟，请耐心等待）…";
        var deps = _install.StartDeps(_installDshDir);
        if (!deps.Ok)
        {
            installStatus.Text = "❌ " + deps.Error;
            _phase = InstallPhase.Failed;
            btnInstallFull.IsEnabled = true;
            return;
        }
        _installProc = deps.Proc;
        _installTimer.Start();
    }

    private void StartBuildStep()
    {
        _phase = InstallPhase.Building;
        installStatus.Text = "正在构建 DSH（pnpm run build，需要几分钟）…";
        var build = _install.StartBuild(_installDshDir);
        if (!build.Ok)
        {
            installStatus.Text = "❌ " + build.Error;
            _phase = InstallPhase.Failed;
            btnInstallFull.IsEnabled = true;
            return;
        }
        _installProc = build.Proc;
        _installTimer.Start();
    }

    private void FinishInstall()
    {
        _phase = InstallPhase.Finishing;
        installStatus.Text = "正在安装 Orca 插件…";

        var src = PluginPayload.Resolve(AppInfo.PackageRootDir);
        if (src != null)
        {
            _install.InstallPlugin(src, _installDshDir);
            _install.CreateDesktopShortcut();
        }
        else
        {
            _installLog.Write("[插件] 找不到插件文件包，已跳过插件安装（DSH 本体已装好）");
        }

        // 配置指向新装的 DSH
        _cfg.DshDir = _installDshDir;
        _cfg.Save();

        _phase = InstallPhase.Done;
        installStatus.Text = "✅ 安装完成！正在启动 DSH…";
        btnInstallFull.IsEnabled = true;
        btnInstallCancel.IsEnabled = false;
        _installTimer.Stop();
        UpdateStatusDisplay();
        _pendingStartAfterInstall = true;
    }

    /// <summary>安装进度定时器（800ms）：刷日志 + 按进程退出码推进状态机。</summary>
    private void OnInstallTick(object? sender, EventArgs e)
    {
        // 刷新日志
        var lines = _installLog.ReadTail(60);
        if (lines.Length > 0)
        {
            txtInstallLog.Text = string.Join("\n", lines);
            txtInstallLog.ScrollToEnd();
        }

        // 进程还在跑 → 等下一轮
        if (_installProc != null && !_installProc.HasExited) return;
        int exitCode = -1;
        try
        {
            if (_installProc != null) exitCode = _installProc.ExitCode;
        }
        catch
        {
            exitCode = -1;
        }

        switch (_phase)
        {
            case InstallPhase.Cloning:
                if (exitCode == 0)
                {
                    installStatus.Text = "✅ 源码下载完成，开始装依赖…";
                    StartDepsStep();
                }
                else
                {
                    FailInstall($"❌ 下载失败（退出码 {exitCode}），请查看日志并检查网络");
                }
                break;

            case InstallPhase.Installing:
                if (exitCode == 0)
                {
                    installStatus.Text = "✅ 依赖安装完成，开始构建…";
                    StartBuildStep();
                }
                else
                {
                    FailInstall($"❌ 依赖安装失败（退出码 {exitCode}），请查看日志（常见原因：网络中断、磁盘空间不足）");
                }
                break;

            case InstallPhase.Building:
                if (exitCode == 0)
                {
                    FinishInstall();
                }
                else
                {
                    FailInstall($"❌ 构建失败（退出码 {exitCode}），请查看日志");
                }
                break;

            default:
                // 官方 Web 版只需要刷日志，等 pendingWebOpen 生效后停表
                if (!_pendingWebOpen) _installTimer.Stop();
                break;
        }
    }

    private void FailInstall(string message)
    {
        _phase = InstallPhase.Failed;
        installStatus.Text = message;
        installStatus.Foreground = ThemeApplier.GetBrush(this, "ColorTagWarnFg");
        btnInstallFull.IsEnabled = true;
        btnInstallCancel.IsEnabled = false;
        _installTimer.Stop();
    }

    /// <summary>取消安装并清理（只删本次安装创建的目录，安装前就存在的绝不删）。</summary>
    private void CancelInstall()
    {
        if (_installProc != null)
        {
            ProcessRunner.TryKillTree(_installProc);
            _installProc = null;
        }
        _installTimer.Stop();
        _phase = InstallPhase.Idle;
        _pendingWebOpen = false;

        var canDelete = !_dirExistedBefore && !string.IsNullOrWhiteSpace(_installDshDir) && Directory.Exists(_installDshDir);
        var msg = "要取消安装吗？";
        if (canDelete)
        {
            msg += "\n\n本次安装创建了文件夹：\n" + _installDshDir + "\n\n是否删除它（包括已下载的文件）？";
        }
        else if (_dirExistedBefore)
        {
            msg += "\n\n（这个文件夹在安装前就存在，为了安全不会删除它）";
        }

        if (!OrcaDialog.Show(this, "取消安装", msg, OrcaDialogType.Question, OrcaDialogButtons.YesNo)) return;

        if (canDelete)
        {
            try
            {
                Directory.Delete(_installDshDir, recursive: true);
            }
            catch
            {
                // 有文件被占用时删不掉，交给用户手动处理
            }
        }

        installStatus.Text = "已取消安装并清理";
        installStatus.Foreground = ThemeApplier.GetBrush(this, "ColorTagWarnFg");
        btnInstallFull.IsEnabled = true;
        btnInstallCancel.IsEnabled = false;
        txtInstallLog.Text = string.Empty;
        UpdateInstallCard();
        lblStatus.Text = "已取消安装";
    }

    // ============================================================
    //  设置保存
    // ============================================================
    private void SaveSettings()
    {
        try
        {
            var portText = txtPort.Text.Trim();
            if (!int.TryParse(portText, out var newPort)) throw new InvalidOperationException("端口必须是数字");
            if (newPort is < 1 or > 65535) throw new InvalidOperationException("端口需在 1-65535 之间");

            var newDir = txtDshDir.Text.Trim();
            if (string.IsNullOrWhiteSpace(newDir)) throw new InvalidOperationException("DSH 目录不能为空");

            var newTheme = rdoLight.IsChecked == true ? "light" : "dark";
            var newAccent = "blue";
            if (rdoAccentGreen.IsChecked == true) newAccent = "green";
            else if (rdoAccentPurple.IsChecked == true) newAccent = "purple";
            else if (rdoAccentAmber.IsChecked == true) newAccent = "amber";
            else if (rdoAccentRose.IsChecked == true) newAccent = "rose";
            else if (rdoAccentSlate.IsChecked == true) newAccent = "slate";

            // 1) 写共享配置
            _cfg.Port = newPort;
            _cfg.DshDir = newDir;
            _cfg.TrayAutoStart = chkTrayAuto.IsChecked == true;
            _cfg.Theme = newTheme;
            _cfg.Accent = newAccent;
            if (!_cfg.Save()) throw new InvalidOperationException("写入配置文件失败");

            // 2) 开机自启托盘
            ShortcutManager.SetTrayAutoStart(chkStartup.IsChecked == true);

            // 3) 开机自启 DSH 服务器
            ShortcutManager.SetServerAutoStart(chkDshAutoStart.IsChecked == true);

            // 4) 主题 + 强调色立即生效
            ApplyThemeFromConfig();
            UpdateStatusDisplay();

            lblStatus.Text = "设置已保存";
        }
        catch (Exception ex)
        {
            lblStatus.Text = "保存失败：" + ex.Message;
        }
    }
}
