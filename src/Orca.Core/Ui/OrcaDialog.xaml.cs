using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;

namespace Orca.Core.Ui;

/// <summary>对话框类型（决定图标字符、配色与副标题）。</summary>
public enum OrcaDialogType
{
    /// <summary>询问（? 图标，用强调色）。</summary>
    Question,

    /// <summary>提示（i 图标，用强调色）。</summary>
    Info,

    /// <summary>警告（! 图标，琥珀色）。</summary>
    Warning,

    /// <summary>错误（✕ 图标，红色）。</summary>
    Error,
}

/// <summary>对话框按钮组合。</summary>
public enum OrcaDialogButtons
{
    /// <summary>只有「好的」。</summary>
    Ok,

    /// <summary>「是」/「否」。</summary>
    YesNo,
}

/// <summary>
/// Orca 自定义对话框（替代旧版 Show-OrcaDialog）。
/// 用法：OrcaDialog.Show(owner, "标题", "内容", OrcaDialogType.Question, OrcaDialogButtons.YesNo)
/// YesNo 返回 true(是)/false(否)；Ok 一律返回 true。
/// </summary>
public partial class OrcaDialog : Window
{
    private bool _result;

    private OrcaDialog()
    {
        InitializeComponent();
    }

    /// <summary>弹出对话框并等待用户选择。</summary>
    /// <param name="owner">父窗口（居中于它；可为 null）</param>
    /// <param name="title">标题</param>
    /// <param name="message">正文（自动换行，超长可滚动）</param>
    /// <param name="type">类型（决定图标与配色）</param>
    /// <param name="buttons">按钮组合</param>
    public static bool Show(
        Window? owner,
        string title,
        string message,
        OrcaDialogType type = OrcaDialogType.Info,
        OrcaDialogButtons buttons = OrcaDialogButtons.Ok)
    {
        try
        {
            var dlg = new OrcaDialog();
            dlg.Setup(title, message, type, buttons);
            if (owner != null && owner.IsVisible)
            {
                dlg.Owner = owner;
            }
            else
            {
                dlg.WindowStartupLocation = WindowStartupLocation.CenterScreen;
            }
            dlg.ShowDialog();
            return dlg._result;
        }
        catch
        {
            // 界面异常时不能把主流程卡死：当作"取消"处理
            return false;
        }
    }

    private void Setup(string title, string message, OrcaDialogType type, OrcaDialogButtons buttons)
    {
        var accent = AccentPresets.Current();

        // 类型 → 图标字符 / 配色 / 副标题（与旧版逐项一致）
        string ico, accentColor, accentDark, bg, sub;
        switch (type)
        {
            case OrcaDialogType.Question:
                ico = "?"; accentColor = accent.Accent; accentDark = accent.AccentDark; bg = accent.Bg; sub = "确认操作";
                break;
            case OrcaDialogType.Warning:
                ico = "!"; accentColor = "#F2B14B"; accentDark = "#D9942E"; bg = "#3A3222"; sub = "注意";
                break;
            case OrcaDialogType.Error:
                ico = "✕"; accentColor = "#EF7F7F"; accentDark = "#D05B5B"; bg = "#3A2626"; sub = "错误";
                break;
            default:
                ico = "i"; accentColor = accent.Accent; accentDark = accent.AccentDark; bg = accent.Bg; sub = "提示";
                break;
        }

        Title = title;
        dlgTitle.Text = title;
        dlgSub.Text = sub;
        dlgMsg.Text = message;
        dlgIco.Text = ico;
        dlgIco.Foreground = ThemeApplier.CreateBrush(accentColor);
        iconCircle.Background = ThemeApplier.CreateBrush(bg);

        // 顶部品牌线条：强调色 → 预设第二段色
        topLine.Background = ThemeApplier.CreateGradient(accentColor, accent.Line2, horizontal: true);

        // 主按钮渐变
        btnYes.Background = ThemeApplier.CreateGradient(accentColor, accentDark);

        // 品牌行虎鲸 logo
        var logo = IconLoader.LoadImage();
        if (logo != null) dlgLogo.Source = logo;

        if (buttons == OrcaDialogButtons.Ok)
        {
            btnNo.Visibility = Visibility.Collapsed;
            btnYes.Content = "好的";
            btnYes.IsDefault = true;
            KeyDown += (_, e) =>
            {
                if (e.Key == Key.Escape)
                {
                    _result = false;
                    Close();
                }
            };
        }
        else
        {
            btnYes.Content = "是";
            btnNo.Content = "否";
            btnYes.IsDefault = true;   // 回车 = 是
            btnNo.IsCancel = true;     // Esc = 否
        }

        btnYes.Click += (_, _) => { _result = true; Close(); };
        btnNo.Click += (_, _) => { _result = false; Close(); };

        // 淡入动效
        Loaded += (_, _) =>
        {
            try
            {
                dlgRoot.Opacity = 0;
                var anim = new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(180));
                dlgRoot.BeginAnimation(OpacityProperty, anim);
            }
            catch
            {
                dlgRoot.Opacity = 1;
            }
        };
    }
}
