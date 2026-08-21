using System.Windows;
using Orca.Core;
using Orca.Core.Ui;

namespace Orca.App;

/// <summary>程序运行模式。</summary>
public enum AppMode
{
    /// <summary>图形控制台（默认）。</summary>
    Console,

    /// <summary>系统托盘常驻。</summary>
    Tray,

    /// <summary>一键安装向导。</summary>
    Setup,

    /// <summary>静默启动 DSH 服务器后退出（开机自启入口）。</summary>
    StartServer,

    /// <summary>诊断用：弹一次自定义对话框看渲染是否正常，然后退出。</summary>
    DialogTest,
}

/// <summary>
/// 程序入口：按命令行参数分发到不同模式。
/// 一个 exe 干完原来 4 个 .ps1 + 3 个 .vbs 的活。
/// </summary>
public partial class App : Application
{
    private System.Threading.Mutex? _singleInstanceMutex;
    private TrayApp? _tray;

    /// <summary>当前模式。</summary>
    public AppMode Mode { get; private set; } = AppMode.Console;

    /// <inheritdoc/>
    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        // 由我们自己决定何时退出（托盘模式没有窗口也要活着）
        ShutdownMode = ShutdownMode.OnExplicitShutdown;
        Mode = ResolveMode(e.Args);

        // 任务栏归组标识 + 图标（让任务栏显示虎鲸而不是宿主图标）
        Win32Helper.SetupAppUserModelId();

        switch (Mode)
        {
            case AppMode.Tray:
                StartTrayMode();
                break;
            case AppMode.Setup:
                StartSetupMode();
                break;
            case AppMode.StartServer:
                StartServerMode();
                break;
            case AppMode.DialogTest:
                DialogTestMode();
                break;
            default:
                StartConsoleMode();
                break;
        }
    }

    /// <summary>
    /// 解析模式：优先看命令行参数，其次看自己的文件名
    /// （orca-setup.exe 双击直接进安装向导，不需要带参数）。
    /// </summary>
    private static AppMode ResolveMode(string[] args)
    {
        foreach (var raw in args)
        {
            var a = raw.TrimStart('-', '/').ToLowerInvariant();
            switch (a)
            {
                case "tray":
                    return AppMode.Tray;
                case "console":
                case "ui":
                    return AppMode.Console;
                case "setup":
                case "install":
                    return AppMode.Setup;
                case "start-server":
                case "startserver":
                case "server":
                    return AppMode.StartServer;
                case "dialog-test":
                    return AppMode.DialogTest;
            }
        }

        try
        {
            var exeName = Path.GetFileNameWithoutExtension(AppInfo.ExecutablePath) ?? string.Empty;
            if (exeName.Contains("setup", StringComparison.OrdinalIgnoreCase)) return AppMode.Setup;
            if (exeName.Contains("tray", StringComparison.OrdinalIgnoreCase)) return AppMode.Tray;
        }
        catch
        {
            // 取不到文件名就用默认模式
        }
        return AppMode.Console;
    }

    // ============================================================
    //  托盘模式
    // ============================================================
    private void StartTrayMode()
    {
        // 单实例：已经有托盘在跑就直接退出（与旧版行为一致）
        _singleInstanceMutex = OrcaSignals.TryAcquire(OrcaSignals.TrayMutexName);
        if (_singleInstanceMutex == null)
        {
            Shutdown(0);
            return;
        }

        _tray = new TrayApp();
        _tray.ExitRequested += (_, _) => Shutdown(0);
        _tray.Start();
    }

    // ============================================================
    //  控制台模式
    // ============================================================
    private void StartConsoleMode()
    {
        // 单实例：已有控制台在跑 → 通知它显示到前台，然后本实例退出
        _singleInstanceMutex = OrcaSignals.TryAcquire(OrcaSignals.ConsoleMutexName);
        if (_singleInstanceMutex == null)
        {
            OrcaSignals.Signal(OrcaSignals.ConsoleShowEventName);
            Shutdown(0);
            return;
        }

        var window = new ConsoleWindow();
        MainWindow = window;
        window.Closed += (_, _) => Shutdown(0);
        window.Show();
    }

    // ============================================================
    //  安装向导模式
    // ============================================================
    private void StartSetupMode()
    {
        var window = new SetupWindow();
        MainWindow = window;
        window.Closed += (_, _) => Shutdown(0);
        window.Show();
    }

    // ============================================================
    //  静默启动服务器模式（开机自启）
    // ============================================================
    private void StartServerMode()
    {
        try
        {
            var cfg = OrcaConfig.Load();
            // 已在运行就不重复启动；启动失败也静默（不打扰登录）
            if (!DshServer.IsRunning(cfg))
            {
                DshServer.Start(cfg);
            }
        }
        catch
        {
            // 开机自启失败绝不弹窗
        }
        Shutdown(0);
    }

    // ============================================================
    //  诊断模式：验证自定义对话框能正常渲染（改主题/配色后可跑一下）
    // ============================================================
    private void DialogTestMode()
    {
        OrcaDialog.Show(null, "对话框自检", "这是一条提示型对话框。\n\n如果你能看到圆角卡片、顶部品牌色线条和虎鲸小图标，说明渲染正常。",
            OrcaDialogType.Info, OrcaDialogButtons.Ok);
        var yes = OrcaDialog.Show(null, "对话框自检", "这是一条询问型对话框：点「是」表示渲染正常。", OrcaDialogType.Question, OrcaDialogButtons.YesNo);
        OrcaDialog.Show(null, "对话框自检", yes ? "你点了「是」，对话框工作正常。" : "你点了「否」，对话框同样工作正常。",
            OrcaDialogType.Warning, OrcaDialogButtons.Ok);
        Shutdown(0);
    }

    /// <inheritdoc/>
    protected override void OnExit(ExitEventArgs e)
    {
        try
        {
            _tray?.Dispose();
            _singleInstanceMutex?.ReleaseMutex();
            _singleInstanceMutex?.Dispose();
        }
        catch
        {
            // 退出清理失败无所谓
        }
        base.OnExit(e);
    }
}
