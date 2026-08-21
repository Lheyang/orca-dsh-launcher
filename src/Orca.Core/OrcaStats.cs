using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Orca.Core;

/// <summary>
/// 使用统计 ~/.dsh/orca-stats.json（原子写入，坏了不影响使用）。
/// 字段与旧版 PowerShell 完全一致：launchCount / serverStarts / totalRunSeconds / lastStartTime。
/// </summary>
public sealed class OrcaStats
{
    /// <summary>托盘 / 控制台被打开的次数。</summary>
    public int LaunchCount { get; set; }

    /// <summary>服务器启动次数。</summary>
    public int ServerStarts { get; set; }

    /// <summary>累计运行秒数。</summary>
    public long TotalRunSeconds { get; set; }

    /// <summary>本次启动时间（ISO 8601 字符串；关闭时用来累加运行时长）。</summary>
    public string? LastStartTime { get; set; }

    /// <summary>读统计（文件不存在 / 损坏 → 全零）。</summary>
    public static OrcaStats Load()
    {
        var stats = new OrcaStats();
        var obj = Utf8Files.ParseJsonObject(Utf8Files.ReadAllTextOrNull(OrcaPaths.StatsFile));
        if (obj == null) return stats;
        try
        {
            if (obj["launchCount"] is JsonNode a && a.GetValueKind() == JsonValueKind.Number) stats.LaunchCount = a.GetValue<int>();
            if (obj["serverStarts"] is JsonNode b && b.GetValueKind() == JsonValueKind.Number) stats.ServerStarts = b.GetValue<int>();
            if (obj["totalRunSeconds"] is JsonNode c && c.GetValueKind() == JsonValueKind.Number) stats.TotalRunSeconds = c.GetValue<long>();
            if (obj["lastStartTime"] is JsonNode d && d.GetValueKind() == JsonValueKind.String) stats.LastStartTime = d.GetValue<string>();
        }
        catch
        {
            // 单个字段坏了就用默认值，不影响其它字段
        }
        return stats;
    }

    /// <summary>保存统计（原子写入：先写 .tmp 再替换）。</summary>
    public bool Save()
    {
        var obj = new JsonObject
        {
            ["launchCount"] = LaunchCount,
            ["serverStarts"] = ServerStarts,
            ["totalRunSeconds"] = TotalRunSeconds,
            ["lastStartTime"] = LastStartTime is null ? null : JsonValue.Create(LastStartTime),
        };
        return Utf8Files.WriteAllTextAtomic(OrcaPaths.StatsFile, obj.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
    }

    /// <summary>记一次界面打开（托盘 / 控制台启动时调用）。</summary>
    public static void AddLaunch()
    {
        try
        {
            var s = Load();
            s.LaunchCount++;
            s.Save();
        }
        catch
        {
            // 统计失败绝不影响主功能
        }
    }

    /// <summary>记一次服务器启动（同时记下启动时刻，用于累计运行时长）。</summary>
    public static void AddServerStart()
    {
        try
        {
            var s = Load();
            s.ServerStarts++;
            s.LastStartTime = DateTime.Now.ToString("o", CultureInfo.InvariantCulture);
            s.Save();
        }
        catch
        {
            // 同上
        }
    }

    /// <summary>服务器关闭时把本次运行时长累加进总时长。</summary>
    public static void AccumulateRunTimeOnStop()
    {
        try
        {
            var s = Load();
            if (string.IsNullOrWhiteSpace(s.LastStartTime)) return;
            if (!DateTime.TryParse(s.LastStartTime, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out var start)) return;
            var secs = (long)(DateTime.Now - start).TotalSeconds;
            if (secs > 0) s.TotalRunSeconds += secs;
            s.LastStartTime = null;
            s.Save();
        }
        catch
        {
            // 同上
        }
    }

    /// <summary>把秒数格式化成 "X 小时 Y 分"（与旧版 Format-RunDuration 一致）。</summary>
    public static string FormatRunDuration(long totalSeconds)
    {
        var h = totalSeconds / 3600;
        var m = totalSeconds % 3600 / 60;
        return h > 0 ? $"{h} 小时 {m} 分" : $"{m} 分";
    }

    /// <summary>关于页显示用的一行统计文本。</summary>
    public string ToDisplayLine()
        => $"🐋 已启动 {LaunchCount} 次 · 服务器启动 {ServerStarts} 次 · 累计运行 {FormatRunDuration(TotalRunSeconds)}";
}

/// <summary>
/// 更新检查结果 ~/.dsh/update-check-state.json。
/// DSH 插件启动时写、界面读，字段与 plugin.js 保持一致。
/// </summary>
public sealed class UpdateState
{
    /// <summary>检查时间（ISO 8601）。</summary>
    public string? CheckedAt { get; set; }

    /// <summary>本地提交号。</summary>
    public string? LocalCommit { get; set; }

    /// <summary>官方提交号。</summary>
    public string? RemoteCommit { get; set; }

    /// <summary>是否有更新。</summary>
    public bool HasUpdate { get; set; }

    /// <summary>一句话摘要。</summary>
    public string? Summary { get; set; }

    /// <summary>读取上次检查结果（没有返回 null）。</summary>
    public static UpdateState? Load()
    {
        var obj = Utf8Files.ParseJsonObject(Utf8Files.ReadAllTextOrNull(OrcaPaths.UpdateStateFile));
        if (obj == null) return null;
        try
        {
            return new UpdateState
            {
                CheckedAt = obj["checkedAt"]?.GetValue<string>(),
                LocalCommit = obj["localCommit"]?.GetValue<string>(),
                RemoteCommit = obj["remoteCommit"]?.GetValue<string>(),
                HasUpdate = obj["hasUpdate"]?.GetValueKind() == JsonValueKind.True,
                Summary = obj["summary"]?.GetValue<string>(),
            };
        }
        catch
        {
            return null;
        }
    }

    /// <summary>保存检查结果（供 orca-cli 检查更新后写盘，插件与界面共享）。</summary>
    public bool Save()
    {
        var obj = new JsonObject
        {
            ["checkedAt"] = CheckedAt,
            ["localCommit"] = LocalCommit,
            ["remoteCommit"] = RemoteCommit,
            ["hasUpdate"] = HasUpdate,
            ["summary"] = Summary,
        };
        return Utf8Files.WriteAllText(OrcaPaths.UpdateStateFile, obj.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
    }

    /// <summary>取前 10 位短提交号（界面展示用）。</summary>
    public static string Short(string? commit)
    {
        if (string.IsNullOrWhiteSpace(commit)) return "—";
        return commit.Length <= 10 ? commit : commit[..10];
    }
}
