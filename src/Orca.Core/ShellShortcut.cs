using System.Runtime.InteropServices;
using System.Text;

namespace Orca.Core;

/// <summary>
/// 创建 Windows 快捷方式（.lnk）。
/// 原 PowerShell 版用 WScript.Shell COM 对象；这里直接调 Shell 的 IShellLink 接口，
/// 不依赖脚本宿主，行为与资源管理器"新建快捷方式"完全一致。
/// </summary>
public static class ShellShortcut
{
    /// <summary>
    /// 创建（或覆盖）一个快捷方式。成功返回 true，失败返回 false（不抛异常）。
    /// </summary>
    /// <param name="lnkPath">.lnk 文件完整路径</param>
    /// <param name="targetPath">要启动的程序</param>
    /// <param name="arguments">命令行参数</param>
    /// <param name="workingDirectory">工作目录</param>
    /// <param name="description">备注（鼠标悬停提示）</param>
    /// <param name="iconPath">图标文件（.ico 或 exe）</param>
    /// <param name="iconIndex">图标序号</param>
    public static bool Create(
        string lnkPath,
        string targetPath,
        string? arguments = null,
        string? workingDirectory = null,
        string? description = null,
        string? iconPath = null,
        int iconIndex = 0)
    {
        object? shellLinkObj = null;
        try
        {
            OrcaPaths.EnsureParentDir(lnkPath);
            shellLinkObj = new ShellLinkCoClass();
            var link = (IShellLinkW)shellLinkObj;

            link.SetPath(targetPath);
            if (!string.IsNullOrEmpty(arguments)) link.SetArguments(arguments);
            if (!string.IsNullOrEmpty(workingDirectory)) link.SetWorkingDirectory(workingDirectory);
            if (!string.IsNullOrEmpty(description)) link.SetDescription(description);
            if (!string.IsNullOrEmpty(iconPath) && File.Exists(iconPath)) link.SetIconLocation(iconPath, iconIndex);

            var persist = (IPersistFile)shellLinkObj;
            persist.Save(lnkPath, true);
            return true;
        }
        catch
        {
            return false;
        }
        finally
        {
            if (shellLinkObj != null)
            {
                try { Marshal.FinalReleaseComObject(shellLinkObj); } catch { /* 释放失败无所谓 */ }
            }
        }
    }

    /// <summary>删除快捷方式（不存在也算成功）。</summary>
    public static bool Delete(string lnkPath)
    {
        try
        {
            if (File.Exists(lnkPath)) File.Delete(lnkPath);
            return true;
        }
        catch
        {
            return false;
        }
    }

    /// <summary>快捷方式是否存在。</summary>
    public static bool Exists(string lnkPath)
    {
        try
        {
            return File.Exists(lnkPath);
        }
        catch
        {
            return false;
        }
    }

    // ---------- 以下是 Shell 的 COM 接口声明（顺序不能改，按 vtable 排列） ----------

    [ComImport]
    [Guid("00021401-0000-0000-C000-000000000046")]
    [ClassInterface(ClassInterfaceType.None)]
    private sealed class ShellLinkCoClass
    {
    }

    [ComImport]
    [Guid("000214F9-0000-0000-C000-000000000046")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IShellLinkW
    {
        void GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszFile, int cchMaxPath, IntPtr pfd, int fFlags);
        void GetIDList(out IntPtr ppidl);
        void SetIDList(IntPtr pidl);
        void GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszName, int cchMaxName);
        void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string pszName);
        void GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszDir, int cchMaxPath);
        void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string pszDir);
        void GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszArgs, int cchMaxPath);
        void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string pszArgs);
        void GetHotkey(out short pwHotkey);
        void SetHotkey(short wHotkey);
        void GetShowCmd(out int piShowCmd);
        void SetShowCmd(int iShowCmd);
        void GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszIconPath, int cchIconPath, out int piIcon);
        void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string pszIconPath, int iIcon);
        void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string pszPathRel, int dwReserved);
        void Resolve(IntPtr hwnd, int fFlags);
        void SetPath([MarshalAs(UnmanagedType.LPWStr)] string pszFile);
    }

    [ComImport]
    [Guid("0000010b-0000-0000-C000-000000000046")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IPersistFile
    {
        void GetClassID(out Guid pClassID);
        [PreserveSig]
        int IsDirty();
        void Load([MarshalAs(UnmanagedType.LPWStr)] string pszFileName, uint dwMode);
        void Save([MarshalAs(UnmanagedType.LPWStr)] string? pszFileName, [MarshalAs(UnmanagedType.Bool)] bool fRemember);
        void SaveCompleted([MarshalAs(UnmanagedType.LPWStr)] string pszFileName);
        void GetCurFile([MarshalAs(UnmanagedType.LPWStr)] out string ppszFileName);
    }
}

