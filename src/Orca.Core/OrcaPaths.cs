using System.Diagnostics;
using System.Reflection;
using System.Text;
using System.Text.Json.Nodes;

namespace Orca.Core;

/// <summary>
/// 所有文件路径的唯一出处（对应原 orca-common.ps1 里散落的 Join-Path）。
/// 用户数据统一放在 ~/.dsh 下，与旧版 PowerShell 完全一致，升级不丢数据。
/// </summary>
public static class OrcaPaths
{
    /// <summary>用户主目录（C:\Users\xxx）。</summary>
    public static string Home => Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);

    /// <summary>DSH 用户目录 ~/.dsh。</summary>
    public static string DshHome => Path.Combine(Home, ".dsh");

    /// <summary>共享配置文件 ~/.dsh/orca-dsh-launcher.json（托盘 / 控制台 / 插件共用）。</summary>
    public static string ConfigFile => Path.Combine(DshHome, "orca-dsh-launcher.json");

    /// <summary>使用统计 ~/.dsh/orca-stats.json。</summary>
    public static string StatsFile => Path.Combine(DshHome, "orca-stats.json");

    /// <summary>更新检查结果 ~/.dsh/update-check-state.json（插件写、界面读）。</summary>
    public static string UpdateStateFile => Path.Combine(DshHome, "update-check-state.json");

    /// <summary>DSH 服务器运行日志 ~/.dsh/orca-dsh-server.log。</summary>
    public static string ServerLogFile => Path.Combine(DshHome, "orca-dsh-server.log");

    /// <summary>上次成功构建的提交号缓存 ~/.dsh/orca-dsh-last-build.json。</summary>
    public static string BuildCacheFile => Path.Combine(DshHome, "orca-dsh-last-build.json");

    /// <summary>DSH 构建日志 ~/.dsh/orca-dsh-build.log。</summary>
    public static string BuildLogFile => Path.Combine(DshHome, "orca-dsh-build.log");

    /// <summary>DSH web 配置目录 ~/.dsh/profiles/web。</summary>
    public static string DshWebProfileDir => Path.Combine(DshHome, "profiles", "web");

    /// <summary>DSH 插件目录 ~/.dsh/profiles/web/node_modules。</summary>
    public static string DshNodeModulesDir => Path.Combine(DshWebProfileDir, "node_modules");

    /// <summary>本插件在 DSH 里的安装位置。</summary>
    public static string PluginInstallDir => Path.Combine(DshNodeModulesDir, "orca-dsh-launcher");

    /// <summary>DSH 插件登记文件 cordis.patch.yml。</summary>
    public static string CordisPatchFile => Path.Combine(DshWebProfileDir, "cordis.patch.yml");

    /// <summary>
    /// 安装 / 卸载前的自动备份目录 ~/.dsh/orca-backup。
    /// 放用户目录而不是仓库目录：从发布包安装时也一定可写，且不会被打进分发包。
    /// </summary>
    public static string BackupDir => Path.Combine(DshHome, "orca-backup");

    /// <summary>Windows 启动文件夹。</summary>
    public static string StartupDir => Environment.GetFolderPath(Environment.SpecialFolder.Startup);

    /// <summary>桌面文件夹。</summary>
    public static string DesktopDir => Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory);

    /// <summary>托盘开机自启快捷方式（与旧版同名，升级时自动接管）。</summary>
    public static string TrayStartupLnk => Path.Combine(StartupDir, "Orca DSH Launcher.lnk");

    /// <summary>DSH 服务器开机自启快捷方式（与旧版同名）。</summary>
    public static string ServerStartupLnk => Path.Combine(StartupDir, "Orca DSH 服务器.lnk");

    /// <summary>桌面控制台图标（与旧版同名）。</summary>
    public static string ConsoleDesktopLnk => Path.Combine(DesktopDir, "Orca DSH Launcher.lnk");

    /// <summary>控制台安装页用的安装日志（临时目录）。</summary>
    public static string ConsoleInstallLogFile => Path.Combine(Path.GetTempPath(), "orca-install.log");

    /// <summary>独立安装向导用的安装日志（临时目录，与控制台分开避免打架）。</summary>
    public static string SetupInstallLogFile => Path.Combine(Path.GetTempPath(), "orca-setup-install.log");

    /// <summary>托盘"上次已通知过的版本"记录（避免每次开机都弹气泡）。</summary>
    public static string TrayLastNotifiedFile => Path.Combine(Path.GetTempPath(), "dsh-tray-last-notified.txt");

    /// <summary>确保目录存在（不存在就创建，失败不抛）。</summary>
    public static void EnsureDir(string dir)
    {
        try
        {
            if (!string.IsNullOrWhiteSpace(dir) && !Directory.Exists(dir))
            {
                Directory.CreateDirectory(dir);
            }
        }
        catch
        {
            // 创建不了就算了，调用方会在写文件时收到错误
        }
    }

    /// <summary>确保某个文件的父目录存在。</summary>
    public static void EnsureParentDir(string file)
    {
        var dir = Path.GetDirectoryName(file);
        if (!string.IsNullOrEmpty(dir)) EnsureDir(dir);
    }
}

