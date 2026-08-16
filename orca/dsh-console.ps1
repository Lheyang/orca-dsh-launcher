# ============================================================
#  Orca DSH Launcher - 控制台（独立管理窗口 · WPF 导航式界面）
# ============================================================
#  双击桌面图标「Orca DSH Launcher」打开本窗口：
#    - 左侧导航：概览 / 服务器 / 安装 / 日志 / 设置 / 关于
#    - 概览页：健康检查式状态卡片（服务器 / 更新 / 托盘）
#    - 服务器页：启动 / 关闭 / 重启 + 状态信息 + 端口占用检测
#    - 安装页：一键安装完整版 DSH / 启动官方 Web 版 / 打开官网
#    - 日志页：实时查看 DSH 运行日志
#    - 设置页：端口 / DSH 目录 / 自启开关 / 主题（深色/浅色）
#  深色主题（仿 Codex++ 风格）；支持浅色主题切换（设置页）
#  窗口是独立软件界面（WPF，Windows 自带框架），不依赖浏览器；
#  DSH 没启动也能打开。
#
#  公共逻辑在 orca-common.ps1（启停/状态）+ orca-install.ps1（安装），
#  本文件只管界面。
#  参数：-QuickCheck 只输出状态 JSON 后退出（供测试/自检用）
#  注意：本文件必须保存为 UTF-8 带 BOM（PowerShell 5.1 才能
#        正确解析中文）。
# ============================================================
$ErrorActionPreference = 'Continue'

# 加载公共逻辑库（配置、服务器启停、更新检查、窗口辅助、图标）
. (Join-Path $PSScriptRoot 'orca-common.ps1')
Initialize-OrcaCommon

# 加载安装核心逻辑库（环境/网络检测、git clone、pnpm install+build、
# npx web 启动、装插件）——「安装」页与独立安装向导共用同一份
. (Join-Path $PSScriptRoot 'orca-install.ps1')

# ---------- 自检模式：不弹窗口，输出状态后退出 ----------
if ($args -contains '-QuickCheck') {
    try {
        $result = Invoke-UpdateCheck
        $state = [pscustomobject]@{
            ok            = $true
            serverRunning = Test-ServerRunning
            trayRunning   = Test-TrayRunning
            portStatus    = Get-PortStatus
            port          = $script:orcaCfgPort
            dshDir        = $script:orcaCfgDshDir
            trayAutoStart = $script:orcaCfgTrayAutoStart
            theme         = $script:orcaCfgTheme
            dshAutoStart  = Test-DshAutoStart
            dshInstalled  = Test-DshInstalled -DshDir $script:orcaCfgDshDir
            updateOk      = $result.ok
            hasUpdate     = $result.hasUpdate
            localCommit   = $result.localCommit
            remoteCommit  = $result.remoteCommit
        }
        $state | ConvertTo-Json
    } catch {
        [pscustomobject]@{ ok = $false; error = $_.Exception.Message } | ConvertTo-Json
        exit 1
    }
    exit 0
}

# 防止重复实例（控制台只开一个）
$mutex = New-Object System.Threading.Mutex($false, 'Local\DSH-Console-Single')
if (-not $mutex.WaitOne(0, $false)) {
    [System.Windows.MessageBox]::Show('控制台已经打开了，先看看托盘或任务栏。', 'Orca DSH Launcher')
    exit
}