/// <summary>
/// 开机自启与桌面图标管理（对应旧版 Test/Set/Remove-DshAutoStart + New-DesktopShortcut）。
/// 快捷方式统一指向 orca.exe 的不同模式，彻底告别 wscript + .vbs。
/// </summary>
public static class ShortcutManager
{
    /// <summary>界面程序 orca.exe 的完整路径（优先当前目录，其次已安装的插件目录）。</summary>
    public static string AppExePath
    {
        get
        {
            var local = Path.Combine(AppInfo.BaseDir, "orca.exe");
            if (File.Exists(local)) return local;
            var installed = Path.Combine(OrcaPaths.PluginInstallDir, "bin", "orca.exe");
            if (File.Exists(installed)) return installed;
            return local;
        }
    }

    /// <summary>指定安装目录下的 orca.exe（安装流程里目标目录还不是当前目录）。</summary>
    public static string AppExeIn(string binDir) => Path.Combine(binDir, "orca.exe");

    /// <summary>
    /// 取快捷方式该用的图标：优先用目标 exe 旁边的 dsh-tray.ico，
    /// 这样快捷方式不会指向编译目录（编译目录随时可能被清掉）。
    /// </summary>
    private static string? IconFor(string exePath)
    {
        try
        {
            var dir = Path.GetDirectoryName(exePath);
            if (!string.IsNullOrEmpty(dir))
            {
                var ico = Path.Combine(dir, "dsh-tray.ico");
                if (File.Exists(ico)) return ico;
            }
        }
        catch
        {
            // 路径异常就退回全局查找
        }
        return AppInfo.TrayIconPath;
    }

    /// <summary>托盘开机自启是否已开启。</summary>
    public static bool IsTrayAutoStartEnabled() => ShellShortcut.Exists(OrcaPaths.TrayStartupLnk);

    /// <summary>开启 / 关闭托盘开机自启。</summary>
    public static bool SetTrayAutoStart(bool enabled, string? exePath = null)
    {
        if (!enabled) return ShellShortcut.Delete(OrcaPaths.TrayStartupLnk);
        var exe = exePath ?? AppExePath;
        return ShellShortcut.Create(
            OrcaPaths.TrayStartupLnk,
            exe,
            "--tray",
            Path.GetDirectoryName(exe),
            "Orca DSH Launcher 托盘（开机自启）",
            IconFor(exe));
    }

    /// <summary>DSH 服务器开机自启是否已开启。</summary>
    public static bool IsServerAutoStartEnabled() => ShellShortcut.Exists(OrcaPaths.ServerStartupLnk);

    /// <summary>开启 / 关闭 DSH 服务器开机自启。</summary>
    public static bool SetServerAutoStart(bool enabled, string? exePath = null)
    {
        if (!enabled) return ShellShortcut.Delete(OrcaPaths.ServerStartupLnk);
        var exe = exePath ?? AppExePath;
        return ShellShortcut.Create(
            OrcaPaths.ServerStartupLnk,
            exe,
            "--start-server",
            Path.GetDirectoryName(exe),
            "Orca DSH Launcher 开机自启 DSH 服务器",
            IconFor(exe));
    }

    /// <summary>创建桌面「Orca DSH Launcher」图标（双击打开控制台）。</summary>
    public static bool CreateDesktopShortcut(string? exePath = null)
    {
        var exe = exePath ?? AppExePath;
        if (!File.Exists(exe)) return false;
        var icon = IconFor(exe) ?? exe;
        return ShellShortcut.Create(
            OrcaPaths.ConsoleDesktopLnk,
            exe,
            "--console",
            Path.GetDirectoryName(exe),
            "Orca DSH Launcher 控制台（管理 DSH）",
            icon);
    }

    /// <summary>删除桌面图标。</summary>
    public static bool RemoveDesktopShortcut() => ShellShortcut.Delete(OrcaPaths.ConsoleDesktopLnk);
}
