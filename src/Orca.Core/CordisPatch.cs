using System.Text;

namespace Orca.Core;

/// <summary>
/// DSH 插件登记文件 cordis.patch.yml 的读写。
/// 该文件是 UTF-8 无 BOM，必须显式指定编码（旧版最容易踩的坑之一）。
/// 登记块格式与旧版 install.ps1 生成的一模一样，新旧版本互相认。
/// </summary>
public static class CordisPatch
{
    /// <summary>本插件的包名。</summary>
    public const string PluginName = "orca-dsh-launcher";

    /// <summary>旧版更新检查插件包名（安装时自动迁移掉，避免两套更新检查并存）。</summary>
    public const string LegacyPluginName = "dsh-update-checker";

    /// <summary>登记块文本（前面留一个空行，与旧版完全一致）。</summary>
    private const string RegistrationBlock =
        "\n# --- orca-dsh-launcher 启动器插件 (自动安装，勿删此注释块) ---\n" +
        "- insert:\n" +
        "    - id: orca-dsh-launcher\n" +
        "      name: 'orca-dsh-launcher'\n" +
        "# --- end orca-dsh-launcher ---\n";

    /// <summary>插件是否已登记。</summary>
    public static bool IsRegistered(string? patchFile = null)
    {
        var file = patchFile ?? OrcaPaths.CordisPatchFile;
        var content = Utf8Files.ReadAllTextOrNull(file);
        return content != null && content.Contains(PluginName, StringComparison.Ordinal);
    }

    /// <summary>
    /// 登记插件（已登记则跳过，绝不重复写）。
    /// 文件不存在时会新建并写一行说明注释。
    /// </summary>
    public static bool Register(string? patchFile = null)
    {
        var file = patchFile ?? OrcaPaths.CordisPatchFile;
        try
        {
            OrcaPaths.EnsureParentDir(file);
            if (!File.Exists(file))
            {
                Utf8Files.WriteAllText(file, "# 由 Orca DSH Launcher 自动创建\n");
            }
            var content = Utf8Files.ReadAllTextOrNull(file) ?? string.Empty;
            if (content.Contains(PluginName, StringComparison.Ordinal)) return true;   // 已登记
            return Utf8Files.WriteAllText(file, content + RegistrationBlock);
        }
        catch
        {
            return false;
        }
    }

    /// <summary>移除本插件的登记块（卸载用）。</summary>
    public static bool Unregister(string? patchFile = null)
        => RemoveBlock(patchFile ?? OrcaPaths.CordisPatchFile,
            startMarkers: new[] { "orca-dsh-launcher 启动器插件", "# --- orca-dsh-launcher" },
            endMarker: "# --- end orca-dsh-launcher ---");

    /// <summary>移除旧版 dsh-update-checker 的登记块（安装时自动迁移）。</summary>
    public static bool UnregisterLegacy(string? patchFile = null)
        => RemoveBlock(patchFile ?? OrcaPaths.CordisPatchFile,
            startMarkers: new[] { "dsh-update-checker 更新检查插件", "# --- dsh-update-checker" },
            endMarker: "# --- end dsh-update-checker ---");

    /// <summary>
    /// 按注释块边界删除一段登记（与旧版 uninstall.ps1 的逐行扫描算法一致）。
    /// 文件不存在或没有这一块时返回 false（表示没做改动）。
    /// </summary>
    private static bool RemoveBlock(string file, string[] startMarkers, string endMarker)
    {
        var content = Utf8Files.ReadAllTextOrNull(file);
        if (content == null) return false;
        if (!startMarkers.Any(m => content.Contains(m, StringComparison.Ordinal))) return false;

        var lines = content.Replace("\r\n", "\n").Split('\n');
        var kept = new List<string>();
        bool inBlock = false;
        foreach (var line in lines)
        {
            if (startMarkers.Any(m => line.Contains(m, StringComparison.Ordinal))) inBlock = true;
            if (!inBlock) kept.Add(line);
            if (inBlock && line.Contains(endMarker, StringComparison.Ordinal)) inBlock = false;
        }
        // 去掉尾部多余空行，再补一个换行结尾
        while (kept.Count > 0 && kept[^1].Length == 0) kept.RemoveAt(kept.Count - 1);

        var sb = new StringBuilder();
        sb.Append(string.Join("\n", kept));
        sb.Append('\n');
        return Utf8Files.WriteAllText(file, sb.ToString());
    }
}
