using System.Windows;
using System.Windows.Media;

namespace Orca.Core.Ui;

/// <summary>
/// 主题应用（替代旧版 Apply-Theme）。
/// 把颜色写进窗口的资源字典，界面里所有 DynamicResource 立即跟着变。
/// </summary>
public static class ThemeApplier
{
    /// <summary>把一整套主题 + 强调色应用到窗口。</summary>
    public static void Apply(Window window, bool isDark, AccentPreset? accent = null)
    {
        var palette = ThemePalette.For(isDark);
        foreach (var kv in palette)
        {
            SetBrush(window, kv.Key, kv.Value);
        }
        var acc = accent ?? AccentPresets.Current();
        SetBrush(window, "ColorAccent", acc.Accent);
    }

    /// <summary>写入/替换一个颜色资源（Remove + Add，避免 DynamicResource 报 invalid value）。</summary>
    public static void SetBrush(Window window, string key, string hex)
    {
        try
        {
            var brush = CreateBrush(hex);
            if (window.Resources.Contains(key)) window.Resources.Remove(key);
            window.Resources.Add(key, brush);
        }
        catch
        {
            // 单个颜色失败不影响其它颜色
        }
    }

    /// <summary>由 #RRGGBB 造一个已冻结的画刷（冻结后渲染更快）。</summary>
    public static SolidColorBrush CreateBrush(string hex)
    {
        var color = (Color)ColorConverter.ConvertFromString(hex);
        var brush = new SolidColorBrush(color);
        brush.Freeze();
        return brush;
    }

    /// <summary>造一个两段渐变画刷（对话框按钮 / 品牌线条用）。</summary>
    public static LinearGradientBrush CreateGradient(string fromHex, string toHex, bool horizontal = false)
    {
        var brush = new LinearGradientBrush
        {
            StartPoint = new System.Windows.Point(0, 0),
            EndPoint = horizontal ? new System.Windows.Point(1, 0) : new System.Windows.Point(0, 1),
        };
        brush.GradientStops.Add(new GradientStop((Color)ColorConverter.ConvertFromString(fromHex), 0));
        brush.GradientStops.Add(new GradientStop((Color)ColorConverter.ConvertFromString(toHex), 1));
        brush.Freeze();
        return brush;
    }

    /// <summary>取窗口资源里的画刷（取不到返回透明）。</summary>
    public static Brush GetBrush(Window window, string key)
    {
        try
        {
            if (window.Resources[key] is Brush b) return b;
        }
        catch
        {
            // 忽略
        }
        return Brushes.Transparent;
    }
}
