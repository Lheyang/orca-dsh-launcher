using System.Drawing;
using System.Windows.Media.Imaging;

namespace Orca.Core.Ui;

/// <summary>
/// 图标加载（虎鲸 ico 多尺寸帧）。
/// WPF 窗口用 BitmapSource（保留透明通道），托盘用 System.Drawing.Icon。
/// ico 缺失时退回画一个蓝底白 D，保证界面永远有图标（与旧版兜底逻辑一致）。
/// </summary>
public static class IconLoader
{
    private static BitmapSource? _cachedImage;

    /// <summary>取虎鲸图标的 WPF 图像（优先 48px 帧；失败返回 null）。</summary>
    public static BitmapSource? LoadImage(string? icoPath = null)
    {
        if (_cachedImage != null && icoPath == null) return _cachedImage;

        var path = icoPath ?? AppInfo.TrayIconPath;
        if (path == null || !File.Exists(path)) return null;

        try
        {
            using var fs = File.OpenRead(path);
            var decoder = new IconBitmapDecoder(
                fs,
                BitmapCreateOptions.PreservePixelFormat,
                BitmapCacheOption.OnLoad);

            // 优先 <=48px 里最大的一帧（任务栏清晰又不过大），没有就取最大帧
            var frame = decoder.Frames
                .Where(f => f.PixelWidth <= 48)
                .OrderByDescending(f => f.PixelWidth)
                .FirstOrDefault() ?? decoder.Frames.OrderByDescending(f => f.PixelWidth).FirstOrDefault();

            if (frame == null) return null;
            frame.Freeze();
            if (icoPath == null) _cachedImage = frame;
            return frame;
        }
        catch
        {
            return null;
        }
    }

    /// <summary>取托盘用的 Icon（ico 缺失时画一个蓝底白 D 兜底）。</summary>
    public static Icon LoadTrayIcon(string? icoPath = null)
    {
        var path = icoPath ?? AppInfo.TrayIconPath;
        if (path != null && File.Exists(path))
        {
            try
            {
                return new Icon(path);
            }
            catch
            {
                // 文件坏了 → 走兜底
            }
        }
        return CreateFallbackIcon();
    }

    /// <summary>取指定尺寸的 Icon（设置窗口类图标用）。</summary>
    public static Icon? LoadIconSized(int size)
    {
        var path = AppInfo.TrayIconPath;
        if (path == null || !File.Exists(path)) return null;
        try
        {
            return new Icon(path, size, size);
        }
        catch
        {
            return null;
        }
    }

    private static Icon CreateFallbackIcon()
    {
        using var bmp = new Bitmap(16, 16);
        using (var g = Graphics.FromImage(bmp))
        {
            g.Clear(Color.Transparent);
            g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
            using var brush = new SolidBrush(Color.DodgerBlue);
            g.FillEllipse(brush, 0, 0, 15, 15);
            using var font = new Font("Arial", 9, FontStyle.Bold);
            g.DrawString("D", font, Brushes.White, 4, 2);
        }
        // 从位图句柄创建 Icon 后立刻复制一份，避免句柄随位图释放而失效
        var handle = bmp.GetHicon();
        using var temp = Icon.FromHandle(handle);
        return (Icon)temp.Clone();
    }
}