# ---------- 任务栏图标：给进程设 AppUserModelID（powershell 是控制台程序，
# ---------- 任务栏按钮默认用 exe 图标，设 AppID + 注册表图标后任务栏显示虎鲸）
Add-Type -TypeDefinition 'using System;using System.Runtime.InteropServices;public static class AppIdWin {
  [DllImport("shell32.dll")] public static extern int SetCurrentProcessExplicitAppUserModelID([MarshalAs(UnmanagedType.LPWStr)] string AppID);
}' -ErrorAction SilentlyContinue
$script:orcaAppId = 'Orca.DSH.Launcher'
try {
    $appIco = Join-Path $PSScriptRoot 'dsh-tray.ico'
    $regPath = "HKCU:\Software\Classes\AppUserModelId\$($script:orcaAppId)"
    if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }
    if (Test-Path $appIco) {
        Set-ItemProperty -Path $regPath -Name 'DefaultIcon' -Value "`"$appIco`,0" -Force
    }
    [AppIdWin]::SetCurrentProcessExplicitAppUserModelID($script:orcaAppId)
} catch {}

# ---------- 加载 WPF（Windows 自带，无需安装） ----------
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
# 窗口图标强设（无边框窗口 WPF 不应用 Icon，需 SetClassLong 改窗口类图标）
Add-Type -TypeDefinition 'using System;using System.Runtime.InteropServices;public static class IconWin32 {
  [DllImport("user32.dll", EntryPoint="SetClassLongPtr")] public static extern IntPtr SetClassLongPtr64(IntPtr hWnd, int nIndex, IntPtr dwNewLong);
  [DllImport("user32.dll", EntryPoint="SetClassLong")] public static extern int SetClassLong32(IntPtr hWnd, int nIndex, int dwNewLong);
}' -ErrorAction SilentlyContinue
# ---------- 界面状态（事件间共享） ----------
$script:lastCheck = $null        # 最近一次手动检查结果（含更新详情）
$script:lastDetails = $null      # 最近拉到的官方 commit 标题
$script:pendingOpen = $false     # 服务器就绪后要自动打开浏览器
$script:pendingStart = $false    # 正在启动服务器

# ---------- 界面定义（XAML，颜色全部走资源，支持深浅主题） ----------
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        x:Name="MainWindow"
        Title="Orca DSH Launcher 控制台"
        Width="780" Height="580"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        ResizeMode="NoResize" WindowStartupLocation="CenterScreen"
        FontFamily="Microsoft YaHei UI">
  <Window.Resources>
    <!-- ═══ 颜色资源（Apply-Theme 切换深/浅） ═══ -->
    <SolidColorBrush x:Key="ColorBg" Color="#101010"/>
    <SolidColorBrush x:Key="ColorBorder" Color="#2A2A2A"/>
    <SolidColorBrush x:Key="ColorSidebar" Color="#1A1A1A"/>
    <SolidColorBrush x:Key="ColorCard" Color="#1E1E1E"/>
    <SolidColorBrush x:Key="ColorInput" Color="#1E1E1E"/>
    <SolidColorBrush x:Key="ColorInputBorder" Color="#3A3A3A"/>
    <SolidColorBrush x:Key="ColorTextPrimary" Color="#F0F0F0"/>
    <SolidColorBrush x:Key="ColorTextSecondary" Color="#9A9A9A"/>
    <SolidColorBrush x:Key="ColorTextMuted" Color="#888888"/>
    <SolidColorBrush x:Key="ColorAccent" Color="#36D199"/>
    <SolidColorBrush x:Key="ColorBtnPrimaryBg" Color="#F0F0F0"/>
    <SolidColorBrush x:Key="ColorBtnPrimaryFg" Color="#101010"/>
    <SolidColorBrush x:Key="ColorBtnPrimaryHover" Color="#FFFFFF"/>
    <SolidColorBrush x:Key="ColorBtnPrimaryPressed" Color="#D8D8D8"/>
    <SolidColorBrush x:Key="ColorBtnSecondaryBg" Color="#2D2D2D"/>
    <SolidColorBrush x:Key="ColorBtnSecondaryFg" Color="#E0E0E0"/>
    <SolidColorBrush x:Key="ColorBtnSecondaryHover" Color="#3A3A3A"/>
    <SolidColorBrush x:Key="ColorBtnSecondaryPressed" Color="#262626"/>
    <SolidColorBrush x:Key="ColorBtnDisabledBg" Color="#1E1E1E"/>
    <SolidColorBrush x:Key="ColorBtnDisabledFg" Color="#555555"/>
    <SolidColorBrush x:Key="ColorNavSelectedBg" Color="#2D2D2D"/>
    <SolidColorBrush x:Key="ColorNavHover" Color="#2A2A2A"/>
    <SolidColorBrush x:Key="ColorWindowBtnFg" Color="#9AA0B5"/>
    <SolidColorBrush x:Key="ColorWindowBtnHoverBg" Color="#2A2A2A"/>
    <SolidColorBrush x:Key="ColorDangerText" Color="#E07A7A"/>
    <SolidColorBrush x:Key="ColorDangerHoverBg" Color="#3A2626"/>
    <SolidColorBrush x:Key="ColorTagOkBg" Color="#1C3A2E"/>
    <SolidColorBrush x:Key="ColorTagOkFg" Color="#36D199"/>
    <SolidColorBrush x:Key="ColorTagWarnBg" Color="#3A3222"/>
    <SolidColorBrush x:Key="ColorTagWarnFg" Color="#E8B34A"/>
    <SolidColorBrush x:Key="ColorTagNeutralBg" Color="#2D2D2D"/>
    <SolidColorBrush x:Key="ColorTagNeutralFg" Color="#9A9A9A"/>

    <!-- 主按钮：白底黑字（高对比） -->
    <Style x:Key="PrimaryButton" TargetType="Button">
      <Setter Property="Background" Value="{DynamicResource ColorBtnPrimaryBg}"/>
      <Setter Property="Foreground" Value="{DynamicResource ColorBtnPrimaryFg}"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="6">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="{DynamicResource ColorBtnPrimaryHover}"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="bd" Property="Background" Value="{DynamicResource ColorBtnPrimaryPressed}"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="bd" Property="Background" Value="{DynamicResource ColorBtnDisabledBg}"/>
                <Setter Property="Foreground" Value="{DynamicResource ColorBtnDisabledFg}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <!-- 次要按钮：深灰底浅字 -->
    <Style x:Key="SecondaryButton" TargetType="Button">
      <Setter Property="Background" Value="{DynamicResource ColorBtnSecondaryBg}"/>
      <Setter Property="Foreground" Value="{DynamicResource ColorBtnSecondaryFg}"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="6">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="{DynamicResource ColorBtnSecondaryHover}"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="bd" Property="Background" Value="{DynamicResource ColorBtnSecondaryPressed}"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="bd" Property="Background" Value="{DynamicResource ColorBtnDisabledBg}"/>
                <Setter Property="Foreground" Value="{DynamicResource ColorBtnDisabledFg}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <!-- 危险按钮：淡红字（关闭服务器） -->
    <Style x:Key="DangerButton" TargetType="Button" BasedOn="{StaticResource SecondaryButton}">
      <Setter Property="Foreground" Value="{DynamicResource ColorDangerText}"/>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter Property="Background" Value="{DynamicResource ColorDangerHoverBg}"/>
        </Trigger>
      </Style.Triggers>
    </Style>
    <!-- 导航按钮 -->
    <Style x:Key="NavButton" TargetType="Button">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="{DynamicResource ColorTextSecondary}"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Height" Value="38"/>
      <Setter Property="Margin" Value="8,2"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="HorizontalContentAlignment" Value="Left"/>
      <Setter Property="Padding" Value="14,0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="6">
              <ContentPresenter Margin="{TemplateBinding Padding}" HorizontalAlignment="Left" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="{DynamicResource ColorNavHover}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <!-- 标题栏按钮 -->
    <Style x:Key="WindowButton" TargetType="Button">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="{DynamicResource ColorWindowBtnFg}"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="6">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="{DynamicResource ColorWindowBtnHoverBg}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <!-- 文本框：聚焦时青绿边框 -->
    <Style x:Key="ModernTextBox" TargetType="TextBox">
      <Setter Property="Background" Value="{DynamicResource ColorInput}"/>
      <Setter Property="Foreground" Value="{DynamicResource ColorTextPrimary}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource ColorInputBorder}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="8,5"/>
      <Setter Property="CaretBrush" Value="{DynamicResource ColorAccent}"/>
      <Style.Triggers>
        <Trigger Property="IsKeyboardFocused" Value="True">
          <Setter Property="BorderBrush" Value="{DynamicResource ColorAccent}"/>
          <Setter Property="BorderThickness" Value="1.5"/>
        </Trigger>
      </Style.Triggers>
    </Style>
    <!-- 状态标签（胶囊） -->
    <Style x:Key="StatusTag" TargetType="Border">
      <Setter Property="CornerRadius" Value="10"/>
      <Setter Property="Padding" Value="10,3"/>
      <Setter Property="Background" Value="{DynamicResource ColorTagNeutralBg}"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>
  </Window.Resources>

  <!-- 外层圆角主容器 -->
  <Border x:Name="Root" CornerRadius="8" Background="{DynamicResource ColorBg}" BorderThickness="1" BorderBrush="{DynamicResource ColorBorder}">
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="44"/>
        <RowDefinition Height="*"/>
      </Grid.RowDefinitions>

      <!-- ═══ 顶部标题栏（可拖动） ═══ -->
      <Grid x:Name="titleBar" Grid.Row="0" Background="Transparent">
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center" Margin="16,0,0,0">
          <Image x:Name="imgLogo" Width="22" Height="22" VerticalAlignment="Center" Stretch="Uniform"/>
          <TextBlock Text="Orca DSH Launcher" FontSize="13" FontWeight="Bold" Foreground="{DynamicResource ColorTextPrimary}" Margin="8,0,0,0" VerticalAlignment="Center"/>
        </StackPanel>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,8,0">
          <Button x:Name="btnMin" Content="—" Style="{StaticResource WindowButton}" Width="34" Height="26"/>
          <Button x:Name="btnClose" Content="✕" Style="{StaticResource WindowButton}" Width="34" Height="26" Margin="4,0,0,0"/>
        </StackPanel>
      </Grid>

      <!-- ═══ 主体：侧边栏 + 内容区 ═══ -->
      <Grid Grid.Row="1">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="190"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>

        <!-- 侧边栏 -->
        <Border Grid.Column="0" Background="{DynamicResource ColorSidebar}" BorderBrush="{DynamicResource ColorBorder}" BorderThickness="0,0,1,0">
          <Grid>
            <Grid.RowDefinitions>
              <RowDefinition Height="*"/>
              <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>
            <StackPanel Margin="0,14,0,0">
              <TextBlock Text="管理控制台" FontSize="11" Foreground="{DynamicResource ColorTextMuted}" Margin="20,0,0,8"/>
              <Button x:Name="navOverview" Style="{StaticResource NavButton}" Content="📊  概览"/>
              <Button x:Name="navServer"   Style="{StaticResource NavButton}" Content="🖥️  服务器"/>
              <Button x:Name="navInstall"  Style="{StaticResource NavButton}" Content="📦  安装"/>
              <Button x:Name="navLogs"     Style="{StaticResource NavButton}" Content="📄  日志"/>
              <Button x:Name="navSettings" Style="{StaticResource NavButton}" Content="⚙️  设置"/>
              <Button x:Name="navAbout"    Style="{StaticResource NavButton}" Content="ℹ️  关于"/>
            </StackPanel>
            <TextBlock x:Name="lblVer" Grid.Row="1" Text="v1.5.0" FontSize="11" Foreground="{DynamicResource ColorTextMuted}" Margin="20,0,0,14"/>
          </Grid>
        </Border>

        <!-- 内容区 -->
        <Grid Grid.Column="1">
          <Grid.RowDefinitions>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>

          <!-- 页面容器 -->
          <Grid Grid.Row="0" Margin="24,16,24,0">

            <!-- ═══ 概览页 ═══ -->
            <StackPanel x:Name="pageOverview" CacheMode="BitmapCache">
              <TextBlock Text="概览" FontSize="22" FontWeight="Bold" Foreground="{DynamicResource ColorTextPrimary}"/>
              <TextBlock Text="检查问题、启动与快速修复" FontSize="12" Foreground="{DynamicResource ColorTextSecondary}" Margin="0,2,0,0"/>
              <TextBlock Text="健康检查" FontSize="14" Foreground="{DynamicResource ColorTextPrimary}" Margin="0,18,0,0"/>
              <TextBlock Text="概览只展示关键状态，具体配置在设置页处理" FontSize="11" Foreground="{DynamicResource ColorTextMuted}" Margin="0,2,0,0"/>

              <StackPanel Margin="0,12,0,0">
                <!-- 卡片1：DSH 服务器 -->
                <Border CornerRadius="6" Background="{DynamicResource ColorCard}" Padding="14,12" Margin="0,0,0,8">
                  <Grid>
                    <Grid.ColumnDefinitions>
                      <ColumnDefinition Width="Auto"/>
                      <ColumnDefinition Width="*"/>
                      <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <TextBlock Text="✓" FontSize="16" Foreground="{DynamicResource ColorAccent}" VerticalAlignment="Center"/>
                    <StackPanel Grid.Column="1" Margin="10,0,0,0" VerticalAlignment="Center">
                      <TextBlock Text="DSH 服务器" FontSize="13" Foreground="{DynamicResource ColorTextPrimary}"/>
                      <TextBlock x:Name="cardServerSub" Text="http://127.0.0.1:3080" FontSize="11" Foreground="{DynamicResource ColorTextMuted}" Margin="0,2,0,0"/>
                    </StackPanel>
                    <Border Grid.Column="2" Style="{StaticResource StatusTag}">
                      <TextBlock x:Name="cardServerTag" Text="运行中" FontSize="11" Foreground="{DynamicResource ColorTagOkFg}"/>
                    </Border>
                  </Grid>
                </Border>
                <!-- 卡片2：更新检查 -->
                <Border CornerRadius="6" Background="{DynamicResource ColorCard}" Padding="14,12" Margin="0,0,0,8">
                  <Grid>
                    <Grid.ColumnDefinitions>
                      <ColumnDefinition Width="Auto"/>
                      <ColumnDefinition Width="*"/>
                      <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <TextBlock Text="✓" FontSize="16" Foreground="{DynamicResource ColorAccent}" VerticalAlignment="Center"/>
                    <StackPanel Grid.Column="1" Margin="10,0,0,0" VerticalAlignment="Center">
                      <TextBlock Text="更新检查" FontSize="13" Foreground="{DynamicResource ColorTextPrimary}"/>
                      <TextBlock x:Name="cardUpdateSub" Text="版本 47f943859b" FontSize="11" Foreground="{DynamicResource ColorTextMuted}" Margin="0,2,0,0" TextWrapping="Wrap"/>
                    </StackPanel>
                    <Border Grid.Column="2" Style="{StaticResource StatusTag}">
                      <TextBlock x:Name="cardUpdateTag" Text="已是最新" FontSize="11" Foreground="{DynamicResource ColorTagOkFg}"/>
                    </Border>
                  </Grid>
                </Border>
                <!-- 卡片3：Orca 托盘 -->
                <Border CornerRadius="6" Background="{DynamicResource ColorCard}" Padding="14,12" Margin="0,0,0,8">
                  <Grid>
                    <Grid.ColumnDefinitions>
                      <ColumnDefinition Width="Auto"/>
                      <ColumnDefinition Width="*"/>
                      <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <TextBlock Text="✓" FontSize="16" Foreground="{DynamicResource ColorAccent}" VerticalAlignment="Center"/>
                    <StackPanel Grid.Column="1" Margin="10,0,0,0" VerticalAlignment="Center">
                      <TextBlock Text="Orca 托盘" FontSize="13" Foreground="{DynamicResource ColorTextPrimary}"/>
                      <TextBlock Text="右下角虎鲸图标" FontSize="11" Foreground="{DynamicResource ColorTextMuted}" Margin="0,2,0,0"/>
                    </StackPanel>
                    <Border Grid.Column="2" Style="{StaticResource StatusTag}">
                      <TextBlock x:Name="cardTrayTag" Text="运行中" FontSize="11" Foreground="{DynamicResource ColorTagOkFg}"/>
                    </Border>
                  </Grid>
                </Border>
              </StackPanel>

              <!-- 概览按钮 -->
              <StackPanel Orientation="Horizontal" Margin="0,6,0,0">
                <Button x:Name="btnOpenOverview" Content="打开 DSH 界面" Style="{StaticResource PrimaryButton}" Width="150" Height="36"/>
                <Button x:Name="btnCheckOverview" Content="检查更新" Style="{StaticResource SecondaryButton}" Width="120" Height="36" Margin="10,0,0,0"/>
                <Button x:Name="btnUpdateDsh" Content="更新 DSH…" Style="{StaticResource SecondaryButton}" Width="120" Height="36" Margin="10,0,0,0"/>
              </StackPanel>
            </StackPanel>

            <!-- ═══ 服务器页 ═══ -->
            <StackPanel x:Name="pageServer" CacheMode="BitmapCache" Visibility="Collapsed">
              <TextBlock Text="服务器" FontSize="22" FontWeight="Bold" Foreground="{DynamicResource ColorTextPrimary}"/>
              <TextBlock Text="启动、关闭、重启与打开 DSH 界面" FontSize="12" Foreground="{DynamicResource ColorTextSecondary}" Margin="0,2,0,0"/>
              <TextBlock Text="最近状态" FontSize="14" Foreground="{DynamicResource ColorTextPrimary}" Margin="0,18,0,0"/>

              <Border CornerRadius="6" Background="{DynamicResource ColorCard}" Padding="16,12" Margin="0,10,0,0">
                <Grid>
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="110"/>
                    <ColumnDefinition Width="*"/>
                  </Grid.ColumnDefinitions>
                  <Grid.RowDefinitions>
                    <RowDefinition Height="26"/>
                    <RowDefinition Height="26"/>
                    <RowDefinition Height="26"/>
                    <RowDefinition Height="26"/>
                    <RowDefinition Height="26"/>
                  </Grid.RowDefinitions>
                  <TextBlock Text="状态" Foreground="{DynamicResource ColorTextSecondary}" FontSize="12" VerticalAlignment="Center"/>
                  <TextBlock x:Name="infoStatus" Grid.Column="1" Text="—" Foreground="{DynamicResource ColorTextPrimary}" FontSize="12" VerticalAlignment="Center"/>
                  <TextBlock Text="端口" Grid.Row="1" Foreground="{DynamicResource ColorTextSecondary}" FontSize="12" VerticalAlignment="Center"/>
                  <TextBlock x:Name="infoPort" Grid.Row="1" Grid.Column="1" Text="—" Foreground="{DynamicResource ColorTextPrimary}" FontSize="12" VerticalAlignment="Center"/>
                  <TextBlock Text="DSH 目录" Grid.Row="2" Foreground="{DynamicResource ColorTextSecondary}" FontSize="12" VerticalAlignment="Center"/>
                  <TextBlock x:Name="infoDir" Grid.Row="2" Grid.Column="1" Text="—" Foreground="{DynamicResource ColorTextPrimary}" FontSize="12" VerticalAlignment="Center"/>
                  <TextBlock Text="最近检查" Grid.Row="3" Foreground="{DynamicResource ColorTextSecondary}" FontSize="12" VerticalAlignment="Center"/>
                  <TextBlock x:Name="infoChecked" Grid.Row="3" Grid.Column="1" Text="—" Foreground="{DynamicResource ColorTextPrimary}" FontSize="12" VerticalAlignment="Center"/>
                  <TextBlock Text="日志文件" Grid.Row="4" Foreground="{DynamicResource ColorTextSecondary}" FontSize="12" VerticalAlignment="Center"/>
                  <TextBlock x:Name="infoLog" Grid.Row="4" Grid.Column="1" Text="—" Foreground="{DynamicResource ColorTextPrimary}" FontSize="12" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
                </Grid>
              </Border>

              <StackPanel Orientation="Horizontal" Margin="0,16,0,0">
                <Button x:Name="btnOpenServer" Content="打开 DSH 界面" Style="{StaticResource PrimaryButton}" Width="140" Height="36"/>
                <Button x:Name="btnStartServer" Content="启动服务器" Style="{StaticResource SecondaryButton}" Width="110" Height="36" Margin="10,0,0,0"/>
                <Button x:Name="btnStopServer" Content="关闭服务器" Style="{StaticResource DangerButton}" Width="110" Height="36" Margin="10,0,0,0"/>
                <Button x:Name="btnRestartServer" Content="重启服务器" Style="{StaticResource SecondaryButton}" Width="110" Height="36" Margin="10,0,0,0"/>
              </StackPanel>
            </StackPanel>

            <!-- ═══ 安装页 ═══ -->
            <StackPanel x:Name="pageInstall" CacheMode="BitmapCache" Visibility="Collapsed">
              <TextBlock Text="安装 DSH" FontSize="22" FontWeight="Bold" Foreground="{DynamicResource ColorTextPrimary}"/>
              <TextBlock Text="电脑上还没有 DSH？这里一键搞定，两条路任选" FontSize="12" Foreground="{DynamicResource ColorTextSecondary}" Margin="0,2,0,0"/>

              <TextBlock Text="安装状态" FontSize="14" Foreground="{DynamicResource ColorTextPrimary}" Margin="0,18,0,0"/>
              <Border CornerRadius="6" Background="{DynamicResource ColorCard}" Padding="16,12" Margin="0,8,0,0">
                <Grid>
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                  </Grid.ColumnDefinitions>
                  <TextBlock x:Name="installCardIcon" Text="○" FontSize="16" Foreground="{DynamicResource ColorTextMuted}" VerticalAlignment="Center"/>
                  <StackPanel Grid.Column="1" Margin="10,0,0,0" VerticalAlignment="Center">
                    <TextBlock Text="DSH 完整版" FontSize="13" Foreground="{DynamicResource ColorTextPrimary}"/>
                    <TextBlock x:Name="installCardSub" Text="检测中…" FontSize="11" Foreground="{DynamicResource ColorTextMuted}" Margin="0,2,0,0" TextWrapping="Wrap"/>
                  </StackPanel>
                  <Border Grid.Column="2" Style="{StaticResource StatusTag}">
                    <TextBlock x:Name="installCardTag" Text="…" FontSize="11" Foreground="{DynamicResource ColorTagNeutralFg}"/>
                  </Border>
                </Grid>
              </Border>
              <TextBlock x:Name="installHelp" Text="方式一：完整版（适合长期使用，自动下载官方源码并安装，约 20~40 分钟）；方式二：官方 Web 版（只需 Node.js，一条命令秒开，适合先体验）。" FontSize="11" Foreground="{DynamicResource ColorTextMuted}" Margin="0,10,0,0" TextWrapping="Wrap"/>

              <StackPanel Orientation="Horizontal" Margin="0,16,0,0">
                <Button x:Name="btnInstallFull" Content="一键安装完整版" Style="{StaticResource PrimaryButton}" Width="160" Height="36"/>
                <Button x:Name="btnInstallWeb" Content="启动官方 Web 版" Style="{StaticResource SecondaryButton}" Width="140" Height="36" Margin="10,0,0,0"/>
                <Button x:Name="btnOpenSite" Content="打开 DSH 官网" Style="{StaticResource SecondaryButton}" Width="120" Height="36" Margin="10,0,0,0"/>
              </StackPanel>

              <TextBlock x:Name="installStatus" Text="" FontSize="12" Foreground="{DynamicResource ColorAccent}" Margin="0,12,0,0" TextWrapping="Wrap"/>
              <TextBox x:Name="txtInstallLog" IsReadOnly="True" FontFamily="Consolas" FontSize="11"
                       Background="#12141C" Foreground="#D0D7E5" BorderBrush="#2A2D42" BorderThickness="1"
                       Padding="10,8" TextWrapping="NoWrap" AcceptsReturn="True"
                       VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"
                       Height="160" Margin="0,10,0,0" Visibility="Collapsed"/>
              <StackPanel Orientation="Horizontal" Margin="0,10,0,0">
                <Button x:Name="btnInstallCancel" Content="取消安装并清理" Style="{StaticResource DangerButton}" Width="130" Height="32"/>
              </StackPanel>
            </StackPanel>

            <!-- ═══ 日志页 ═══ -->
            <StackPanel x:Name="pageLogs" CacheMode="BitmapCache" Visibility="Collapsed">
              <TextBlock Text="日志" FontSize="22" FontWeight="Bold" Foreground="{DynamicResource ColorTextPrimary}"/>
              <TextBlock Text="DSH 服务器运行日志（存于 ~/.dsh/orca-dsh-server.log）" FontSize="12" Foreground="{DynamicResource ColorTextSecondary}" Margin="0,2,0,0"/>
              <TextBox x:Name="txtLog" IsReadOnly="True" FontFamily="Consolas" FontSize="11"
                       Background="#12141C" Foreground="#D0D7E5" BorderBrush="#2A2D42" BorderThickness="1"
                       Padding="10,8" TextWrapping="NoWrap" AcceptsReturn="True"
                       VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"
                       Height="330" Margin="0,14,0,0"/>
              <StackPanel Orientation="Horizontal" Margin="0,12,0,0">
                <Button x:Name="btnLogRefresh" Content="刷新" Style="{StaticResource SecondaryButton}" Width="90" Height="32"/>
                <Button x:Name="btnLogClear" Content="清空日志" Style="{StaticResource DangerButton}" Width="100" Height="32" Margin="10,0,0,0"/>
              </StackPanel>
            </StackPanel>

            <!-- ═══ 设置页 ═══ -->
            <StackPanel x:Name="pageSettings" CacheMode="BitmapCache" Visibility="Collapsed">
              <TextBlock Text="设置" FontSize="22" FontWeight="Bold" Foreground="{DynamicResource ColorTextPrimary}"/>
              <TextBlock Text="修改后点保存，立即生效" FontSize="12" Foreground="{DynamicResource ColorTextSecondary}" Margin="0,2,0,0"/>

              <Border CornerRadius="6" Background="{DynamicResource ColorCard}" Padding="16,16" Margin="0,16,0,0">
                <StackPanel>
                  <Grid>
                    <Grid.ColumnDefinitions>
                      <ColumnDefinition Width="110"/>
                      <ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>
                    <Grid.RowDefinitions>
                      <RowDefinition Height="Auto"/>
                      <RowDefinition Height="14"/>
                      <RowDefinition Height="Auto"/>
                      <RowDefinition Height="16"/>
                      <RowDefinition Height="Auto"/>
                      <RowDefinition Height="8"/>
                      <RowDefinition Height="Auto"/>
                      <RowDefinition Height="14"/>
                      <RowDefinition Height="Auto"/>
                      <RowDefinition Height="12"/>
                      <RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>
                    <TextBlock Text="端口" Foreground="{DynamicResource ColorTextSecondary}" FontSize="12" VerticalAlignment="Center"/>
                    <TextBox x:Name="txtPort" Grid.Column="1" Style="{StaticResource ModernTextBox}" Height="30" HorizontalAlignment="Left" Width="120"/>
                    <TextBlock Text="DSH 目录" Grid.Row="2" Foreground="{DynamicResource ColorTextSecondary}" FontSize="12" VerticalAlignment="Center"/>
                    <TextBox x:Name="txtDshDir" Grid.Row="2" Grid.Column="1" Style="{StaticResource ModernTextBox}" Height="30"/>
                    <CheckBox x:Name="chkStartup" Grid.Row="4" Grid.Column="1" Content="开机自启托盘（Windows 登录时）" Foreground="{DynamicResource ColorTextSecondary}" FontSize="12"/>
                    <CheckBox x:Name="chkTrayAuto" Grid.Row="6" Grid.Column="1" Content="DSH 启动时自动拉起托盘" Foreground="{DynamicResource ColorTextSecondary}" FontSize="12"/>
                    <CheckBox x:Name="chkDshAutoStart" Grid.Row="8" Grid.Column="1" Content="开机自启 DSH 服务器（Windows 登录时）" Foreground="{DynamicResource ColorTextSecondary}" FontSize="12"/>
                    <TextBlock Text="主题" Grid.Row="10" Foreground="{DynamicResource ColorTextSecondary}" FontSize="12" VerticalAlignment="Center"/>
                    <StackPanel Grid.Row="10" Grid.Column="1" Orientation="Horizontal">
                      <RadioButton x:Name="rdoDark" Content="深色" GroupName="theme" Foreground="{DynamicResource ColorTextSecondary}" FontSize="12" IsChecked="True"/>
                      <RadioButton x:Name="rdoLight" Content="浅色" GroupName="theme" Foreground="{DynamicResource ColorTextSecondary}" FontSize="12" Margin="20,0,0,0"/>
                    </StackPanel>
                  </Grid>
                  <Button x:Name="btnSave" Content="保存设置" Style="{StaticResource PrimaryButton}" HorizontalAlignment="Right" Width="120" Height="34" Margin="0,18,0,0"/>
                </StackPanel>
              </Border>
            </StackPanel>

            <!-- ═══ 关于页 ═══ -->
            <StackPanel x:Name="pageAbout" CacheMode="BitmapCache" Visibility="Collapsed">
              <TextBlock Text="关于" FontSize="22" FontWeight="Bold" Foreground="{DynamicResource ColorTextPrimary}"/>
              <Border CornerRadius="6" Background="{DynamicResource ColorCard}" Padding="20,20" Margin="0,16,0,0">
                <StackPanel HorizontalAlignment="Center">
                  <TextBlock Text="🐋" FontSize="40" HorizontalAlignment="Center"/>
                  <TextBlock Text="Orca DSH Launcher" FontSize="16" FontWeight="Bold" Foreground="{DynamicResource ColorTextPrimary}" HorizontalAlignment="Center" Margin="0,10,0,0"/>
                  <TextBlock x:Name="lblVerAbout" Text="版本 v1.5.0" FontSize="12" Foreground="{DynamicResource ColorTextSecondary}" HorizontalAlignment="Center" Margin="0,4,0,0"/>
                  <TextBlock Text="DSH 守护者：更新检查 · 服务器启停 · 托盘 · 控制台" FontSize="12" Foreground="{DynamicResource ColorTextMuted}" HorizontalAlignment="Center" Margin="0,14,0,0" TextWrapping="Wrap"/>
                  <TextBlock x:Name="lblStats" Text="🐋 正在计算使用统计…" FontSize="11" Foreground="{DynamicResource ColorAccent}" HorizontalAlignment="Center" Margin="0,10,0,0" TextWrapping="Wrap"/>
                </StackPanel>
              </Border>
            </StackPanel>
          </Grid>

          <!-- 状态栏 -->
          <TextBlock x:Name="lblStatus" Grid.Row="1" Text="就绪" FontSize="12" Foreground="{DynamicResource ColorTextSecondary}" Margin="24,10,24,14"/>
        </Grid>
      </Grid>
    </Grid>
  </Border>
</Window>
'@

# ---------- 加载窗口 ----------
$reader = New-Object System.Xml.XmlNodeReader($xaml)
$window = [System.Windows.Markup.XamlReader]::Load($reader)

# 取控件
$titleBar   = $window.FindName('titleBar')
$btnMin     = $window.FindName('btnMin')
$btnClose   = $window.FindName('btnClose')
$navOverview= $window.FindName('navOverview')
$navServer  = $window.FindName('navServer')
$navInstall = $window.FindName('navInstall')
$navLogs    = $window.FindName('navLogs')
$navSettings= $window.FindName('navSettings')
$navAbout   = $window.FindName('navAbout')
$pageOverview=$window.FindName('pageOverview')
$pageServer = $window.FindName('pageServer')
$pageInstall=$window.FindName('pageInstall')
$pageLogs   = $window.FindName('pageLogs')
$pageSettings=$window.FindName('pageSettings')
$pageAbout  = $window.FindName('pageAbout')
$cardServerSub = $window.FindName('cardServerSub')
$cardServerTag = $window.FindName('cardServerTag')
$cardUpdateSub = $window.FindName('cardUpdateSub')
$cardUpdateTag = $window.FindName('cardUpdateTag')
$cardTrayTag   = $window.FindName('cardTrayTag')
$btnOpenOverview = $window.FindName('btnOpenOverview')
$btnCheckOverview= $window.FindName('btnCheckOverview')
$btnUpdateDsh = $window.FindName('btnUpdateDsh')
$lblVer      = $window.FindName('lblVer')
$lblVerAbout = $window.FindName('lblVerAbout')
$lblStats    = $window.FindName('lblStats')
$btnOpenServer = $window.FindName('btnOpenServer')
$btnStartServer= $window.FindName('btnStartServer')
$btnStopServer = $window.FindName('btnStopServer')
$btnRestartServer = $window.FindName('btnRestartServer')
$installCardIcon = $window.FindName('installCardIcon')
$installCardSub  = $window.FindName('installCardSub')
$installCardTag  = $window.FindName('installCardTag')
$installHelp     = $window.FindName('installHelp')
$btnInstallFull  = $window.FindName('btnInstallFull')
$btnInstallWeb   = $window.FindName('btnInstallWeb')
$btnOpenSite     = $window.FindName('btnOpenSite')
$installStatus   = $window.FindName('installStatus')
$txtInstallLog   = $window.FindName('txtInstallLog')
$btnInstallCancel = $window.FindName('btnInstallCancel')
$infoStatus  = $window.FindName('infoStatus')
$infoPort    = $window.FindName('infoPort')
$infoDir     = $window.FindName('infoDir')
$infoChecked = $window.FindName('infoChecked')
$infoLog     = $window.FindName('infoLog')
$txtLog      = $window.FindName('txtLog')
$btnLogRefresh = $window.FindName('btnLogRefresh')
$btnLogClear = $window.FindName('btnLogClear')
$txtPort     = $window.FindName('txtPort')
$txtDshDir   = $window.FindName('txtDshDir')
$chkStartup  = $window.FindName('chkStartup')
$chkTrayAuto = $window.FindName('chkTrayAuto')
$chkDshAutoStart = $window.FindName('chkDshAutoStart')
$rdoDark     = $window.FindName('rdoDark')
$rdoLight    = $window.FindName('rdoLight')
$btnSave     = $window.FindName('btnSave')
$lblStatus   = $window.FindName('lblStatus')

# 窗口图标 + 标题栏 logo（WPF 原生 ICO 解码，保留透明通道，任务栏显示虎鲸图标）
$imgLogo = $window.FindName('imgLogo')
try {
    $icoPath = Join-Path $PSScriptRoot 'dsh-tray.ico'
    if (Test-Path $icoPath) {
        $fs = [System.IO.File]::OpenRead($icoPath)
        try {
            $decoder = New-Object System.Windows.Media.Imaging.IconBitmapDecoder(
                $fs,
                [System.Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat,
                [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
            # 优先取 48px 帧（任务栏清晰且不至于太小），没有则取最大帧
            $frame = $decoder.Frames | Where-Object { $_.PixelWidth -le 48 } | Sort-Object PixelWidth -Descending | Select-Object -First 1
            if (-not $frame) { $frame = $decoder.Frames | Sort-Object PixelWidth -Descending | Select-Object -First 1 }
            if ($frame) {
                $frame.Freeze()
                if ($imgLogo) { $imgLogo.Source = $frame }
                $window.Icon = $frame
            }
        } finally {
            $fs.Dispose()
        }
    }
} catch {}

# ---------- 颜色工具 ----------
function New-Brush([string]$hex) {
    return New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($hex))
}

# ---------- 主题切换（深色 / 浅色） ----------
function Apply-Theme([bool]$isDark) {
    $t = @{}
    if ($isDark) {
        $t['ColorBg']='#101010'; $t['ColorBorder']='#2A2A2A'; $t['ColorSidebar']='#1A1A1A'
        $t['ColorCard']='#1E1E1E'; $t['ColorInput']='#1E1E1E'; $t['ColorInputBorder']='#3A3A3A'
        $t['ColorTextPrimary']='#F0F0F0'; $t['ColorTextSecondary']='#9A9A9A'; $t['ColorTextMuted']='#888888'
        $t['ColorBtnPrimaryBg']='#F0F0F0'; $t['ColorBtnPrimaryFg']='#101010'; $t['ColorBtnPrimaryHover']='#FFFFFF'; $t['ColorBtnPrimaryPressed']='#D8D8D8'
        $t['ColorBtnSecondaryBg']='#2D2D2D'; $t['ColorBtnSecondaryFg']='#E0E0E0'; $t['ColorBtnSecondaryHover']='#3A3A3A'; $t['ColorBtnSecondaryPressed']='#262626'
        $t['ColorBtnDisabledBg']='#1E1E1E'; $t['ColorBtnDisabledFg']='#555555'
        $t['ColorNavSelectedBg']='#2D2D2D'; $t['ColorNavHover']='#2A2A2A'
        $t['ColorWindowBtnFg']='#9AA0B5'; $t['ColorWindowBtnHoverBg']='#2A2A2A'
        $t['ColorDangerText']='#E07A7A'; $t['ColorDangerHoverBg']='#3A2626'
        $t['ColorTagOkBg']='#1C3A2E'; $t['ColorTagOkFg']='#36D199'
        $t['ColorTagWarnBg']='#3A3222'; $t['ColorTagWarnFg']='#E8B34A'
        $t['ColorTagNeutralBg']='#2D2D2D'; $t['ColorTagNeutralFg']='#9A9A9A'
    } else {
        $t['ColorBg']='#F5F5F7'; $t['ColorBorder']='#D9D9DE'; $t['ColorSidebar']='#ECECEF'
        $t['ColorCard']='#FFFFFF'; $t['ColorInput']='#FFFFFF'; $t['ColorInputBorder']='#C8C8CE'
        $t['ColorTextPrimary']='#1A1A1E'; $t['ColorTextSecondary']='#6E6E76'; $t['ColorTextMuted']='#8E8E96'
        $t['ColorBtnPrimaryBg']='#1A1A1E'; $t['ColorBtnPrimaryFg']='#FFFFFF'; $t['ColorBtnPrimaryHover']='#333338'; $t['ColorBtnPrimaryPressed']='#000000'
        $t['ColorBtnSecondaryBg']='#E2E2E6'; $t['ColorBtnSecondaryFg']='#2A2A2E'; $t['ColorBtnSecondaryHover']='#D2D2D8'; $t['ColorBtnSecondaryPressed']='#C8C8CE'
        $t['ColorBtnDisabledBg']='#E9E9EC'; $t['ColorBtnDisabledFg']='#A0A0A8'
        $t['ColorNavSelectedBg']='#D0D0D6'; $t['ColorNavHover']='#DCDCE2'
        $t['ColorWindowBtnFg']='#5A5A62'; $t['ColorWindowBtnHoverBg']='#DCDCE2'
        $t['ColorDangerText']='#C43C3C'; $t['ColorDangerHoverBg']='#F3DEDE'
        $t['ColorTagOkBg']='#DDF3E8'; $t['ColorTagOkFg']='#1E8A52'
        $t['ColorTagWarnBg']='#FBF0DC'; $t['ColorTagWarnFg']='#B07A1E'
        $t['ColorTagNeutralBg']='#E9E9EC'; $t['ColorTagNeutralFg']='#6E6E76'
    }
    foreach ($k in $t.Keys) {
        $brush = New-Brush $t[$k]
        $brush.Freeze()
        # 注意：不能直接 $Resources[$k] = brush（PowerShell 索引器赋值会触发
        # DynamicResource 引用者报错"invalid value"），必须 Remove + Add
        if ($window.Resources.Contains($k)) { $window.Resources.Remove($k) }
        $window.Resources.Add($k, $brush)
    }
}

# ---------- 页面切换 ----------
function Show-Page([string]$name) {
    # 缓存资源 brush（避免循环里反复查资源字典）
    $brushSel = $window.Resources['ColorNavSelectedBg']
    $brushTextPrimary = $window.Resources['ColorTextPrimary']
    $brushTextSecondary = $window.Resources['ColorTextSecondary']
    $pages = @{
        overview = $pageOverview
        server   = $pageServer
        install  = $pageInstall
        logs     = $pageLogs
        settings = $pageSettings
        about    = $pageAbout
    }
    foreach ($k in $pages.Keys) {
        $pages[$k].Visibility = if ($k -eq $name) { 'Visible' } else { 'Collapsed' }
    }
    $navs = @{
        overview = $navOverview
        server   = $navServer
        install  = $navInstall
        logs     = $navLogs
        settings = $navSettings
        about    = $navAbout
    }
    foreach ($k in $navs.Keys) {
        if ($k -eq $name) {
            $navs[$k].Background = $brushSel
            $navs[$k].Foreground = $brushTextPrimary
            $navs[$k].FontWeight = 'Bold'
        } else {
            $navs[$k].Background = [System.Windows.Media.Brushes]::Transparent
            $navs[$k].Foreground = $brushTextSecondary
            $navs[$k].FontWeight = 'Normal'
        }
    }
    # 进入日志页时立即刷一次；进入安装页时刷新安装状态卡
    if ($name -eq 'logs') { Update-LogDisplay }
    if ($name -eq 'install') { Update-InstallCard }
}

$navOverview.Add_Click({ Show-Page 'overview' })
$navServer.Add_Click({ Show-Page 'server' })
$navInstall.Add_Click({ Show-Page 'install' })
$navLogs.Add_Click({ Show-Page 'logs' })
$navSettings.Add_Click({ Show-Page 'settings' })
$navAbout.Add_Click({ Show-Page 'about' })

# ---------- 标题栏拖动 / 窗口按钮 ----------
# 拖拽优化：拖拽期间暂停定时刷新（避免状态查询阻塞 UI 线程导致卡顿）
$titleBar.Add_MouseLeftButtonDown({
    param($s, $e)
    if ($e.LeftButton -eq 'Pressed') {
        try { $refreshTimer.Stop() } catch {}
        try { $window.DragMove() } finally {
            try { $refreshTimer.Start() } catch {}
        }
    }
})
$btnMin.Add_Click({ $window.WindowState = 'Minimized' })
$btnClose.Add_Click({ $window.Close() })

# ---------- 刷新状态显示 ----------
function Update-StatusDisplay {
    try {
        $status = Get-PortStatus
        $owner = Get-PortOwner
        if ($status -eq 'running') {
            $cardServerTag.Text = '运行中'
            $cardServerTag.Foreground = $window.Resources['ColorTagOkFg']
            $cardServerTag.Parent.Background = $window.Resources['ColorTagOkBg']
            $cardServerSub.Text = 'http://127.0.0.1:' + $script:orcaCfgPort
            $infoStatus.Text = 'running'
            $infoStatus.Foreground = $window.Resources['ColorTagOkFg']
            $btnStartServer.IsEnabled = $false
            $btnStartServer.Content = '服务器已运行'
            $btnStopServer.IsEnabled = $true
            $btnStopServer.Content = '关闭服务器'
            $btnRestartServer.IsEnabled = $true
            $btnRestartServer.Content = '重启服务器'
        } elseif ($status -eq 'occupied') {
            $cardServerTag.Text = '端口被占'
            $cardServerTag.Foreground = $window.Resources['ColorTagWarnFg']
            $cardServerTag.Parent.Background = $window.Resources['ColorTagWarnBg']
            $ownerName = if ($owner) { $owner.Name } else { '未知程序' }
            $cardServerSub.Text = "端口 $($script:orcaCfgPort) 被 $ownerName 占用（非 DSH）"
            $infoStatus.Text = '端口被占用'
            $infoStatus.Foreground = $window.Resources['ColorTagWarnFg']
            $btnStartServer.IsEnabled = $true
            $btnStartServer.Content = '启动服务器'
            $btnStopServer.IsEnabled = $false
            $btnStopServer.Content = '服务器未运行'
            $btnRestartServer.IsEnabled = $false
            $btnRestartServer.Content = '重启服务器'
        } else {
            # 端口空闲：区分「已安装未运行」和「未安装」
            $installed = Test-DshInstalled -DshDir $script:orcaCfgDshDir
            if (-not $installed) {
                $cardServerTag.Text = '未安装'
                $cardServerTag.Foreground = $window.Resources['ColorTagWarnFg']
                $cardServerTag.Parent.Background = $window.Resources['ColorTagWarnBg']
                $cardServerSub.Text = '未安装 DSH，请到「安装」页一键安装'
                $infoStatus.Text = '未安装'
                $infoStatus.Foreground = $window.Resources['ColorTagWarnFg']
                $btnStartServer.IsEnabled = $false
                $btnStartServer.Content = '请先安装 DSH'
                $btnStopServer.IsEnabled = $false
                $btnStopServer.Content = '服务器未运行'
                $btnRestartServer.IsEnabled = $false
                $btnRestartServer.Content = '重启服务器'
            } else {
                $cardServerTag.Text = '未运行'
                $cardServerTag.Foreground = $window.Resources['ColorTagNeutralFg']
                $cardServerTag.Parent.Background = $window.Resources['ColorTagNeutralBg']
                $cardServerSub.Text = 'http://127.0.0.1:' + $script:orcaCfgPort
                $infoStatus.Text = 'stopped'
                $infoStatus.Foreground = $window.Resources['ColorTagNeutralFg']
                $btnStartServer.IsEnabled = $true
                $btnStartServer.Content = '启动服务器'
                $btnStopServer.IsEnabled = $false
                $btnStopServer.Content = '服务器未运行'
                $btnRestartServer.IsEnabled = $false
                $btnRestartServer.Content = '重启服务器'
            }
        }
        $infoPort.Text = [string]$script:orcaCfgPort
        $infoDir.Text = $script:orcaCfgDshDir
        $infoLog.Text = (Get-ServerLogFile)

        # 托盘状态
        if (Test-TrayRunning) {
            $cardTrayTag.Text = '运行中'
            $cardTrayTag.Foreground = $window.Resources['ColorTagOkFg']
            $cardTrayTag.Parent.Background = $window.Resources['ColorTagOkBg']
        } else {
            $cardTrayTag.Text = '未运行'
            $cardTrayTag.Foreground = $window.Resources['ColorTagNeutralFg']
            $cardTrayTag.Parent.Background = $window.Resources['ColorTagNeutralBg']
        }

        # 更新状态：优先用最近一次检查结果，否则读插件写的状态文件
        $state = $script:lastCheck
        if (-not $state) { $state = Get-UpdateState }
        if ($state -and $null -ne $state.hasUpdate) {
            if ($state.hasUpdate) {
                $cardUpdateTag.Text = '有新版本'
                $cardUpdateTag.Foreground = $window.Resources['ColorTagWarnFg']
                $cardUpdateTag.Parent.Background = $window.Resources['ColorTagWarnBg']
                $cardUpdateSub.Text = '官方 ' + $state.remoteCommit.ToString().Substring(0,10) + ' / 本地 ' + $state.localCommit.ToString().Substring(0,10)
                # 更新详情（最近 commit 标题）
                if ($script:lastDetails) {
                    $detailLines = ($script:lastDetails | Select-Object -First 3 | ForEach-Object { '· ' + $_ })
                    $cardUpdateSub.Text += "`n" + ($detailLines -join "`n")
                }
            } else {
                $cardUpdateTag.Text = '已是最新'
                $cardUpdateTag.Foreground = $window.Resources['ColorTagOkFg']
                $cardUpdateTag.Parent.Background = $window.Resources['ColorTagOkBg']
                $cardUpdateSub.Text = '版本 ' + $state.localCommit.ToString().Substring(0,10)
            }
            if ($state.checkedAt) {
                $infoChecked.Text = $state.checkedAt.Replace('T',' ').Substring(0,16)
            }
        } else {
            $cardUpdateTag.Text = '无结果'
            $cardUpdateTag.Foreground = $window.Resources['ColorTagNeutralFg']
            $cardUpdateTag.Parent.Background = $window.Resources['ColorTagNeutralBg']
            $cardUpdateSub.Text = '点「检查更新」查看'
            $infoChecked.Text = '—'
        }
        # 安装页卡片状态
        Update-InstallCard
    } catch {}
}

# ---------- 刷新安装页卡片 ----------
function Update-InstallCard {
    try {
        $installed = Test-DshInstalled -DshDir $script:orcaCfgDshDir
        if ($installed) {
            $installCardIcon.Text = '✓'
            $installCardIcon.Foreground = $window.Resources['ColorTagOkFg']
            $installCardSub.Text = $script:orcaCfgDshDir
            $installCardTag.Text = '已安装'
            $installCardTag.Foreground = $window.Resources['ColorTagOkFg']
            $installCardTag.Parent.Background = $window.Resources['ColorTagOkBg']
            $btnInstallFull.IsEnabled = $false
            $btnInstallFull.Content = '已安装 ✓'
            $btnInstallCancel.IsEnabled = $false
        } else {
            $installCardIcon.Text = '○'
            $installCardIcon.Foreground = $window.Resources['ColorTagWarnFg']
            $installCardSub.Text = '尚未安装，点下方按钮一键安装'
            $installCardTag.Text = '未安装'
            $installCardTag.Foreground = $window.Resources['ColorTagWarnFg']
            $installCardTag.Parent.Background = $window.Resources['ColorTagWarnBg']
            $btnInstallFull.IsEnabled = $true
            $btnInstallFull.Content = '一键安装完整版'
            $btnInstallCancel.IsEnabled = $false
        }
    } catch {}
}

# ---------- 刷新日志显示 ----------
function Update-LogDisplay {
    try {
        $lines = Get-ServerLog -Lines 250
        $txtLog.Text = ($lines -join "`n")
        $txtLog.ScrollToEnd()
    } catch {}
}

