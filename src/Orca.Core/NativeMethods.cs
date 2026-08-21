using System.Runtime.InteropServices;

namespace Orca.Core;

/// <summary>
/// Win32 API 声明集中处（替代原 PowerShell 里内联的 Add-Type C# 片段）。
/// 全部 P/Invoke 都放这一处，方便审阅。
/// </summary>
internal static class NativeMethods
{
    // ---------- 窗口控制（把浏览器窗口最大化并置前） ----------
    public const int SW_MAXIMIZE = 3;
    public const int SW_RESTORE = 9;

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    // ---------- 窗口类图标（无边框 WPF 窗口的任务栏图标） ----------
    public const int GCLP_HICON = -14;
    public const int GCLP_HICONSM = -34;

    [DllImport("user32.dll", EntryPoint = "SetClassLongPtrW", SetLastError = true)]
    public static extern IntPtr SetClassLongPtr64(IntPtr hWnd, int nIndex, IntPtr dwNewLong);

    [DllImport("user32.dll", EntryPoint = "SetClassLongW", SetLastError = true)]
    public static extern int SetClassLong32(IntPtr hWnd, int nIndex, int dwNewLong);

    // ---------- 任务栏归组标识（让任务栏显示虎鲸图标而不是宿主 exe 图标） ----------
    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
    public static extern void SetCurrentProcessExplicitAppUserModelID([MarshalAs(UnmanagedType.LPWStr)] string appId);

    // ---------- TCP 连接表（查端口被哪个进程监听，替代 Get-NetTCPConnection / netstat） ----------
    public const int AF_INET = 2;
    public const int AF_INET6 = 23;
    public const int TCP_TABLE_OWNER_PID_LISTENER = 3;
    public const uint ERROR_INSUFFICIENT_BUFFER = 122;

    [DllImport("iphlpapi.dll", SetLastError = true)]
    public static extern uint GetExtendedTcpTable(
        IntPtr pTcpTable,
        ref int pdwSize,
        bool bOrder,
        int ulAf,
        int tableClass,
        int reserved);

    [StructLayout(LayoutKind.Sequential)]
    public struct MIB_TCPROW_OWNER_PID
    {
        public uint State;
        public uint LocalAddr;
        public uint LocalPort;      // 端口在低 2 字节，网络字节序
        public uint RemoteAddr;
        public uint RemotePort;
        public uint OwningPid;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct MIB_TCP6ROW_OWNER_PID
    {
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 16)]
        public byte[] LocalAddr;
        public uint LocalScopeId;
        public uint LocalPort;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 16)]
        public byte[] RemoteAddr;
        public uint RemoteScopeId;
        public uint RemotePort;
        public uint State;
        public uint OwningPid;
    }

    // ---------- 读取任意进程的命令行（判断端口占用者是不是 DSH） ----------
    public const int PROCESS_QUERY_INFORMATION = 0x0400;
    public const int PROCESS_VM_READ = 0x0010;

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr OpenProcess(int dwDesiredAccess, bool bInheritHandle, int dwProcessId);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr hObject);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool ReadProcessMemory(
        IntPtr hProcess,
        IntPtr lpBaseAddress,
        byte[] lpBuffer,
        IntPtr dwSize,
        out IntPtr lpNumberOfBytesRead);

    [StructLayout(LayoutKind.Sequential)]
    public struct PROCESS_BASIC_INFORMATION
    {
        public IntPtr Reserved1;
        public IntPtr PebBaseAddress;
        public IntPtr Reserved2_0;
        public IntPtr Reserved2_1;
        public IntPtr UniqueProcessId;
        public IntPtr Reserved3;
    }

    [DllImport("ntdll.dll")]
    public static extern int NtQueryInformationProcess(
        IntPtr processHandle,
        int processInformationClass,
        ref PROCESS_BASIC_INFORMATION processInformation,
        int processInformationLength,
        out int returnLength);
}

/// <summary>
/// 读取指定进程的完整命令行。
/// 原 PowerShell 版用 Get-CimInstance Win32_Process（每次 50~200ms，界面轮询时明显卡）；
/// 这里直接读进程的 PEB，微秒级完成，且不依赖 WMI 服务。
/// 读不到时返回 null，调用方按"未知占用者"处理（绝不误判成 DSH，也绝不误杀）。
/// </summary>
public static class ProcessCommandLine
{
    /// <summary>取进程命令行（失败返回 null）。</summary>
    public static string? TryGet(int processId)
    {
        IntPtr handle = IntPtr.Zero;
        try
        {
            handle = NativeMethods.OpenProcess(
                NativeMethods.PROCESS_QUERY_INFORMATION | NativeMethods.PROCESS_VM_READ,
                false,
                processId);
            if (handle == IntPtr.Zero) return null;

            var pbi = new NativeMethods.PROCESS_BASIC_INFORMATION();
            int status = NativeMethods.NtQueryInformationProcess(handle, 0, ref pbi, Marshal.SizeOf(pbi), out _);
            if (status != 0 || pbi.PebBaseAddress == IntPtr.Zero) return null;

            // 64 位进程 PEB 布局：+0x20 = ProcessParameters 指针
            var paramsPtr = ReadPointer(handle, pbi.PebBaseAddress + 0x20);
            if (paramsPtr == IntPtr.Zero) return null;

            // RTL_USER_PROCESS_PARAMETERS：+0x70 = CommandLine（UNICODE_STRING）
            //   +0x70 Length(ushort) / +0x72 MaximumLength(ushort) / +0x78 Buffer(指针)
            var lenBuf = new byte[2];
            if (!Read(handle, paramsPtr + 0x70, lenBuf)) return null;
            int byteLength = BitConverter.ToUInt16(lenBuf, 0);
            if (byteLength <= 0 || byteLength > 64 * 1024) return null;

            var bufferPtr = ReadPointer(handle, paramsPtr + 0x78);
            if (bufferPtr == IntPtr.Zero) return null;

            var strBuf = new byte[byteLength];
            if (!Read(handle, bufferPtr, strBuf)) return null;

            return System.Text.Encoding.Unicode.GetString(strBuf).TrimEnd('\0');
        }
        catch
        {
            return null;
        }
        finally
        {
            if (handle != IntPtr.Zero) NativeMethods.CloseHandle(handle);
        }
    }

    private static IntPtr ReadPointer(IntPtr handle, IntPtr address)
    {
        var buf = new byte[IntPtr.Size];
        if (!Read(handle, address, buf)) return IntPtr.Zero;
        return IntPtr.Size == 8 ? new IntPtr(BitConverter.ToInt64(buf, 0)) : new IntPtr(BitConverter.ToInt32(buf, 0));
    }

    private static bool Read(IntPtr handle, IntPtr address, byte[] buffer)
    {
        return NativeMethods.ReadProcessMemory(handle, address, buffer, new IntPtr(buffer.Length), out var read)
               && read.ToInt64() == buffer.Length;
    }
}
