namespace Orca.Core;

/// <summary>一套强调色预设（对话框与界面配色跟随它）。</summary>
public sealed class AccentPreset
{
    /// <summary>预设键名（green / blue / …）。</summary>
    public string Key { get; init; } = "blue";

    /// <summary>中文名（设置页悬停提示）。</summary>
    public string Name { get; init; } = "科技蓝";

    /// <summary>主强调色。</summary>
    public string Accent { get; init; } = "#5B9BFF";

    /// <summary>渐变深色端。</summary>
    public string AccentDark { get; init; } = "#3B74E8";

    /// <summary>图标底色。</summary>
    public string Bg { get; init; } = "#1B3A66";

    /// <summary>顶部品牌线条第二段颜色。</summary>
    public string Line2 { get; init; } = "#27405E";
}

/// <summary>
/// 6 种强调色预设（与旧版 orca-install.ps1 的 $script:OrcaAccentPresets 完全一致）。
/// </summary>
public static class AccentPresets
{
    /// <summary>全部预设，按设置页展示顺序。</summary>
    public static readonly AccentPreset[] All =
    {
        new() { Key = "green",  Name = "经典青绿", Accent = "#3ED6A3", AccentDark = "#2BBF87", Bg = "#1C3A2E", Line2 = "#2E4B3F" },
        new() { Key = "blue",   Name = "科技蓝",   Accent = "#5B9BFF", AccentDark = "#3B74E8", Bg = "#1B3A66", Line2 = "#27405E" },
        new() { Key = "purple", Name = "蓝紫渐变", Accent = "#8B7CF6", AccentDark = "#6A5AE0", Bg = "#2A2A5E", Line2 = "#3A3570" },
        new() { Key = "amber",  Name = "琥珀暖橙", Accent = "#F2B14B", AccentDark = "#D9942E", Bg = "#3A3222", Line2 = "#4A3A22" },
        new() { Key = "rose",   Name = "玫红",     Accent = "#F27DA8", AccentDark = "#D95F8E", Bg = "#3A2440", Line2 = "#4A2A45" },
        new() { Key = "slate",  Name = "银灰蓝",   Accent = "#9AA7BC", AccentDark = "#7C8AA3", Bg = "#2A3240", Line2 = "#35404F" },
    };

    /// <summary>按键名取预设（未知键名退回科技蓝）。</summary>
    public static AccentPreset Get(string? key)
    {
        if (!string.IsNullOrWhiteSpace(key))
        {
            var hit = All.FirstOrDefault(a => string.Equals(a.Key, key, StringComparison.OrdinalIgnoreCase));
            if (hit != null) return hit;
        }
        return All.First(a => a.Key == "blue");
    }

    /// <summary>读当前配置里的强调色预设。</summary>
    public static AccentPreset Current() => Get(OrcaConfig.Load().Accent);
}

/// <summary>
/// 深色 / 浅色主题色表（与旧版 Apply-Theme 的两套颜色逐项一致）。
/// 控制台窗口把这些键写进 WPF 资源字典，切换主题即时生效。
/// </summary>
public static class ThemePalette
{
    /// <summary>深色主题（默认）。</summary>
    public static readonly Dictionary<string, string> Dark = new()
    {
        ["ColorBg"] = "#101010",
        ["ColorBorder"] = "#2A2A2A",
        ["ColorSidebar"] = "#1A1A1A",
        ["ColorCard"] = "#1E1E1E",
        ["ColorInput"] = "#1E1E1E",
        ["ColorInputBorder"] = "#3A3A3A",
        ["ColorTextPrimary"] = "#F0F0F0",
        ["ColorTextSecondary"] = "#9A9A9A",
        ["ColorTextMuted"] = "#888888",
        ["ColorBtnPrimaryBg"] = "#F0F0F0",
        ["ColorBtnPrimaryFg"] = "#101010",
        ["ColorBtnPrimaryHover"] = "#FFFFFF",
        ["ColorBtnPrimaryPressed"] = "#D8D8D8",
        ["ColorBtnSecondaryBg"] = "#2D2D2D",
        ["ColorBtnSecondaryFg"] = "#E0E0E0",
        ["ColorBtnSecondaryHover"] = "#3A3A3A",
        ["ColorBtnSecondaryPressed"] = "#262626",
        ["ColorBtnDisabledBg"] = "#1E1E1E",
        ["ColorBtnDisabledFg"] = "#555555",
        ["ColorNavSelectedBg"] = "#2D2D2D",
        ["ColorNavHover"] = "#2A2A2A",
        ["ColorWindowBtnFg"] = "#9AA0B5",
        ["ColorWindowBtnHoverBg"] = "#2A2A2A",
        ["ColorDangerText"] = "#E07A7A",
        ["ColorDangerHoverBg"] = "#3A2626",
        ["ColorTagOkBg"] = "#1C3A2E",
        ["ColorTagOkFg"] = "#36D199",
        ["ColorTagWarnBg"] = "#3A3222",
        ["ColorTagWarnFg"] = "#E8B34A",
        ["ColorTagNeutralBg"] = "#2D2D2D",
        ["ColorTagNeutralFg"] = "#9A9A9A",
    };

    /// <summary>浅色主题。</summary>
    public static readonly Dictionary<string, string> Light = new()
    {
        ["ColorBg"] = "#F5F5F7",
        ["ColorBorder"] = "#D9D9DE",
        ["ColorSidebar"] = "#ECECEF",
        ["ColorCard"] = "#FFFFFF",
        ["ColorInput"] = "#FFFFFF",
        ["ColorInputBorder"] = "#C8C8CE",
        ["ColorTextPrimary"] = "#1A1A1E",
        ["ColorTextSecondary"] = "#6E6E76",
        ["ColorTextMuted"] = "#8E8E96",
        ["ColorBtnPrimaryBg"] = "#1A1A1E",
        ["ColorBtnPrimaryFg"] = "#FFFFFF",
        ["ColorBtnPrimaryHover"] = "#333338",
        ["ColorBtnPrimaryPressed"] = "#000000",
        ["ColorBtnSecondaryBg"] = "#E2E2E6",
        ["ColorBtnSecondaryFg"] = "#2A2A2E",
        ["ColorBtnSecondaryHover"] = "#D2D2D8",
        ["ColorBtnSecondaryPressed"] = "#C8C8CE",
        ["ColorBtnDisabledBg"] = "#E9E9EC",
        ["ColorBtnDisabledFg"] = "#A0A0A8",
        ["ColorNavSelectedBg"] = "#D0D0D6",
        ["ColorNavHover"] = "#DCDCE2",
        ["ColorWindowBtnFg"] = "#5A5A62",
        ["ColorWindowBtnHoverBg"] = "#DCDCE2",
        ["ColorDangerText"] = "#C43C3C",
        ["ColorDangerHoverBg"] = "#F3DEDE",
        ["ColorTagOkBg"] = "#DDF3E8",
        ["ColorTagOkFg"] = "#1E8A52",
        ["ColorTagWarnBg"] = "#FBF0DC",
        ["ColorTagWarnFg"] = "#B07A1E",
        ["ColorTagNeutralBg"] = "#E9E9EC",
        ["ColorTagNeutralFg"] = "#6E6E76",
    };

    /// <summary>按是否深色取一整套颜色。</summary>
    public static Dictionary<string, string> For(bool isDark) => isDark ? Dark : Light;
}