# ---------- 操作按钮（概览页） ----------
$btnOpenOverview.Add_Click({
    try {
        $status = Get-PortStatus
        if ($status -eq 'free' -and -not (Test-DshInstalled -DshDir $script:orcaCfgDshDir)) {
            $lblStatus.Text = '⚠️ 未安装 DSH，请到「安装」页一键安装，或直接启动官方 Web 版'
            Show-Page 'install'
            return
        }
        if ($status -eq 'occupied') {
            $lblStatus.Text = '⚠️ 端口 ' + $script:orcaCfgPort + ' 被其他程序占用，无法启动 DSH'
            return
        }
        if (Test-ServerRunning) {
            $lblStatus.Text = '正在打开 DSH 界面…'
            [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Background)
            Open-DshUi
            $lblStatus.Text = 'DSH 界面已打开'
        } else {
            if (Start-DshServer) {
                $script:pendingOpen = $true
                $lblStatus.Text = '正在启动 DSH…（就绪后自动打开界面）'
                Update-StatusDisplay
            } else {
                $lblStatus.Text = '启动失败：' + $script:orcaLastServerError
            }
        }
    } catch {
        $lblStatus.Text = '操作出错：' + $_.Exception.Message
    }
})

$btnCheckOverview.Add_Click({
    try {
        $btnCheckOverview.IsEnabled = $false
        $lblStatus.Text = '正在检查更新…（网络查询，稍等几秒）'
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Background)
        $script:lastCheck = Invoke-UpdateCheck
        $script:lastDetails = $null
        if ($script:lastCheck.ok -and $script:lastCheck.hasUpdate) {
            # 有新版本：顺带拉官方最近提交标题
            $script:lastDetails = Get-UpdateDetails -Count 5
        }
        Update-StatusDisplay
        if (-not $script:lastCheck.ok) {
            $lblStatus.Text = '检查失败（网络或本地版本读不到）'
        } elseif ($script:lastCheck.hasUpdate) {
            if ($script:lastDetails) {
                $lblStatus.Text = ('发现新版本！最近更新：' + $script:lastDetails[0])
            } else {
                $lblStatus.Text = '发现新版本！详情见概览页'
            }
        } else {
            $lblStatus.Text = '已是最新版本'
        }
        $btnCheckOverview.IsEnabled = $true
    } catch {
        $btnCheckOverview.IsEnabled = $true
        $lblStatus.Text = '操作出错：' + $_.Exception.Message
    }
})

