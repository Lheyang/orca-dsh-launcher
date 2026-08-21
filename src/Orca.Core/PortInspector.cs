using System.Diagnostics;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;

namespace Orca.Core;

/// <summary>端口状态：空闲 / DSH 在跑 / 被其它程序占用。</summary>
public enum PortStatus
{
    /// <summary>没有任何程序监听。</summary>
    Free,

    /// <summary>DSH 正在监听（命令行特征匹配）。</summary>
    Running,

    /// <summary>被其它程序占用（绝不误杀）。</summary>
    Occupied,
}

/// <summary>端口占用者信息。</summary>
public sealed class PortOwner
{
    /// <summary>进程号。</summary>
    public int ProcessId { get; init; }

    /// <summary>进程名（如 node.exe）。</summary>
    public string Name { get; init; } = string.Empty;

    /// <summary>完整命令行（读不到时为空串）。</summary>
    public string CommandLine { get; init; } = string.Empty;

    /// <summary>界面展示用名称（没有进程名时退回 "PID 1234"）。</summary>
    public string DisplayName => string.IsNullOrWhiteSpace(Name) ? "PID " + ProcessId : Name;
}

/// <summary>
/// 端口探测与归属判断（替代原 Get-NetTCPConnection + Get-CimInstance 组合）。
/// 判断是不是 DSH 只看命令行特征 pnpm|dsh|deepseek|harness|tsx，
/// 绝不误杀其它 Node 程序 —— 这是原项目的关键纪律，此处原样保留。
/// </summary>
public static class PortInspector
{
    private static readonly Regex DshCommandLineRegex =
        new("pnpm|dsh|deepseek|harness|tsx", RegexOptions.IgnoreCase | RegexOptions.Compiled);

    /// <summary>
    /// 快速探测本机端口是否有人监听（TCP 连一下，默认 800ms 超时）。
    /// 注意：任何程序监听都算 true；要区分 DSH / 被占用请用 GetStatus。
    /// </summary>
    public static bool IsPortListening(int port, int timeoutMs = 800)
        => IsHostPortOpen("127.0.0.1", port, timeoutMs);

    /// <summary>探测任意主机端口是否通（安装向导的网络体检用，默认 3 秒）。</summary>
    public static bool IsHostPortOpen(string host, int port, int timeoutMs = 3000)
    {
        try
        {
            using var client = new TcpClient();
            var task = client.ConnectAsync(host, port);
            if (!task.Wait(timeoutMs)) return false;
            return client.Connected;
        }
        catch
        {
            return false;
        }
    }

    /// <summary>等待端口就绪：最多等 timeoutSeconds 秒，每 0.5 秒查一次。</summary>
    public static bool WaitPortReady(int port, int timeoutSeconds = 60)
    {
        var deadline = DateTime.UtcNow.AddSeconds(timeoutSeconds);
        while (DateTime.UtcNow < deadline)
        {
            if (IsPortListening(port)) return true;
            Thread.Sleep(500);
        }
        return IsPortListening(port);
    }

    /// <summary>取监听指定端口的进程号（没有返回 null）。</summary>
    public static int? GetListenerPid(int port)
    {
        var pid = FindListenerPid(NativeMethods.AF_INET, port);
        pid ??= FindListenerPid(NativeMethods.AF_INET6, port);
        return pid;
    }

    /// <summary>取端口占用者详情（PID / 进程名 / 命令行），没有返回 null。</summary>
    public static PortOwner? GetOwner(int port)
    {
        var pid = GetListenerPid(port);
        if (pid == null) return null;

        string name = string.Empty;
        try
        {
            using var proc = Process.GetProcessById(pid.Value);
            name = proc.ProcessName + ".exe";
        }
        catch
        {
            // 进程刚退出 / 权限不足：至少把 PID 报出去，让调用方按未知占用者处理
        }

        var cmd = ProcessCommandLine.TryGet(pid.Value) ?? string.Empty;
        return new PortOwner { ProcessId = pid.Value, Name = name, CommandLine = cmd };
    }

    /// <summary>判断占用者是不是 DSH（只看命令行特征）。</summary>
    public static bool IsDshOwner(PortOwner? owner)
    {
        if (owner == null) return false;
        return !string.IsNullOrEmpty(owner.CommandLine) && DshCommandLineRegex.IsMatch(owner.CommandLine);
    }

    /// <summary>端口状态：free / running / occupied。</summary>
    public static PortStatus GetStatus(int port)
    {
        var owner = GetOwner(port);
        if (owner == null) return PortStatus.Free;
        return IsDshOwner(owner) ? PortStatus.Running : PortStatus.Occupied;
    }

    /// <summary>端口状态 + 占用者一次取回（界面刷新时少查一遍表）。</summary>
    public static (PortStatus Status, PortOwner? Owner) GetStatusWithOwner(int port)
    {
        var owner = GetOwner(port);
        if (owner == null) return (PortStatus.Free, null);
        return (IsDshOwner(owner) ? PortStatus.Running : PortStatus.Occupied, owner);
    }

    /// <summary>状态转旧版一样的英文串（quick-check JSON 与 /orca 命令输出兼容）。</summary>
    public static string ToText(PortStatus status) => status switch
    {
        PortStatus.Running => "running",
        PortStatus.Occupied => "occupied",
        _ => "free",
    };

    private static int? FindListenerPid(int family, int port)
    {
        IntPtr table = IntPtr.Zero;
        try
        {
            int size = 0;
            uint ret = NativeMethods.GetExtendedTcpTable(IntPtr.Zero, ref size, false, family,
                NativeMethods.TCP_TABLE_OWNER_PID_LISTENER, 0);
            if (ret != NativeMethods.ERROR_INSUFFICIENT_BUFFER && ret != 0) return null;
            if (size <= 0) return null;

            table = Marshal.AllocHGlobal(size);
            ret = NativeMethods.GetExtendedTcpTable(table, ref size, false, family,
                NativeMethods.TCP_TABLE_OWNER_PID_LISTENER, 0);
            if (ret != 0) return null;

            int rowCount = Marshal.ReadInt32(table);
            IntPtr rowPtr = table + 4;

            if (family == NativeMethods.AF_INET)
            {
                int rowSize = Marshal.SizeOf<NativeMethods.MIB_TCPROW_OWNER_PID>();
                for (int i = 0; i < rowCount; i++)
                {
                    var row = Marshal.PtrToStructure<NativeMethods.MIB_TCPROW_OWNER_PID>(rowPtr);
                    if (DecodePort(row.LocalPort) == port) return (int)row.OwningPid;
                    rowPtr += rowSize;
                }
            }
            else
            {
                int rowSize = Marshal.SizeOf<NativeMethods.MIB_TCP6ROW_OWNER_PID>();
                for (int i = 0; i < rowCount; i++)
                {
                    var row = Marshal.PtrToStructure<NativeMethods.MIB_TCP6ROW_OWNER_PID>(rowPtr);
                    if (DecodePort(row.LocalPort) == port) return (int)row.OwningPid;
                    rowPtr += rowSize;
                }
            }
            return null;
        }
        catch
        {
            return null;
        }
        finally
        {
            if (table != IntPtr.Zero) Marshal.FreeHGlobal(table);
        }
    }

    /// <summary>Windows 把端口存成网络字节序放在 DWORD 低两字节，这里换回主机序。</summary>
    private static int DecodePort(uint raw)
    {
        var b = BitConverter.GetBytes(raw);
        return (b[0] << 8) | b[1];
    }
}
