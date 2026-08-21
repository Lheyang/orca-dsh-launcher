using System.Windows;
using System.Windows.Interop;
using Microsoft.Win32;
using Orca.Core;
using Orca.Core.Ui;

namespace Orca.App;

/// <summary>
/// 任务栏 / 窗口图标相关的 Windows 细节
/// （对应旧版 dsh-console.ps1 里那两段 Add-Type Win32 代码）。
/// </summary>
internal static class Win32Helper
{
    /// <summary>任务栏归组标识。</summary>
    public const string AppUserModelId = "Orca.DSH.Launcher";

    /// <summary>
    /// 给进程设置 AppUserModelID 并在注册表登记默认图标，
    /// 这样任务栏按钮显示虎鲸图标而不是宿主程序图标。
    /// </summary>
    public static void SetupAppUserModelId()
    {
        try
        {
            var ico = AppInfo.TrayIconPath;
            if (ico != null)
            {
                using var key = Registry.CurrentUser.CreateSubKey(@"Software\Classes\AppUserModelId\" + AppUserModelId);
                key?.SetValue("DefaultIcon", "\"" + ico + "\",0");
            }
            NativeAppId.SetCurrentProcessExplicitAppUserModelID(AppUserModelId);
        }
        catch
        {
            // 设置失败只是图标不好看，不影响功能
        }
    }

    /// <summary>
    /// 强制设置窗口类图标：无边框 WPF 窗口不应用 Window.Icon，
    /// 必须改窗口类图标，任务栏才会显示虎鲸。
    /// </summary>
    public static void ApplyWindowClassIcon(Window window)
    {
        try
        {
            var handle = new WindowInteropHelper(window).Handle;
            if (handle == IntPtr.Zero) return;
            var icon = IconLoader.LoadIconSized(32);
            if (icon == null) return;

            if (IntPtr.Size == 8)
            {
                NativeIcon.SetClassLongPtr64(handle, NativeIcon.GCLP_HICON, icon.Handle);
                NativeIcon.SetClassLongPtr64(handle, NativeIcon.GCLP_HICONSM, icon.Handle);
            }
            else
            {
                NativeIcon.SetClassLong32(handle, NativeIcon.GCLP_HICON, icon.Handle.ToInt32());
                NativeIcon.SetClassLong32(handle, NativeIcon.GCLP_HICONSM, icon.Handle.ToInt32());
            }
        }
        catch
        {
            // 同上，纯外观
        }
    }
}

/// <summary>SetCurrentProcessExplicitAppUserModelID 的声明。</summary>
internal static class NativeAppId
{
    [System.Runtime.InteropServices.DllImport("shell32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode, PreserveSig = false)]
    public static extern void SetCurrentProcessExplicitAppUserModelID(
        [System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.LPWStr)] string appId);
}

/// <summary>窗口类图标 API 的声明。</summary>
internal static class NativeIcon
{
    public const int GCLP_HICON = -14;
    public const int GCLP_HICONSM = -34;

    [System.Runtime.InteropServices.DllImport("user32.dll", EntryPoint = "SetClassLongPtrW", SetLastError = true)]
    public static extern IntPtr SetClassLongPtr64(IntPtr hWnd, int nIndex, IntPtr dwNewLong);

    [System.Runtime.InteropServices.DllImport("user32.dll", EntryPoint = "SetClassLongW", SetLastError = true)]
    public static extern int SetClassLong32(IntPtr hWnd, int nIndex, int dwNewLong);
}