# 一键更新 DSH（git pull，需用户确认；失败不影响现有版本）
$btnUpdateDsh.Add_Click({
    try {
        $confirm = [System.Windows.MessageBox]::Show(
            '即将更新 DSH 本体（在 ' + $script:orcaCfgDshDir + ' 执行 git pull）。' + "`n" + '更新后需要重启 DSH 才能生效。' + "`n" + '继续吗？',
            '更新 DSH', 'YesNo', 'Question')
        if ($confirm -ne 'Yes') { return }
        $btnUpdateDsh.IsEnabled = $false
        $lblStatus.Text = '正在更新 DSH…（git pull，可能需要一点时间）'
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Background)
        $result = Update-Dsh
        if ($result.ok) {
            # 成功：刷新版本状态
            $script:lastCheck = Invoke-UpdateCheck
            $script:lastDetails = $null
            Update-StatusDisplay
            $lblStatus.Text = '更新完成！请重启 DSH 生效（本窗口可点「重启服务器」）'
            [System.Windows.MessageBox]::Show('DSH 更新成功！' + "`n" + $result.output + "`n" + '请重启 DSH 生效。', '更新完成', 'OK', 'Information')
        } else {
            $lblStatus.Text = '更新失败：git pull 出错（当前版本不受影响）'
            [System.Windows.MessageBox]::Show('更新失败，当前版本不受影响。' + "`n" + $result.output, '更新失败', 'OK', 'Warning')
        }
        $btnUpdateDsh.IsEnabled = $true
    } catch {
        $btnUpdateDsh.IsEnabled = $true
        $lblStatus.Text = '操作出错：' + $_.Exception.Message
    }
})

