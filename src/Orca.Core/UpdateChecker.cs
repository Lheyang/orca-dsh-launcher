using System.Globalization;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text.Json;

namespace Orca.Core;

/// <summary>一次更新检查的结果。</summary>
public sealed class UpdateCheckResult
{
    /// <summary>本地和网络都读到了才为 true。</summary>
    public bool Ok { get; init; }

    /// <summary>是否有新版本。</summary>
    public bool HasUpdate { get; init; }

    /// <summary>本地提交号。</summary>
    public string? LocalCommit { get; init; }

    /// <summary>官方提交号。</summary>
    public string? RemoteCommit { get; init; }

    /// <summary>失败原因。</summary>
    public string? Error { get; init; }

    /// <summary>本地短号。</summary>
    public string LocalShort => UpdateState.Short(LocalCommit);

    /// <summary>官方短号。</summary>
    public string RemoteShort => UpdateState.Short(RemoteCommit);
}

/// <summary>
/// 更新检查（对应旧版 Invoke-UpdateCheck / Get-UpdateDetails 与 plugin.js 的 checkUpdate）。
/// 只查询、只提醒，绝不自动更新，绝不改动 DSH 源码 —— 项目铁律，此处原样保留。
/// </summary>
public static class UpdateChecker
{
    private static readonly HttpClient Http = CreateHttpClient();

    private static HttpClient CreateHttpClient()
    {
        var client = new HttpClient { Timeout = TimeSpan.FromSeconds(8) };
        client.DefaultRequestHeaders.UserAgent.Add(new ProductInfoHeaderValue("orca-dsh-launcher", AppInfo.Version));
        client.DefaultRequestHeaders.Accept.Add(new MediaTypeWithQualityHeaderValue("application/vnd.github+json"));
        return client;
    }

    /// <summary>读本地 DSH 当前提交号（读不到返回 null）。</summary>
    public static string? GetLocalCommit(OrcaConfig cfg)
    {
        var r = ProcessRunner.Run("git", new[] { "-C", cfg.DshDir, "rev-parse", "HEAD" }, cfg.CheckTimeoutMs);
        if (!r.Ok) return null;
        var s = r.StdOut.Trim();
        return string.IsNullOrWhiteSpace(s) ? null : s;
    }

    /// <summary>查 GitHub 官方最新提交号（git ls-remote 只读查询，读不到返回 null）。</summary>
    public static string? GetRemoteCommit(OrcaConfig cfg)
    {
        var url = $"https://github.com/{cfg.Repo}.git";
        var r = ProcessRunner.Run("git", new[] { "ls-remote", url, $"refs/heads/{cfg.Branch}" }, cfg.CheckTimeoutMs);
        if (!r.Ok) return null;
        var first = r.StdOut.Split('\n').Select(x => x.Trim()).FirstOrDefault(x => x.Length > 0);
        if (string.IsNullOrWhiteSpace(first)) return null;
        var sha = first.Split(new[] { ' ', '\t' }, StringSplitOptions.RemoveEmptyEntries).FirstOrDefault();
        return string.IsNullOrWhiteSpace(sha) ? null : sha;
    }

    /// <summary>执行一次更新检查（不写盘）。</summary>
    public static UpdateCheckResult Check(OrcaConfig cfg)
    {
        var local = GetLocalCommit(cfg);
        var remote = GetRemoteCommit(cfg);
        if (local == null || remote == null)
        {
            return new UpdateCheckResult
            {
                Ok = false,
                LocalCommit = local,
                RemoteCommit = remote,
                Error = "本地或网络不可用",
            };
        }
        return new UpdateCheckResult
        {
            Ok = true,
            HasUpdate = !string.Equals(local, remote, StringComparison.OrdinalIgnoreCase),
            LocalCommit = local,
            RemoteCommit = remote,
        };
    }

    /// <summary>
    /// 执行一次检查并把结果写进 ~/.dsh/update-check-state.json
    /// （与 plugin.js 写的格式完全一致，界面和命令共享同一份结果）。
    /// </summary>
    public static UpdateCheckResult CheckAndSave(OrcaConfig cfg)
    {
        var result = Check(cfg);
        if (!result.Ok) return result;

        var state = new UpdateState
        {
            CheckedAt = DateTime.Now.ToString("o", CultureInfo.InvariantCulture),
            LocalCommit = result.LocalCommit,
            RemoteCommit = result.RemoteCommit,
            HasUpdate = result.HasUpdate,
            Summary = result.HasUpdate ? "官方发布了新版本，快去看看吧！" : "当前已是最新版本",
        };
        state.Save();
        return result;
    }

    /// <summary>
    /// 拉官方最近几条提交的标题（用于展示"更新了什么"）。
    /// 网络不通就安静返回 null，调用方降级显示。
    /// </summary>
    public static string[]? GetUpdateDetails(OrcaConfig cfg, int count = 5)
    {
        try
        {
            var url = $"https://api.github.com/repos/{cfg.Repo}/commits?sha={cfg.Branch}&per_page={count}";
            using var response = Http.GetAsync(url).GetAwaiter().GetResult();
            if (!response.IsSuccessStatusCode) return null;
            var json = response.Content.ReadAsStringAsync().GetAwaiter().GetResult();

            using var doc = JsonDocument.Parse(json);
            if (doc.RootElement.ValueKind != JsonValueKind.Array) return null;

            var titles = new List<string>();
            foreach (var item in doc.RootElement.EnumerateArray())
            {
                if (!item.TryGetProperty("commit", out var commit)) continue;
                if (!commit.TryGetProperty("message", out var msgNode)) continue;
                var msg = msgNode.GetString() ?? string.Empty;
                var firstLine = msg.Replace("\r\n", "\n").Split('\n').Select(l => l.Trim()).FirstOrDefault(l => l.Length > 0);
                if (!string.IsNullOrWhiteSpace(firstLine)) titles.Add(firstLine!);
            }
            return titles.Count == 0 ? null : titles.ToArray();
        }
        catch
        {
            return null;
        }
    }
}