/// <summary>
/// UTF-8 无 BOM 的文本读写（DSH 的 json / yml 配置全部是无 BOM，
/// 这是原 PowerShell 版最容易踩的坑，这里统一封装掉）。
/// </summary>
public static class Utf8Files
{
    /// <summary>UTF-8 无 BOM 编码实例。</summary>
    public static readonly UTF8Encoding NoBom = new(encoderShouldEmitUTF8Identifier: false);

    /// <summary>读文本（文件不存在或读失败返回 null，绝不抛）。</summary>
    public static string? ReadAllTextOrNull(string path)
    {
        try
        {
            return File.Exists(path) ? File.ReadAllText(path, NoBom) : null;
        }
        catch
        {
            return null;
        }
    }

    /// <summary>写文本（UTF-8 无 BOM），成功返回 true。</summary>
    public static bool WriteAllText(string path, string content)
    {
        try
        {
            OrcaPaths.EnsureParentDir(path);
            File.WriteAllText(path, content, NoBom);
            return true;
        }
        catch
        {
            return false;
        }
    }

    /// <summary>原子写文本：先写临时文件再替换，防止写一半损坏原文件。</summary>
    public static bool WriteAllTextAtomic(string path, string content)
    {
        try
        {
            OrcaPaths.EnsureParentDir(path);
            var tmp = path + ".tmp";
            File.WriteAllText(tmp, content, NoBom);
            File.Move(tmp, path, overwrite: true);
            return true;
        }
        catch
        {
            return false;
        }
    }

    /// <summary>追加一行（UTF-8 无 BOM）。</summary>
    public static void AppendLine(string path, string text)
    {
        try
        {
            OrcaPaths.EnsureParentDir(path);
            File.AppendAllText(path, text + "\n", NoBom);
        }
        catch
        {
            // 日志写不进去不影响主流程
        }
    }

    /// <summary>
    /// 共享读取整个文本文件：目标文件可能正被其他进程（cmd 重定向）写入，
    /// 必须用 FileShare.ReadWrite 打开，否则会因独占锁定读失败。
    /// </summary>
    public static string? ReadAllTextShared(string path)
    {
        try
        {
            if (!File.Exists(path)) return null;
            using var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
            using var reader = new StreamReader(fs, NoBom);
            return reader.ReadToEnd();
        }
        catch
        {
            return null;
        }
    }

    /// <summary>解析 JSON 成可改写的节点树（失败返回 null）。</summary>
    public static JsonObject? ParseJsonObject(string? json)
    {
        if (string.IsNullOrWhiteSpace(json)) return null;
        try
        {
            return JsonNode.Parse(json) as JsonObject;
        }
        catch
        {
            return null;
        }
    }
}

/// <summary>
/// 程序自身信息：版本号、资源文件位置。
/// 版本号唯一来源仍是 package.json（AGENTS.md 的规定），
/// 读不到时退回程序集版本，保证界面永远有值可显示。
/// </summary>
public static class AppInfo
{
    private static string? _cachedVersion;