# ---------- 操作按钮（服务器页） ----------
$btnOpenServer.Add_Click({
    try {
        $status = Get-PortStatus
        if ($status -eq 'free' -and -not (Test-DshInstalled -DshDir $script:orcaCfgDshDir)) {
            $lblStatus.Text = '⚠️ 未安装 DSH，请到「安装」页一键安装，或直接启动官方 Web 版'
            Show-Page 'install'
            return
        }
        if ($status -eq 'occupied') {
            $lblStatus.Text = '⚠️ 端口 ' + $script:orcaCfgPort + ' 被其他程序占用，无法启动 DSH'
            return
        }
        if (Test-ServerRunning) {
            $lblStatus.Text = '正在打开 DSH 界面…'
            [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Background)
            Open-DshUi
            $lblStatus.Text = 'DSH 界面已打开'
        } else {
            if (Start-DshServer) {
                $script:pendingOpen = $true
                $lblStatus.Text = '正在启动 DSH…（就绪后自动打开界面）'
                Update-StatusDisplay
            } else {
                $lblStatus.Text = '启动失败：' + $script:orcaLastServerError
            }
        }
    } catch {
        $lblStatus.Text = '操作出错：' + $_.Exception.Message
    }
})

$btnStartServer.Add_Click({
    try {
        $status = Get-PortStatus
        if ($status -eq 'free' -and -not (Test-DshInstalled -DshDir $script:orcaCfgDshDir)) {
            $lblStatus.Text = '⚠️ 未安装 DSH，请到「安装」页一键安装，或直接启动官方 Web 版'
            Show-Page 'install'
            return
        }
        if ($status -eq 'occupied') {
            $owner = Get-PortOwner
            $ownerName = if ($owner) { $owner.Name } else { '未知程序' }
            $lblStatus.Text = '⚠️ 端口 ' + $script:orcaCfgPort + ' 被 ' + $ownerName + ' 占用，无法启动'
            return
        }
        if (Test-ServerRunning) {
            $lblStatus.Text = '服务器已经在运行中'
        } elseif (Start-DshServer) {
            $script:pendingStart = $true
            $lblStatus.Text = '正在启动服务器…'
            Update-StatusDisplay
        } else {
            $lblStatus.Text = '启动失败：' + $script:orcaLastServerError
        }
    } catch {
        $lblStatus.Text = '操作出错：' + $_.Exception.Message
    }
})

