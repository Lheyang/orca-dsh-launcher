using System.Windows.Forms;
using System.Windows.Threading;
using Orca.Core;
using Orca.Core.Ui;

namespace Orca.App;

/// <summary>
/// 系统托盘（替代 dsh-tray.ps1）。
/// 右下角虎鲸图标：左键打开 DSH 界面，右键菜单启停服务器 / 打开控制台 / 检查更新。
/// 与控制台通过命名信号联动（控制台「退出程序」会一起关掉托盘）。
/// </summary>
internal sealed class TrayApp : IDisposable
{
    private readonly NotifyIcon _notify = new();
    private readonly ContextMenuStrip _menu = new();
    private readonly ToolStripMenuItem _miStatus = new();
    private readonly ToolStripMenuItem _miVer = new();
    private readonly ToolStripMenuItem _miOpen = new("打开 DSH 界面");
    private readonly ToolStripMenuItem _miConsole = new("打开管理界面");
    private readonly ToolStripMenuItem _miCheck = new("检查更新");
    private readonly ToolStripMenuItem _miLog = new("日志位置…");
    private readonly ToolStripMenuItem _miStart = new("启动服务器");
    private readonly ToolStripMenuItem _miStop = new("关闭服务器");
    private readonly ToolStripMenuItem _miQuit = new("退出程序");
    private readonly DispatcherTimer _signalTimer = new();
    private System.Threading.EventWaitHandle? _closeEvent;
    private bool _busy;

    /// <summary>用户选择"退出程序"时触发。</summary>
    public event EventHandler? ExitRequested;

    /// <summary>启动托盘（建图标、建菜单、开始联动轮询）。</summary>
    public void Start()
    {
        _notify.Icon = IconLoader.LoadTrayIcon();
        _notify.Text = "Orca · DSH Launcher";
        _notify.Visible = true;

        _miStatus.Enabled = false;
        _miVer.Enabled = false;
        _miVer.Text = "Orca " + AppInfo.VersionDisplay;

        _miOpen.Click += (_, _) => RunBackground(OpenDshUi);
        _miConsole.Click += (_, _) => OpenConsole();
        _miCheck.Click += (_, _) => RunBackground(ManualCheck);
        _miLog.Click += (_, _) => ShowBalloon("Orca 日志", OrcaLog.ServerLogFile);
        _miStart.Click += (_, _) => RunBackground(StartServer);
        _miStop.Click += (_, _) => RunBackground(StopServer);
        _miQuit.Click += (_, _) => QuitAll();

        _menu.Items.Add(_miStatus);
        _menu.Items.Add(_miVer);
        _menu.Items.Add(new ToolStripSeparator());
        _menu.Items.Add(_miOpen);
        _menu.Items.Add(_miConsole);
        _menu.Items.Add(_miCheck);
        _menu.Items.Add(_miLog);
        _menu.Items.Add(_miStart);
        _menu.Items.Add(_miStop);
        _menu.Items.Add(new ToolStripSeparator());
        _menu.Items.Add(_miQuit);

        _notify.ContextMenuStrip = _menu;
        _menu.Opening += (_, _) => RefreshMenu();
        _notify.MouseClick += (_, e) =>
        {
            if (e.Button == MouseButtons.Left) RunBackground(OpenDshUi);
        };

        RefreshMenu();

        // 统计 + 启动后台更新检查（有更新且没通知过才弹气泡）
        OrcaStats.AddLaunch();
        Task.Run(StartupUpdateCheck);

        // 与控制台联动：控制台「退出程序」→ 通知托盘一起退出
        _closeEvent = OrcaSignals.CreateEvent(OrcaSignals.TrayCloseEventName);
        _signalTimer.Interval = TimeSpan.FromSeconds(1);
        _signalTimer.Tick += (_, _) =>
        {
            if (OrcaSignals.Consume(_closeEvent))
            {
                _notify.Visible = false;
                ExitRequested?.Invoke(this, EventArgs.Empty);
            }
        };
        _signalTimer.Start();
    }

    /// <summary>刷新菜单文字与可用状态（右键弹出前调用）。</summary>
    private void RefreshMenu()
    {
        var cfg = OrcaConfig.Load();
        var status = PortInspector.GetStatus(cfg.Port);
        switch (status)
        {
            case PortStatus.Running:
                _miStatus.Text = "● 服务器运行中";
                _miStart.Enabled = false;
                _miStop.Enabled = true;
                _miOpen.Enabled = true;
                _notify.Text = "Orca · DSH Launcher — 运行中";
                break;
            case PortStatus.Occupied:
                _miStatus.Text = "⚠️ 端口被其他程序占用";
                _miStart.Enabled = false;
                _miStop.Enabled = false;
                _miOpen.Enabled = false;
                _notify.Text = "Orca · DSH Launcher — 端口被占用";
                break;
            default:
                _miStatus.Text = "○ 服务器未运行";
                _miStart.Enabled = true;
                _miStop.Enabled = false;
                _miOpen.Enabled = true;
                _notify.Text = "Orca · DSH Launcher — 未运行";
                break;
        }
    }

