using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Orca.Core;

/// <summary>一次操作的结果（成功 / 失败 + 原因），界面直接拿 Error 显示给用户。</summary>
public sealed class OpResult
{
    /// <summary>是否成功。</summary>
    public bool Ok { get; init; }

    /// <summary>失败原因（成功时为 null）。</summary>
    public string? Error { get; init; }

    /// <summary>附加输出（git pull 输出等）。</summary>
    public string? Output { get; init; }

    /// <summary>本次是否触发了重新构建。</summary>
    public bool Rebuilt { get; init; }

    /// <summary>构造成功结果。</summary>
    public static OpResult Success(string? output = null, bool rebuilt = false)
        => new() { Ok = true, Output = output, Rebuilt = rebuilt };

    /// <summary>构造失败结果。</summary>
    public static OpResult Fail(string error, string? output = null)
        => new() { Ok = false, Error = error, Output = output };
}

/// <summary>
/// DSH 构建检查（对应旧版 Ensure-DshBuilt）。
/// DSH 仓库是源码 checkout，git pull 后不重新构建会缺关键产物导致启动失败，
/// 所以"启动服务器"和"更新 DSH"两条路径都先过这里。
/// </summary>
public static class DshBuild
{
    /// <summary>6 个关键构建产物（缺任何一个都要重新构建）。</summary>
    public static readonly string[] KeyArtifacts =
    {
        @"packages\context\session-reference\lib\typert.host.js",
        @"packages\context\session-reference\lib\typert.remote-client.js",
        @"packages\client\ui-renderer\lib\client.js",
        @"packages\client\ui-brand-official\lib\client.js",
        @"packages\client\ui-attachment\lib\client.js",
        @"packages\client\ui-reference\lib\client.js",
    };

    /// <summary>构建超时：10 分钟。</summary>
    public const int BuildTimeoutMs = 10 * 60 * 1000;

    /// <summary>读本地 DSH 当前提交号（读不到返回 null）。</summary>
    public static string? GetHead(string dshDir)
    {
        if (string.IsNullOrWhiteSpace(dshDir) || !Directory.Exists(dshDir)) return null;
        var r = ProcessRunner.Run("git", new[] { "-C", dshDir, "rev-parse", "HEAD" }, 10000);
        if (!r.Ok) return null;
        var head = r.StdOut.Trim();
        return string.IsNullOrWhiteSpace(head) ? null : head;
    }

    /// <summary>读上次成功构建的提交号（缓存文件，读不到返回 null）。</summary>
    public static string? GetLastBuiltCommit()
    {
        var obj = Utf8Files.ParseJsonObject(Utf8Files.ReadAllTextOrNull(OrcaPaths.BuildCacheFile));
        try
        {
            return obj?["commit"]?.GetValue<string>();
        }
        catch
        {
            return null;
        }
    }

    /// <summary>写回本次成功构建的提交号。</summary>
    public static bool SetLastBuiltCommit(string commit)
    {
        var obj = new JsonObject
        {
            ["commit"] = commit,
            ["builtAt"] = DateTime.Now.ToString("o", CultureInfo.InvariantCulture),
        };
        return Utf8Files.WriteAllText(OrcaPaths.BuildCacheFile, obj.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
    }

    /// <summary>6 个关键构建产物是否齐全。</summary>
    public static bool ArtifactsPresent(string dshDir)
    {
        foreach (var rel in KeyArtifacts)
        {
            var path = Path.Combine(dshDir, rel);
            if (!File.Exists(path)) return false;
        }
        return true;
    }

    /// <summary>执行构建（pnpm run build，隐藏窗口，输出进构建日志，10 分钟超时）。</summary>
    public static OpResult RunBuild(string dshDir)
    {
        try
        {
            var proc = ProcessRunner.StartHiddenCmdToLog("pnpm.cmd run build", OrcaPaths.BuildLogFile, dshDir);
            if (proc == null) return OpResult.Fail("无法启动构建进程（pnpm 是否已安装？）");

            using (proc)
            {
                if (!proc.WaitForExit(BuildTimeoutMs))
                {
                    ProcessRunner.TryKillTree(proc);
                    return OpResult.Fail("DSH 构建超时（超过 10 分钟），已取消");
                }
                if (proc.ExitCode != 0)
                {
                    return OpResult.Fail("DSH 构建失败，详情见 " + OrcaPaths.BuildLogFile);
                }
            }
            return OpResult.Success();
        }
        catch (Exception ex)
        {
            return OpResult.Fail("构建执行出错：" + ex.Message);
        }
    }

    /// <summary>
    /// 构建检查 + 必要时构建。
    /// HEAD 变化或关键产物缺失 → 先构建，成功才放行并写回缓存。
    /// 返回 Ok=false 时不要启动服务器。
    /// </summary>
    public static OpResult EnsureBuilt(string dshDir)
    {
        var head = GetHead(dshDir);
        if (head == null)
        {
            return OpResult.Fail("无法读取 DSH 提交号（目录不是 git 仓库？）");
        }

        var last = GetLastBuiltCommit();
        bool need = string.IsNullOrEmpty(last) || last != head || !ArtifactsPresent(dshDir);
        if (!need) return OpResult.Success();

        var r = RunBuild(dshDir);
        if (!r.Ok) return r;

        SetLastBuiltCommit(head);
        return OpResult.Success(rebuilt: true);
    }
}