    /// <summary>当前 exe 所在目录（安装后是 …/orca-dsh-launcher/bin）。</summary>
    public static string BaseDir => AppContext.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar);

    /// <summary>插件包根目录（bin 的上一级；找不到就用 BaseDir）。</summary>
    public static string PackageRootDir
    {
        get
        {
            var parent = Directory.GetParent(BaseDir)?.FullName;
            if (parent != null && File.Exists(Path.Combine(parent, "package.json"))) return parent;
            return BaseDir;
        }
    }

    /// <summary>版本号（形如 2.0.0）。</summary>
    public static string Version
    {
        get
        {
            if (_cachedVersion != null) return _cachedVersion;
            _cachedVersion = ReadVersionFromPackageJson() ?? ReadVersionFromAssembly();
            return _cachedVersion;
        }
    }

    /// <summary>带 v 前缀的版本号（形如 v2.0.0）。</summary>
    public static string VersionDisplay => "v" + Version;

    private static string? ReadVersionFromPackageJson()
    {
        // 依次尝试：exe 同级、上一级（安装后布局）、上两级（开发时 src/xxx/bin/Debug 布局）
        var candidates = new List<string>();
        var dir = new DirectoryInfo(BaseDir);
        for (int i = 0; i < 5 && dir != null; i++)
        {
            candidates.Add(Path.Combine(dir.FullName, "package.json"));
            dir = dir.Parent;
        }
        foreach (var file in candidates)
        {
            var obj = Utf8Files.ParseJsonObject(Utf8Files.ReadAllTextOrNull(file));
            var name = obj?["name"]?.GetValue<string>();
            var ver = obj?["version"]?.GetValue<string>();
            // 只认本插件的 package.json，避免误读别的包
            if (!string.IsNullOrWhiteSpace(ver) && string.Equals(name, "orca-dsh-launcher", StringComparison.OrdinalIgnoreCase))
            {
                return ver;
            }
        }
        return null;
    }

    private static string ReadVersionFromAssembly()
    {
        try
        {
            var asm = Assembly.GetEntryAssembly() ?? Assembly.GetExecutingAssembly();
            var info = asm.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion;
            if (!string.IsNullOrWhiteSpace(info))
            {
                // 去掉 +commit 后缀
                var plus = info.IndexOf('+');
                return plus > 0 ? info[..plus] : info;
            }
            var v = asm.GetName().Version;
            if (v != null) return $"{v.Major}.{v.Minor}.{v.Build}";
        }
        catch
        {
            // 读不到就用兜底值
        }
        return "0.0.0";
    }

    /// <summary>
    /// 找一个随程序分发的资源文件（图标等）：先看 exe 目录，再看包根目录，
    /// 最后看已安装的插件目录，全都没有返回 null。
    /// </summary>
    public static string? FindAsset(string fileName)
    {
        var probes = new[]
        {
            Path.Combine(BaseDir, fileName),
            Path.Combine(BaseDir, "Assets", fileName),
            Path.Combine(PackageRootDir, fileName),
            Path.Combine(PackageRootDir, "bin", fileName),
            Path.Combine(OrcaPaths.PluginInstallDir, "bin", fileName),
            Path.Combine(OrcaPaths.PluginInstallDir, "orca", fileName),
        };
        foreach (var p in probes)
        {
            try
            {
                if (File.Exists(p)) return p;
            }
            catch
            {
                // 路径非法就跳过
            }
        }
        return null;
    }

    /// <summary>虎鲸托盘图标文件路径（找不到返回 null）。</summary>
    public static string? TrayIconPath => FindAsset("dsh-tray.ico");

    /// <summary>当前可执行文件完整路径（.NET 单文件发布也能取对）。</summary>
    public static string ExecutablePath
    {
        get
        {
            try
            {
                var path = Environment.ProcessPath;
                if (!string.IsNullOrEmpty(path)) return path;
            }
            catch
            {
                // 退回主模块
            }
            return Process.GetCurrentProcess().MainModule?.FileName ?? "orca.exe";
        }
    }
}
