namespace Orca.Core;

/// <summary>
/// 日志文件读写（DSH 服务器日志 + 安装日志）。
/// 服务器日志超过 2MB 自动轮转成 .1，防止无限增长塞满硬盘（与旧版一致）。
/// </summary>
public static class OrcaLog
{
    /// <summary>服务器日志默认轮转上限：2MB。</summary>
    public const long DefaultMaxBytes = 2 * 1024 * 1024;

    /// <summary>服务器日志文件路径。</summary>
    public static string ServerLogFile => OrcaPaths.ServerLogFile;

    /// <summary>
    /// 日志轮转：超过上限就把旧日志改名成 .1 再开新日志。
    /// 返回是否真的轮转了。
    /// </summary>
    public static bool RotateServerLog(long maxBytes = DefaultMaxBytes)
    {
        try
        {
            var file = ServerLogFile;
            if (!File.Exists(file)) return false;
            var len = new FileInfo(file).Length;
            if (len <= maxBytes) return false;

            var bak = file + ".1";
            if (File.Exists(bak)) File.Delete(bak);
            File.Move(file, bak);
            return true;
        }
        catch
        {
            return false;
        }
    }

    /// <summary>
    /// 读服务器日志尾部若干行（默认 200 行）。
    /// 日志正被 cmd 重定向写入，必须共享读取；读不到返回空数组。
    /// </summary>
    public static string[] ReadServerLogTail(int lines = 200)
        => ReadTail(ServerLogFile, lines, keepEmptyLines: true);

    /// <summary>清空服务器日志。</summary>
    public static bool ClearServerLog()
    {
        try
        {
            if (File.Exists(ServerLogFile)) File.Delete(ServerLogFile);
            return true;
        }
        catch
        {
            // 文件被占用时退一步：截断成空文件
            try
            {
                using var fs = new FileStream(ServerLogFile, FileMode.Truncate, FileAccess.Write, FileShare.ReadWrite);
                return true;
            }
            catch
            {
                return false;
            }
        }
    }

    /// <summary>读任意日志文件的尾部若干行。</summary>
    public static string[] ReadTail(string file, int lines, bool keepEmptyLines)
    {
        var all = Utf8Files.ReadAllTextShared(file);
        if (string.IsNullOrEmpty(all)) return Array.Empty<string>();

        var arr = all.Replace("\r\n", "\n").Split('\n');
        if (!keepEmptyLines)
        {
            arr = arr.Where(l => l.Trim().Length > 0).ToArray();
        }
        if (arr.Length > lines)
        {
            arr = arr.Skip(arr.Length - lines).ToArray();
        }
        return arr;
    }
}

/// <summary>
/// 安装日志（控制台「安装」页与独立安装向导共用同一套逻辑，只是文件不同）。
/// </summary>
public sealed class InstallLog
{
    /// <summary>日志文件路径。</summary>
    public string FilePath { get; }

    /// <summary>创建一个安装日志写入器。</summary>
    public InstallLog(string filePath)
    {
        FilePath = filePath;
    }

    /// <summary>控制台「安装」页用的日志（~/AppData/Local/Temp/orca-install.log）。</summary>
    public static InstallLog ForConsole() => new(OrcaPaths.ConsoleInstallLogFile);

    /// <summary>独立安装向导用的日志（与控制台分开，避免两边同时写打架）。</summary>
    public static InstallLog ForSetup() => new(OrcaPaths.SetupInstallLogFile);

    /// <summary>写一行日志（UTF-8 无 BOM 追加）。</summary>
    public void Write(string text) => Utf8Files.AppendLine(FilePath, text);

    /// <summary>写一个带分隔线的小标题。</summary>
    public void WriteSection(string title)
    {
        Write(string.Empty);
        Write("========================================");
        Write(title);
        Write("========================================");
    }

    /// <summary>清空日志（每次开始安装前调用）。</summary>
    public void Clear()
    {
        try
        {
            if (File.Exists(FilePath)) File.Delete(FilePath);
        }
        catch
        {
            // 删不掉就算了，日志会接着往后追加
        }
    }

    /// <summary>读日志尾部（界面实时刷新用；还没开始时给一句提示）。</summary>
    public string[] ReadTail(int lines = 150)
    {
        if (!File.Exists(FilePath)) return new[] { "（日志还没开始）" };
        var arr = OrcaLog.ReadTail(FilePath, lines, keepEmptyLines: false);
        return arr.Length == 0 ? new[] { "（日志还没开始）" } : arr;
    }
}