    /// <summary>弹一个 Windows 气泡通知。</summary>
    private void ShowBalloon(string title, string text)
    {
        try
        {
            Dispatch(() => _notify.ShowBalloonTip(8000, title, text, ToolTipIcon.Info));
        }
        catch
        {
            // 通知弹不出来不影响功能
        }
    }

    /// <summary>把耗时操作丢到后台线程，避免卡住托盘菜单。</summary>
    private void RunBackground(Action action)
    {
        if (_busy) return;
        _busy = true;
        Task.Run(() =>
        {
            try
            {
                action();
            }
            catch
            {
                // 后台失败不弹异常框
            }
            finally
            {
                _busy = false;
                Dispatch(RefreshMenu);
            }
        });
    }

    private static void Dispatch(Action action)
    {
        var app = System.Windows.Application.Current;
        if (app == null)
        {
            action();
            return;
        }
        if (app.Dispatcher.CheckAccess()) action();
        else app.Dispatcher.Invoke(action);
    }

    // ============================================================
    //  菜单动作
    // ============================================================

    private void OpenDshUi()
    {
        var cfg = OrcaConfig.Load();
        var r = DshServer.OpenUi(cfg, 180);
        if (!r.Ok) ShowBalloon("Orca", r.Error ?? "打开界面失败");
    }

    private void OpenConsole()
    {
        // 控制台已在运行 → 让它显示到前台；否则启动一个新的
        if (OrcaSignals.Signal(OrcaSignals.ConsoleShowEventName)) return;
        if (!ProcessRunner.StartAppMode("--console"))
        {
            ShowBalloon("Orca", "打开控制台失败（程序文件缺失？）");
        }
    }

    private void StartServer()
    {
        var cfg = OrcaConfig.Load();
        var r = DshServer.Start(cfg);
        if (!r.Ok) ShowBalloon("Orca", r.Error ?? "启动失败");
    }

    private void StopServer()
    {
        var cfg = OrcaConfig.Load();
        var r = DshServer.Stop(cfg);
        if (!r.Ok) ShowBalloon("Orca", r.Error ?? "关闭失败");
    }

    private void ManualCheck()
    {
        var cfg = OrcaConfig.Load();
        var result = UpdateChecker.CheckAndSave(cfg);
        if (!result.Ok)
        {
            ShowBalloon("Orca：DSH 更新检查", "检查失败（网络或本地版本读不到），请稍后再试。");
            return;
        }
        if (!result.HasUpdate)
        {
            ShowBalloon("Orca：DSH 更新检查", $"当前已是最新版本（{result.LocalShort}）✅");
        }
        else
        {
            ShowBalloon("Orca：DSH 有新版本啦 🐋", $"官方已更新到 {result.RemoteShort}，你当前是 {result.LocalShort}。");
        }
    }

    /// <summary>启动时检查：有更新且这个版本没通知过 → 弹一次气泡（不刷屏）。</summary>
    private void StartupUpdateCheck()
    {
        try
        {
            var cfg = OrcaConfig.Load();
            var result = UpdateChecker.CheckAndSave(cfg);
            if (!result.Ok || !result.HasUpdate) return;

            var remote = result.RemoteCommit ?? string.Empty;
            var notified = Utf8Files.ReadAllTextOrNull(OrcaPaths.TrayLastNotifiedFile)?.Trim();
            if (string.Equals(notified, remote, StringComparison.OrdinalIgnoreCase)) return;

            ShowBalloon("Orca：DSH 有新版本啦 🐋",
                $"官方已更新到 {result.RemoteShort}，你当前是 {result.LocalShort}。点开 DSH 界面可以继续使用，更新请咨询懂技术的人。");
            Utf8Files.WriteAllText(OrcaPaths.TrayLastNotifiedFile, remote);
        }
        catch
        {
            // 启动检查失败保持安静
        }
    }

    /// <summary>退出程序：顺带关掉控制台窗口。</summary>
    private void QuitAll()
    {
        OrcaSignals.Signal(OrcaSignals.ConsoleCloseEventName);
        _notify.Visible = false;
        ExitRequested?.Invoke(this, EventArgs.Empty);
    }

    /// <inheritdoc/>
    public void Dispose()
    {
        try
        {
            _signalTimer.Stop();
            _notify.Visible = false;
            _notify.Dispose();
            _menu.Dispose();
            _closeEvent?.Dispose();
        }
        catch
        {
            // 释放失败无所谓
        }
    }
}
