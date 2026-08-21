namespace Orca.Core;

/// <summary>
/// 进程间协作：单实例互斥 + 托盘/控制台互相收发信号。
/// 名字与旧版 PowerShell 完全一致，保证新旧版本混装时也不会开出两个托盘。
/// </summary>
public static class OrcaSignals
{
    /// <summary>托盘单实例互斥名。</summary>
    public const string TrayMutexName = @"Local\DSH-Tray-Single";

    /// <summary>控制台单实例互斥名。</summary>
    public const string ConsoleMutexName = @"Local\DSH-Console-Single";

    /// <summary>让控制台显示到前台（托盘「打开管理界面」用）。</summary>
    public const string ConsoleShowEventName = @"Local\Orca-Console-Show";

    /// <summary>让控制台关闭（托盘「退出程序」用）。</summary>
    public const string ConsoleCloseEventName = @"Local\Orca-Console-Close";

    /// <summary>让托盘退出（控制台「退出程序」用）。</summary>
    public const string TrayCloseEventName = @"Local\Orca-Tray-Close";

    /// <summary>
    /// 抢占单实例互斥。返回值不为 null 表示抢到了（必须在整个进程生命周期持有）；
    /// 返回 null 表示已有实例在运行，调用方应当退出。
    /// </summary>
    public static Mutex? TryAcquire(string name)
    {
        try
        {
            var mutex = new Mutex(false, name);
            if (mutex.WaitOne(0, false)) return mutex;
            mutex.Dispose();
            return null;
        }
        catch (AbandonedMutexException)
        {
            // 上个持有者异常退出：这算抢到了
            try
            {
                return new Mutex(true, name);
            }
            catch
            {
                return null;
            }
        }
        catch
        {
            // 拿不到互斥体时宁可放行（不要因为系统限制导致程序打不开）
            return null;
        }
    }

    /// <summary>某个单实例是否已在运行（用来判断托盘是否活着）。</summary>
    public static bool IsRunning(string mutexName)
    {
        try
        {
            using var mutex = new Mutex(false, mutexName);
            if (mutex.WaitOne(0, false))
            {
                mutex.ReleaseMutex();
                return false;   // 能抢到 → 没人在跑
            }
            return true;
        }
        catch
        {
            return false;
        }
    }

    /// <summary>托盘是否在运行。</summary>
    public static bool IsTrayRunning() => IsRunning(TrayMutexName);

    /// <summary>控制台是否在运行。</summary>
    public static bool IsConsoleRunning() => IsRunning(ConsoleMutexName);

    /// <summary>创建一个可等待的信号（AutoReset），失败返回 null。</summary>
    public static EventWaitHandle? CreateEvent(string name)
    {
        try
        {
            return new EventWaitHandle(false, EventResetMode.AutoReset, name);
        }
        catch
        {
            return null;
        }
    }

    /// <summary>给已存在的信号发一次通知（对方没在跑就返回 false）。</summary>
    public static bool Signal(string name)
    {
        try
        {
            using var evt = EventWaitHandle.OpenExisting(name);
            evt.Set();
            return true;
        }
        catch
        {
            return false;
        }
    }

    /// <summary>非阻塞检查信号是否被触发过。</summary>
    public static bool Consume(EventWaitHandle? evt)
    {
        try
        {
            return evt != null && evt.WaitOne(0);
        }
        catch
        {
            return false;
        }
    }
}