$btnStopServer.Add_Click({
    try {
        $lblStatus.Text = '正在关闭服务器…'
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Background)
        if (Stop-DshServer) {
            Update-StatusDisplay
            $lblStatus.Text = '服务器已关闭'
        } else {
            Update-StatusDisplay
            $lblStatus.Text = '⚠️ ' + $script:orcaLastServerError
        }
    } catch {
        $lblStatus.Text = '操作出错：' + $_.Exception.Message
    }
})

# 一键重启：关闭 → 启动
$btnRestartServer.Add_Click({
    try {
        $status = Get-PortStatus
        if ($status -eq 'occupied') {
            $owner = Get-PortOwner
            $ownerName = if ($owner) { $owner.Name } else { '未知程序' }
            $lblStatus.Text = '⚠️ 端口 ' + $script:orcaCfgPort + ' 被 ' + $ownerName + ' 占用，不能重启'
            return
        }
        if (-not (Test-ServerRunning)) {
            $lblStatus.Text = '服务器未运行，直接启动…'
            if (Start-DshServer) {
                $script:pendingStart = $true
                Update-StatusDisplay
                $lblStatus.Text = '服务器已启动'
            } else {
                $lblStatus.Text = '启动失败：' + $script:orcaLastServerError
            }
            return
        }
        $lblStatus.Text = '正在重启服务器…'
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Background)
        if (-not (Stop-DshServer)) {
            Update-StatusDisplay
            $lblStatus.Text = '⚠️ ' + $script:orcaLastServerError
            return
        }
        Start-Sleep -Seconds 2
        if (Start-DshServer) {
            $script:pendingStart = $true
            $lblStatus.Text = '重启中：服务器正在启动…'
            Update-StatusDisplay
        } else {
            $lblStatus.Text = '重启失败：' + $script:orcaLastServerError
        }
    } catch {
        $lblStatus.Text = '操作出错：' + $_.Exception.Message
    }
})

