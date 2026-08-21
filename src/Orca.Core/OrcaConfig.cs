using System.Text.Json;
using System.Text.Json.Nodes;

namespace Orca.Core;

/// <summary>
/// 共享配置 ~/.dsh/orca-dsh-launcher.json（托盘 / 控制台 / 安装向导 / 插件共用）。
/// 与旧版 PowerShell + plugin.js 的字段完全一致，升级后配置直接沿用。
/// 写入时保留用户手动加的其它字段（如 peakWindows 峰谷时段自定义），不会被清掉。
/// </summary>
public sealed class OrcaConfig
{
    /// <summary>合法主题。</summary>
    public static readonly string[] ValidThemes = { "dark", "light" };

    /// <summary>合法强调色。</summary>
    public static readonly string[] ValidAccents = { "green", "blue", "purple", "amber", "rose", "slate" };

    /// <summary>本地 DSH 源码目录。</summary>
    public string DshDir { get; set; } = @"D:\deepseek harness";

    /// <summary>DSH Web 界面端口。</summary>
    public int Port { get; set; } = 3080;

    /// <summary>官方 GitHub 仓库（owner/repo）。</summary>
    public string Repo { get; set; } = "deepseek-ai/deepseek-harness";

    /// <summary>检查哪个分支。</summary>
    public string Branch { get; set; } = "master";

    /// <summary>网络查询超时（毫秒）。</summary>
    public int CheckTimeoutMs { get; set; } = 8000;

    /// <summary>DSH 启动时是否自动拉起 Orca 托盘。</summary>
    public bool TrayAutoStart { get; set; } = true;

    /// <summary>界面主题：dark / light。</summary>
    public string Theme { get; set; } = "dark";

    /// <summary>强调色：green / blue / purple / amber / rose / slate。</summary>
    public string Accent { get; set; } = "blue";

    /// <summary>是否深色主题。</summary>
    public bool IsDark => !string.Equals(Theme, "light", StringComparison.OrdinalIgnoreCase);

    /// <summary>DSH 界面地址。</summary>
    public string ServerUrl => "http://127.0.0.1:" + Port.ToString();

    /// <summary>
    /// 读取配置：文件不存在 / 损坏 / 字段缺失 → 一律用默认值兜底（绝不抛异常）。
    /// </summary>
    public static OrcaConfig Load()
    {
        var cfg = new OrcaConfig();
        var obj = Utf8Files.ParseJsonObject(Utf8Files.ReadAllTextOrNull(OrcaPaths.ConfigFile));
        if (obj == null) return cfg;

        var dshDir = GetString(obj, "dshDir");
        if (!string.IsNullOrWhiteSpace(dshDir)) cfg.DshDir = dshDir!;

        var port = GetInt(obj, "port");
        if (port is > 0 and <= 65535) cfg.Port = port.Value;

        var repo = GetString(obj, "repo");
        if (!string.IsNullOrWhiteSpace(repo)) cfg.Repo = repo!;

        var branch = GetString(obj, "branch");
        if (!string.IsNullOrWhiteSpace(branch)) cfg.Branch = branch!;

        var timeout = GetInt(obj, "checkTimeoutMs");
        if (timeout is > 0) cfg.CheckTimeoutMs = timeout.Value;

        var trayAuto = GetBool(obj, "trayAutoStart");
        if (trayAuto.HasValue) cfg.TrayAutoStart = trayAuto.Value;

        var theme = GetString(obj, "theme");
        if (theme != null && ValidThemes.Contains(theme, StringComparer.OrdinalIgnoreCase)) cfg.Theme = theme.ToLowerInvariant();

        var accent = GetString(obj, "accent");
        if (accent != null && ValidAccents.Contains(accent, StringComparer.OrdinalIgnoreCase)) cfg.Accent = accent.ToLowerInvariant();

        return cfg;
    }

    /// <summary>
    /// 保存配置（UTF-8 无 BOM，和 plugin.js 写出的格式一致）。
    /// 会先读回原文件，把本类不认识的字段原样保留。
    /// </summary>
    public bool Save()
    {
        try
        {
            // 规范化非法值，避免把坏数据写进文件
            var theme = ValidThemes.Contains(Theme, StringComparer.OrdinalIgnoreCase) ? Theme.ToLowerInvariant() : "dark";
            var accent = ValidAccents.Contains(Accent, StringComparer.OrdinalIgnoreCase) ? Accent.ToLowerInvariant() : "blue";
            var port = Port is > 0 and <= 65535 ? Port : 3080;

            // 先按固定顺序写本插件的字段（与旧版 ConvertTo-Json 输出顺序一致）
            var result = new JsonObject
            {
                ["dshDir"] = DshDir,
                ["port"] = port,
                ["repo"] = Repo,
                ["branch"] = Branch,
                ["checkTimeoutMs"] = CheckTimeoutMs,
                ["trayAutoStart"] = TrayAutoStart,
                ["theme"] = theme,
                ["accent"] = accent,
            };

            // 再把老文件里其它字段补回去（用户手动加的 peakWindows / peakReminder 等）
            var old = Utf8Files.ParseJsonObject(Utf8Files.ReadAllTextOrNull(OrcaPaths.ConfigFile));
            if (old != null)
            {
                foreach (var kv in old)
                {
                    if (result.ContainsKey(kv.Key)) continue;
                    result[kv.Key] = kv.Value?.DeepClone();
                }
            }

            var json = result.ToJsonString(new JsonSerializerOptions { WriteIndented = true });
            return Utf8Files.WriteAllText(OrcaPaths.ConfigFile, json);
        }
        catch
        {
            return false;
        }
    }

    /// <summary>把配置里的一个字段单独更新并保存（保留其它字段）。</summary>
    public static bool UpdateDshDir(string dshDir)
    {
        var cfg = Load();
        cfg.DshDir = dshDir;
        return cfg.Save();
    }

    private static string? GetString(JsonObject obj, string key)
    {
        try
        {
            var node = obj[key];
            if (node == null) return null;
            return node.GetValueKind() switch
            {
                JsonValueKind.String => node.GetValue<string>(),
                JsonValueKind.Number => node.ToJsonString(),
                _ => null,
            };
        }
        catch
        {
            return null;
        }
    }

    private static int? GetInt(JsonObject obj, string key)
    {
        try
        {
            var node = obj[key];
            if (node == null) return null;
            return node.GetValueKind() switch
            {
                JsonValueKind.Number => node.GetValue<int>(),
                JsonValueKind.String => int.TryParse(node.GetValue<string>(), out var n) ? n : null,
                _ => null,
            };
        }
        catch
        {
            return null;
        }
    }

    private static bool? GetBool(JsonObject obj, string key)
    {
        try
        {
            var node = obj[key];
            if (node == null) return null;
            return node.GetValueKind() switch
            {
                JsonValueKind.True => true,
                JsonValueKind.False => false,
                JsonValueKind.String => bool.TryParse(node.GetValue<string>(), out var b) ? b : null,
                _ => null,
            };
        }
        catch
        {
            return null;
        }
    }
}