# ---------- 操作按钮（安装页） ----------
$script:InstallPhase = 'idle'       # idle/cloning/installing/building/finishing/done/failed
$script:InstallProc = $null
$script:InstallDshDir = ''
$script:PendingWebOpen = $false             # 官方 Web 版就绪后自动打开
$script:PendingStartAfterInstall = $false   # 安装完成后自动启动完整版

# 打开 DSH 官网（官方 GitHub 仓库，能看到官方文档与 Web 版说明）
$btnOpenSite.Add_Click({
    try { Start-Process 'https://github.com/deepseek-ai/deepseek-harness' } catch {}
})

# 启动官方 Web 版（npx @deepseek-ai/dsh web，无需本地安装）
$btnInstallWeb.Add_Click({
    try {
        $status = Get-PortStatus
        if ($status -eq 'running') {
            Start-Process "http://127.0.0.1:$($script:orcaCfgPort)"
            $installStatus.Text = 'DSH 已在运行，已为你打开界面'
            return
        }
        if ($status -eq 'occupied') {
            $owner = Get-PortOwner
            $ownerName = if ($owner) { $owner.Name } else { '其他程序' }
            $installStatus.Text = '⚠️ 端口 ' + $script:orcaCfgPort + ' 被 ' + $ownerName + ' 占用，请先处理'
            return
        }
        $btnInstallWeb.IsEnabled = $false
        $txtInstallLog.Visibility = 'Visible'
        $installStatus.Text = '正在启动官方 Web 版（首次运行会自动下载官方包，请稍候）…'
        $r = Start-DshWebNpx -Port $script:orcaCfgPort
        if (-not $r.ok) {
            $installStatus.Text = '❌ ' + $r.error
            $btnInstallWeb.IsEnabled = $true
            return
        }
        $script:PendingWebOpen = $true
    } catch {
        $installStatus.Text = '操作出错：' + $_.Exception.Message
        $btnInstallWeb.IsEnabled = $true
    }
})

# 一键安装完整版（环境 → 网络 → 选目录 → clone → install → build → 装插件）
$btnInstallFull.Add_Click({
    try {
        if ($script:InstallPhase -in @('cloning','installing','building','finishing')) {
            [System.Windows.MessageBox]::Show('安装正在进行中，请稍候。', 'Orca DSH Launcher', 'OK', 'Information') | Out-Null
            return
        }
        # 1) 环境检测
        $installStatus.Text = '① 正在检查电脑环境…'
        $envResult = Test-NodeEnv
        if (-not $envResult.ok) {
            $msg = '还缺少以下软件：' + "`n" + ($envResult.missing -join "`n") + "`n`n" + '装好后再来点「一键安装完整版」。'
            [System.Windows.MessageBox]::Show($msg, '缺少环境', 'OK', 'Warning') | Out-Null
            $installStatus.Text = '缺少环境，请先安装所需软件'
            return
        }
        # 2) 网络检测
        $installStatus.Text = '② 正在检测网络（能否访问 GitHub）…'
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Background)
        $netResult = Test-GithubNetwork
        if (-not $netResult.githubOk) {
            $msg = '当前网络无法访问 GitHub，下载可能会失败。' + "`n" + '检查结果：' + $netResult.detail + "`n`n" + '建议：检查代理/VPN 设置，或更换网络后再试。' + "`n" + '如果确认网络没问题，可以点「是」继续尝试。'
            $ans = [System.Windows.MessageBox]::Show($msg, '网络不可用', 'YesNo', 'Warning')
            if ($ans -ne 'Yes') { $installStatus.Text = '已取消安装'; return }
        }
        # 3) 选择安装位置
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = '选择 DSH 要安装到的文件夹（会自动创建 deepseek-harness 子文件夹）'
        $dlg.ShowNewFolderButton = $true
        if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
        $script:InstallDshDir = Join-Path $dlg.SelectedPath 'deepseek-harness'
        $installStatus.Text = '安装位置：' + $script:InstallDshDir
        # 4) 开始安装
        $txtInstallLog.Visibility = 'Visible'
        try { Remove-Item $script:InstallLogFile -Force -ErrorAction SilentlyContinue } catch {}
        $btnInstallFull.IsEnabled = $false
        $script:InstallPhase = 'idle'
        Start-ConsoleInstall
    } catch {
        $installStatus.Text = '操作出错：' + $_.Exception.Message
        $btnInstallFull.IsEnabled = $true
    }
})

# 控制台版安装状态机（与独立向导同一套逻辑，只差界面）
function Start-ConsoleInstall {
    # 记录"安装开始前目录是否存在"——不存在 = 本次创建的，取消时可安全删除
    $script:ConsoleDirExistedBefore = Test-Path $script:InstallDshDir
    $btnInstallCancel.IsEnabled = $true
    $clone = Install-DshClone -DshDir $script:InstallDshDir
    if (-not $clone.ok) {
        $installStatus.Text = '❌ ' + $clone.error
        $script:InstallPhase = 'failed'
        $btnInstallFull.IsEnabled = $true
        return
    }
    if ($null -ne $clone.proc) {
        $script:InstallPhase = 'cloning'
        $installStatus.Text = '正在下载 DSH 源码（git clone，取决于网速）…'
        $script:InstallProc = $clone.proc
        $installTimer.Start()
        return
    }
    Start-ConsoleDeps
}

function Start-ConsoleDeps {
    $script:InstallPhase = 'installing'
    $installStatus.Text = '正在安装依赖（pnpm install，通常 10~30 分钟，请耐心等待）…'
    $deps = Install-DshDeps -DshDir $script:InstallDshDir
    if (-not $deps.ok) {
        $installStatus.Text = '❌ ' + $deps.error
        $script:InstallPhase = 'failed'
        $btnInstallFull.IsEnabled = $true
        return
    }
    $script:InstallProc = $deps.proc
    $installTimer.Start()
}

function Start-ConsoleBuild {
    $script:InstallPhase = 'building'
    $installStatus.Text = '正在构建 DSH（pnpm run build，需要几分钟）…'
    $script:InstallProc = Start-DshBuild -DshDir $script:InstallDshDir
    $installTimer.Start()
}

function Finish-ConsoleInstall {
    $script:InstallPhase = 'finishing'
    $installStatus.Text = '正在安装 Orca 插件…'
    $src = Get-PluginSource -FallbackDir (Split-Path -Parent $PSScriptRoot)
    if ($src) {
        Install-OrcaPlugin -PluginSource $src -DshDir $script:InstallDshDir | Out-Null
        $targetDir = Join-Path $env:USERPROFILE '.dsh\profiles\web\node_modules\orca-dsh-launcher'
        New-DesktopShortcut -PluginTargetDir $targetDir | Out-Null
    }
    # 更新内存配置指向新装的 DSH（不写盘，重启控制台后由配置文件接管）
    $script:orcaCfgDshDir = $script:InstallDshDir
    $script:InstallPhase = 'done'
    $installStatus.Text = '✅ 安装完成！正在启动 DSH…'
    $btnInstallFull.IsEnabled = $true
    $btnInstallCancel.IsEnabled = $false
    $installTimer.Stop()
    Update-StatusDisplay
    $script:PendingStartAfterInstall = $true
}

# 安装进度定时器（800ms）
$installTimer = New-Object System.Windows.Threading.DispatcherTimer
$installTimer.Interval = [TimeSpan]::FromMilliseconds(800)
$installTimer.Add_Tick({
    # 刷新日志
    $lines = Get-SetupLogTail -Lines 60
    if ($lines.Count -gt 0) {
        $txtInstallLog.Text = ($lines -join "`n")
        $txtInstallLog.ScrollToEnd()
    }
    # 进程还在跑 → 等下一轮
    if ($script:InstallProc -and -not $script:InstallProc.HasExited) { return }

    if ($script:InstallPhase -eq 'cloning') {
        if ($script:InstallProc.ExitCode -eq 0) {
            $installStatus.Text = '✅ 源码下载完成，开始装依赖…'
            Start-ConsoleDeps
        } else {
            $script:InstallPhase = 'failed'
            $installStatus.Text = '❌ 下载失败（退出码 ' + $script:InstallProc.ExitCode + '），请查看日志并检查网络'
            $btnInstallFull.IsEnabled = $true
            $installTimer.Stop()
        }
    } elseif ($script:InstallPhase -eq 'installing') {
        if ($script:InstallProc.ExitCode -eq 0) {
            $installStatus.Text = '✅ 依赖安装完成，开始构建…'
            Start-ConsoleBuild
        } else {
            $script:InstallPhase = 'failed'
            $installStatus.Text = '❌ 依赖安装失败（退出码 ' + $script:InstallProc.ExitCode + '），请查看日志（常见原因：网络中断、磁盘空间不足）'
            $btnInstallFull.IsEnabled = $true
            $installTimer.Stop()
        }
    } elseif ($script:InstallPhase -eq 'building') {
        if ($script:InstallProc.ExitCode -eq 0) {
            Finish-ConsoleInstall
        } else {
            $script:InstallPhase = 'failed'
            $installStatus.Text = '❌ 构建失败（退出码 ' + $script:InstallProc.ExitCode + '），请查看日志'
            $btnInstallFull.IsEnabled = $true
            $installTimer.Stop()
        }
    }
})

# 「取消安装并清理」：杀进程树 + 删除本次残留 + 复位状态
# （只删"本次安装创建"的目录；安装前就存在的目录绝不删除）
$btnInstallCancel.Add_Click({
    # 1) 杀整个进程树（cmd → git/pnpm 的子进程一起结束）
    if ($script:InstallProc) {
        try { taskkill /PID $script:InstallProc.Id /T /F 2>$null | Out-Null } catch {}
        $script:InstallProc = $null
    }
    $installTimer.Stop()
    $script:InstallPhase = 'idle'
    $script:PendingWebOpen = $false

    # 2) 询问是否删除残留（只删本次安装创建的目录）
    $dirInfo = $script:InstallDshDir
    $canDelete = (-not $script:ConsoleDirExistedBefore) -and (Test-Path $dirInfo)
    $msg = '要取消安装吗？'
    if ($canDelete) {
        $msg += "`n`n本次安装创建了文件夹：`n" + $dirInfo + "`n`n是否删除它（包括已下载的文件）？"
    } elseif ($script:ConsoleDirExistedBefore) {
        $msg += "`n`n（这个文件夹在安装前就存在，为了安全不会删除它）"
    }
    $ans = [System.Windows.MessageBox]::Show($msg, '取消安装', 'YesNo', 'Question')
    if ($ans -ne 'Yes') { return }
    if ($canDelete) {
        try { Remove-Item $dirInfo -Recurse -Force -ErrorAction SilentlyContinue } catch {}
    }

    # 3) 复位状态
    $installStatus.Text = '已取消安装并清理'
    $installStatus.Foreground = $window.Resources['ColorWarnFg']
    $btnInstallFull.IsEnabled = $true
    $btnInstallCancel.IsEnabled = $false
    $txtInstallLog.Text = ''
    Update-InstallCard
    $lblStatus.Text = '已取消安装'
})

# ---------- 日志页按钮 ----------
$btnLogRefresh.Add_Click({ Update-LogDisplay; $lblStatus.Text = '日志已刷新' })
$btnLogClear.Add_Click({
    try {
        if (Clear-ServerLog) {
            Update-LogDisplay
            $lblStatus.Text = '日志已清空'
        } else {
            $lblStatus.Text = '清空失败'
        }
    } catch {
        $lblStatus.Text = '操作出错：' + $_.Exception.Message
    }
})

# ---------- 保存设置 ----------
$btnSave.Add_Click({
    try {
        $newPort = 3080
        if ($txtPort.Text.Trim() -match '^\d+$') {
            $newPort = [int]$txtPort.Text.Trim()
            if ($newPort -lt 1 -or $newPort -gt 65535) { throw '端口需在 1-65535 之间' }
        } else {
            throw '端口必须是数字'
        }
        $newDshDir = $txtDshDir.Text.Trim()
        if (-not $newDshDir) { throw 'DSH 目录不能为空' }
        $newTheme = if ($rdoLight.IsChecked) { 'light' } else { 'dark' }

        # 1) 写共享配置
        if (-not (Write-OrcaConfig -Port $newPort -DshDir $newDshDir -TrayAutoStart $chkTrayAuto.IsChecked -Theme $newTheme)) {
            throw '写入配置文件失败'
        }

        # 2) 开机自启托盘（Windows 启动文件夹快捷方式）
        $startupDir = [Environment]::GetFolderPath('Startup')
        $trayLnk = Join-Path $startupDir 'Orca DSH Launcher.lnk'
        if ($chkStartup.IsChecked) {
            $vbs = Join-Path $PSScriptRoot 'start-tray.vbs'
            $ico = Join-Path $PSScriptRoot 'dsh-tray.ico'
            if (-not (Test-Path $trayLnk)) {
                $ws = New-Object -ComObject WScript.Shell
                $sc = $ws.CreateShortcut($trayLnk)
                $sc.TargetPath = 'wscript.exe'
                $sc.Arguments = '"' + $vbs + '"'
                $sc.WorkingDirectory = $PSScriptRoot
                $sc.Description = 'Orca DSH Launcher 托盘（开机自启）'
                if (Test-Path $ico) { $sc.IconLocation = "$ico,0" }
                $sc.Save()
            }
        } else {
            if (Test-Path $trayLnk) { Remove-Item $trayLnk -Force }
        }

        # 3) 开机自启 DSH 服务器
        if ($chkDshAutoStart.IsChecked) {
            Set-DshAutoStart
        } else {
            Remove-DshAutoStart
        }

        # 4) 应用主题（立即生效，不用重启窗口）
        Apply-Theme ($newTheme -eq 'dark')
        Update-StatusDisplay

        $lblStatus.Text = '设置已保存'
    } catch {
        $lblStatus.Text = '保存失败：' + $_.Exception.Message
    }
})

# ---------- 定时刷新（每 2 秒）：状态 + 日志页 + "启动后自动打开" ----------
$refreshTimer = New-Object System.Windows.Threading.DispatcherTimer
$refreshTimer.Interval = [TimeSpan]::FromSeconds(4)
$script:refreshBusy = $false   # 防重入：上一轮还没跑完就跳过本轮
$refreshTimer.Add_Tick({
    # 防重入：查询可能较慢，避免 tick 叠加阻塞界面
    if ($script:refreshBusy) { return }
    $script:refreshBusy = $true
    try {
        Update-StatusDisplay
        if ($pageLogs.Visibility -eq 'Visible') { Update-LogDisplay }
        if ($script:pendingStart -and (Test-ServerRunning)) {
            $script:pendingStart = $false
            $lblStatus.Text = '服务器已启动'
        }
        if ($script:pendingOpen -and (Test-ServerRunning)) {
            $script:pendingOpen = $false
            $lblStatus.Text = '正在打开 DSH 界面…'
            [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Background)
            Open-DshUi
            $lblStatus.Text = 'DSH 界面已打开'
        }
        # 官方 Web 版等待就绪后自动打开界面
        if ($script:PendingWebOpen -and (Test-ServerRunning)) {
            $script:PendingWebOpen = $false
            $btnInstallWeb.IsEnabled = $true
            Start-Process "http://127.0.0.1:$($script:orcaCfgPort)"
            $installStatus.Text = '✅ 官方 Web 版已启动，已打开界面'
        }
        # 完整版安装完成后自动启动
        if ($script:PendingStartAfterInstall -and -not (Test-ServerRunning)) {
            $r = Start-DshFromDir -DshDir $script:InstallDshDir -Port $script:orcaCfgPort
            if ($r.ok) {
                $script:PendingStartAfterInstall = $false
                $lblStatus.Text = '正在启动 DSH…'
                $script:pendingOpen = $true
            }
        }
    } catch {} finally {
        $script:refreshBusy = $false
    }
})

# 强设窗口类图标（无边框窗口 WPF 不应用 Icon；须在窗口显示前设置，
# 否则任务栏按钮已按 exe 图标创建）。SourceInitialized + Loaded 各设一次。
function Set-Win32Icon {
    try {
        $helper = New-Object System.Windows.Interop.WindowInteropHelper($window)
        $hWnd = $helper.Handle
        $icoPath2 = Join-Path $PSScriptRoot 'dsh-tray.ico'
        if (($hWnd -ne [IntPtr]::Zero) -and (Test-Path $icoPath2)) {
            $wIcon = New-Object System.Drawing.Icon($icoPath2, 32, 32)
            if ([IntPtr]::Size -eq 8) {
                [IconWin32]::SetClassLongPtr64($hWnd, -14, $wIcon.Handle)   # GCLP_HICON（任务栏大图标）
                [IconWin32]::SetClassLongPtr64($hWnd, -34, $wIcon.Handle)   # GCLP_HICONSM（小图标）
            } else {
                [IconWin32]::SetClassLong32($hWnd, -14, $wIcon.Handle.ToInt32())
                [IconWin32]::SetClassLong32($hWnd, -34, $wIcon.Handle.ToInt32())
            }
        }
    } catch {}
}

$window.Add_SourceInitialized({ Set-Win32Icon })

# 打开时载入当前设置 + 应用主题 + 淡入动画
$window.Add_Loaded({
    Set-Win32Icon
    $isDark = ($script:orcaCfgTheme -ne 'light')
    Apply-Theme $isDark
    if ($isDark) { $rdoDark.IsChecked = $true } else { $rdoLight.IsChecked = $true }
    $txtPort.Text = [string]$script:orcaCfgPort
    $txtDshDir.Text = $script:orcaCfgDshDir
    $chkTrayAuto.IsChecked = $script:orcaCfgTrayAutoStart
    $startupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'Orca DSH Launcher.lnk'
    $chkStartup.IsChecked = (Test-Path $startupLnk)
    $chkDshAutoStart.IsChecked = Test-DshAutoStart

    # 版本号：从 package.json 动态读取（单一来源）
    try {
        $pkgPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'package.json'
        if (Test-Path $pkgPath) {
            # package.json 是 UTF-8 无 BOM，必须用 .NET 显式编码读（Get-Content 会按 GBK 读乱）
            $pkgRaw = [System.IO.File]::ReadAllText($pkgPath, (New-Object System.Text.UTF8Encoding($false)))
            $pkg = $pkgRaw | ConvertFrom-Json
            if ($pkg.version) {
                $lblVer.Text = 'v' + $pkg.version
                $lblVerAbout.Text = '版本 v' + $pkg.version
            }
        }
    } catch {}

    # 统计：控制台打开次数 +1 + 显示使用统计
    Add-OrcaStat -Launch
    try {
        $s = Get-OrcaStats
        $lblStats.Text = '🐋 已启动 ' + [int]$s.launchCount + ' 次 · 服务器启动 ' + [int]$s.serverStarts + ' 次 · 累计运行 ' + (Format-RunDuration ([long]$s.totalRunSeconds))
    } catch {}

    Update-StatusDisplay
    $refreshTimer.Start()
    $lblStatus.Text = '就绪'

    # 淡入动画
    $root = $window.FindName('Root')
    $root.Opacity = 0
    $anim = New-Object System.Windows.Media.Animation.DoubleAnimation
    $anim.From = 0
    $anim.To = 1
    $anim.Duration = [TimeSpan]::FromMilliseconds(200)
    $root.BeginAnimation([System.Windows.Controls.Control]::OpacityProperty, $anim)
})

$window.ShowDialog() | Out-Null
