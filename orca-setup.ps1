# ============================================================
#  Orca DSH Launcher - 一键安装引导器（orca-setup）
# ============================================================
#  这是给"完全没装过 DSH 的电脑"用的安装向导：
#   1. 欢迎页
#   2. 环境检测（Node.js / Git / pnpm 缺什么告诉你去哪装）
#   3. 网络检测（能否访问 GitHub，网络不好会明确提示）
#   4. 选择安装位置（DSH 装到哪个文件夹，你说了算）
#   5. 下载并安装最新版 DSH（git clone + pnpm install）
#   6. 自动装好本插件（Orca 托盘 + 控制台 + /orca 命令）
#   7. 启动 DSH 并打开网页界面
#
#  用法：
#   双击运行，或
#     powershell -NoProfile -ExecutionPolicy Bypass -File orca-setup.ps1
#  自检模式（供测试脚本用，不弹窗口）：
#     powershell -NoProfile -ExecutionPolicy Bypass -File orca-setup.ps1 -QuickCheck
#
#  注意：本文件必须保存为 UTF-8 带 BOM（PowerShell 5.1 才能
#        正确解析中文）。
# ============================================================
$ErrorActionPreference = 'Stop'

# ============================================================
#  一、加载公共安装逻辑库 + 全局状态
# ============================================================

# 插件包（plugin.js + package.json + orca\ 全部文件）的 Base64。
# 由 build-exe.ps1 打包时自动注入；直接运行本 ps1 时保持占位符，
# 程序会改从脚本所在目录读取插件文件（开发模式）。
$script:SetupPayloadB64 = '__PLUGIN_PAYLOAD_B64__'

# 加载安装核心逻辑库（环境/网络检测、clone、install+build、npx web、装插件）
. (Join-Path $PSScriptRoot 'orca\orca-install.ps1')

# 用本向导的 payload 覆盖库里的占位符（打包版才有真实值）
$script:PluginPayloadB64 = $script:SetupPayloadB64

# 安装日志文件（独立文件，避免和控制台共用日志打架）
$script:InstallLogFile = Join-Path $env:TEMP 'orca-setup-install.log'

# 本脚本所在目录（顶层计算一次；事件处理器里 $MyInvocation.MyCommand.Path 是空的，不能在那用）
$script:SetupScriptDir = $null
try { $script:SetupScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path } catch {}
if (-not $script:SetupScriptDir) { $script:SetupScriptDir = $PSScriptRoot }

$script:DshDir     = ''            # 用户选择的 DSH 安装目录
$script:Phase      = 'idle'        # idle / cloning / installing / building / finishing / done / failed
$script:PhaseError = ''
$script:Proc       = $null         # 当前正在跑的安装子进程
$script:SkipClone  = $false        # 目录里已有 DSH，跳过下载

# （工具函数 / 插件包来源 / 插件安装等公共逻辑全部在 orca-install.ps1 里，
#   本向导和图形控制台共用同一份，改逻辑只改一处）

# ============================================================
#  二、安装流程编排（向导专用，公共逻辑在 orca-install.ps1）
# ============================================================

# ============================================================
#  三、自检模式（供测试脚本用，不弹窗口，输出 JSON 后退出）
# ============================================================
if ($args -contains '-QuickCheck') {
    try {
        $nodeVer = Get-CommandVersion 'node'
        $gitVer  = Get-CommandVersion 'git'
        $pnpmVer = Get-CommandVersion 'pnpm'
        $net = Test-GithubNetwork
        [pscustomobject]@{
            ok       = $true
            node     = if ($nodeVer) { $nodeVer } else { $null }
            git      = if ($gitVer)  { $gitVer }  else { $null }
            pnpm     = if ($pnpmVer) { $pnpmVer } else { $null }
            githubOk = $net.githubOk
        } | ConvertTo-Json
    } catch {
        [pscustomobject]@{ ok = $false; error = $_.Exception.Message } | ConvertTo-Json
        exit 1
    }
    exit 0
}

# ============================================================
#  六、界面（WPF，深色主题，和图形控制台同一风格）
# ============================================================
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms   # FolderBrowserDialog 用

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        x:Name="MainWindow"
        Title="Orca DSH Launcher 一键安装"
        Width="760" Height="560"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        ResizeMode="NoResize" WindowStartupLocation="CenterScreen"
        FontFamily="Microsoft YaHei UI">
  <Window.Resources>
    <SolidColorBrush x:Key="ColorBg" Color="#101010"/>
    <SolidColorBrush x:Key="ColorBorder" Color="#2A2A2A"/>
    <SolidColorBrush x:Key="ColorCard" Color="#1E1E1E"/>
    <SolidColorBrush x:Key="ColorTextPrimary" Color="#F0F0F0"/>
    <SolidColorBrush x:Key="ColorTextSecondary" Color="#9A9A9A"/>
    <SolidColorBrush x:Key="ColorTextMuted" Color="#888888"/>
    <SolidColorBrush x:Key="ColorAccent" Color="#36D199"/>
    <SolidColorBrush x:Key="ColorOkFg" Color="#36D199"/>
    <SolidColorBrush x:Key="ColorWarnFg" Color="#E8B34A"/>
    <SolidColorBrush x:Key="ColorErrFg" Color="#E07A7A"/>
    <SolidColorBrush x:Key="ColorBtnPrimaryBg" Color="#F0F0F0"/>
    <SolidColorBrush x:Key="ColorBtnPrimaryFg" Color="#101010"/>
    <SolidColorBrush x:Key="ColorBtnSecondaryBg" Color="#2D2D2D"/>
    <SolidColorBrush x:Key="ColorBtnSecondaryFg" Color="#E0E0E0"/>
    <Style x:Key="PrimaryButton" TargetType="Button">
      <Setter Property="Background" Value="{DynamicResource ColorBtnPrimaryBg}"/>
      <Setter Property="Foreground" Value="{DynamicResource ColorBtnPrimaryFg}"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="FontSize" Value="14"/>
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
                <Setter TargetName="bd" Property="Background" Value="#FFFFFF"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#D8D8D8"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="bd" Property="Background" Value="#1E1E1E"/>
                <Setter Property="Foreground" Value="#555555"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
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
                <Setter TargetName="bd" Property="Background" Value="#3A3A3A"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="bd" Property="Background" Value="#1E1E1E"/>
                <Setter Property="Foreground" Value="#555555"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="NavButton" TargetType="Button">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="{DynamicResource ColorTextSecondary}"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Height" Value="34"/>
      <Setter Property="Margin" Value="4,2"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="HorizontalContentAlignment" Value="Left"/>
      <Setter Property="Padding" Value="12,0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="6">
              <ContentPresenter Margin="{TemplateBinding Padding}" HorizontalAlignment="Left" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#2A2A2A"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="WindowButton" TargetType="Button">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="#9AA0B5"/>
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
                <Setter TargetName="bd" Property="Background" Value="#2A2A2A"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Border x:Name="Root" CornerRadius="8" Background="{DynamicResource ColorBg}" BorderThickness="1" BorderBrush="{DynamicResource ColorBorder}">
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="44"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="56"/>
      </Grid.RowDefinitions>

      <!-- 顶部标题栏（可拖动） -->
      <Grid x:Name="titleBar" Grid.Row="0" Background="Transparent">
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center" Margin="16,0,0,0">
          <TextBlock Text="🐋" FontSize="18" VerticalAlignment="Center"/>
          <TextBlock Text="Orca DSH Launcher 一键安装" FontSize="14" FontWeight="Bold" Foreground="{DynamicResource ColorTextPrimary}" Margin="8,0,0,0" VerticalAlignment="Center"/>
        </StackPanel>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,8,0">
          <Button x:Name="btnMin" Content="—" Style="{StaticResource WindowButton}" Width="34" Height="26"/>
          <Button x:Name="btnClose" Content="✕" Style="{StaticResource WindowButton}" Width="34" Height="26" Margin="4,0,0,0"/>
        </StackPanel>
      </Grid>

      <!-- 主体：步骤条 + 页面 -->
      <Grid Grid.Row="1">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>
        <!-- 步骤指示条 -->
        <StackPanel x:Name="stepBar" Orientation="Horizontal" Margin="24,14,24,0">
          <TextBlock x:Name="step1" Text="1 欢迎" FontSize="11" Foreground="{DynamicResource ColorAccent}"/>
          <TextBlock Text="  ›  " FontSize="11" Foreground="{DynamicResource ColorTextMuted}"/>
          <TextBlock x:Name="step2" Text="2 环境" FontSize="11" Foreground="{DynamicResource ColorTextMuted}"/>
          <TextBlock Text="  ›  " FontSize="11" Foreground="{DynamicResource ColorTextMuted}"/>
          <TextBlock x:Name="step3" Text="3 网络" FontSize="11" Foreground="{DynamicResource ColorTextMuted}"/>
          <TextBlock Text="  ›  " FontSize="11" Foreground="{DynamicResource ColorTextMuted}"/>
          <TextBlock x:Name="step4" Text="4 位置" FontSize="11" Foreground="{DynamicResource ColorTextMuted}"/>
          <TextBlock Text="  ›  " FontSize="11" Foreground="{DynamicResource ColorTextMuted}"/>
          <TextBlock x:Name="step5" Text="5 安装" FontSize="11" Foreground="{DynamicResource ColorTextMuted}"/>
        </StackPanel>

        <Grid Grid.Row="1" Margin="24,10,24,0">
          <!-- ═══ 1 欢迎页 ═══ -->
          <StackPanel x:Name="pageWelcome">
            <TextBlock Text="欢迎使用 Orca DSH Launcher" FontSize="24" FontWeight="Bold" Foreground="{DynamicResource ColorTextPrimary}"/>
            <TextBlock Text="帮你在一台电脑上，从零装好 DeepSeek Harness（DSH）" FontSize="13" Foreground="{DynamicResource ColorTextSecondary}" Margin="0,8,0,0" TextWrapping="Wrap"/>
            <Border CornerRadius="6" Background="{DynamicResource ColorCard}" Padding="16,14" Margin="0,20,0,0">
              <StackPanel>
                <TextBlock Text="这个向导会帮你完成：" FontSize="13" Foreground="{DynamicResource ColorTextPrimary}"/>
                <TextBlock Text="① 检查电脑环境（缺什么会告诉你去哪装）" FontSize="12" Foreground="{DynamicResource ColorTextSecondary}" Margin="0,8,0,0"/>
                <TextBlock Text="② 检查网络能否访问 GitHub（网络不好会明确提示）" FontSize="12" Foreground="{DynamicResource ColorTextSecondary}" Margin="0,4,0,0"/>
                <TextBlock Text="③ 让你选择把 DSH 装到哪个文件夹" FontSize="12" Foreground="{DynamicResource ColorTextSecondary}" Margin="0,4,0,0"/>
                <TextBlock Text="④ 自动下载、安装最新版 DSH" FontSize="12" Foreground="{DynamicResource ColorTextSecondary}" Margin="0,4,0,0"/>
                <TextBlock Text="⑤ 自动装好本插件（托盘 + 控制台 + 命令）并打开界面" FontSize="12" Foreground="{DynamicResource ColorTextSecondary}" Margin="0,4,0,0"/>
              </StackPanel>
            </Border>
            <TextBlock Text="整个过程中，你的电脑不会被偷偷改动——每一步都清清楚楚。" FontSize="11" Foreground="{DynamicResource ColorTextMuted}" Margin="0,12,0,0" TextWrapping="Wrap"/>
            <StackPanel Orientation="Horizontal" Margin="0,24,0,0">
              <Button x:Name="btnWelcomeNext" Content="开始安装 ›" Style="{StaticResource PrimaryButton}" Width="150" Height="40"/>
            </StackPanel>
          </StackPanel>

          <!-- ═══ 2 环境检测页 ═══ -->
          <StackPanel x:Name="pageEnv" Visibility="Collapsed">
            <TextBlock Text="检查电脑环境" FontSize="22" FontWeight="Bold" Foreground="{DynamicResource ColorTextPrimary}"/>
            <TextBlock Text="安装 DSH 需要 Node.js、Git 和 pnpm，缺哪个装哪个" FontSize="12" Foreground="{DynamicResource ColorTextSecondary}" Margin="0,6,0,0"/>
            <Border CornerRadius="6" Background="{DynamicResource ColorCard}" Padding="16,14" Margin="0,18,0,0">
              <StackPanel>
                <Grid>
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="130"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                  </Grid.ColumnDefinitions>
                  <TextBlock x:Name="envNodeName" Text="Node.js" FontSize="13" Foreground="{DynamicResource ColorTextPrimary}" VerticalAlignment="Center"/>
                  <TextBlock x:Name="envNodeVer" Grid.Column="1" Text="检查中…" FontSize="12" Foreground="{DynamicResource ColorTextSecondary}" VerticalAlignment="Center"/>
                  <TextBlock x:Name="envNodeTag" Grid.Column="2" Text="…" FontSize="12" FontWeight="Bold" VerticalAlignment="Center"/>
                </Grid>
                <Grid Margin="0,14,0,0">
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="130"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                  </Grid.ColumnDefinitions>
                  <TextBlock Text="Git" FontSize="13" Foreground="{DynamicResource ColorTextPrimary}" VerticalAlignment="Center"/>
                  <TextBlock x:Name="envGitVer" Grid.Column="1" Text="检查中…" FontSize="12" Foreground="{DynamicResource ColorTextSecondary}" VerticalAlignment="Center"/>
                  <TextBlock x:Name="envGitTag" Grid.Column="2" Text="…" FontSize="12" FontWeight="Bold" VerticalAlignment="Center"/>
                </Grid>
                <Grid Margin="0,14,0,0">
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="130"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                  </Grid.ColumnDefinitions>
                  <TextBlock Text="pnpm" FontSize="13" Foreground="{DynamicResource ColorTextPrimary}" VerticalAlignment="Center"/>
                  <TextBlock x:Name="envPnpmVer" Grid.Column="1" Text="检查中…" FontSize="12" Foreground="{DynamicResource ColorTextSecondary}" VerticalAlignment="Center"/>
                  <TextBlock x:Name="envPnpmTag" Grid.Column="2" Text="…" FontSize="12" FontWeight="Bold" VerticalAlignment="Center"/>
                </Grid>
              </StackPanel>
            </Border>
            <TextBlock x:Name="envHelp" Text="" FontSize="11" Foreground="{DynamicResource ColorWarnFg}" Margin="0,12,0,0" TextWrapping="Wrap"/>
            <StackPanel Orientation="Horizontal" Margin="0,18,0,0">
              <Button x:Name="btnEnvRetry" Content="重新检测" Style="{StaticResource SecondaryButton}" Width="110" Height="36"/>
              <Button x:Name="btnEnvNext" Content="下一步 ›" Style="{StaticResource PrimaryButton}" Width="130" Height="36" Margin="10,0,0,0"/>
            </StackPanel>
          </StackPanel>

          <!-- ═══ 3 网络检测页 ═══ -->
          <StackPanel x:Name="pageNet" Visibility="Collapsed">
            <TextBlock Text="检查网络" FontSize="22" FontWeight="Bold" Foreground="{DynamicResource ColorTextPrimary}"/>
            <TextBlock Text="下载 DSH 需要能访问 GitHub，先测一下" FontSize="12" Foreground="{DynamicResource ColorTextSecondary}" Margin="0,6,0,0"/>
            <Border CornerRadius="6" Background="{DynamicResource ColorCard}" Padding="16,14" Margin="0,18,0,0">
              <StackPanel>
                <Grid>
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                  </Grid.ColumnDefinitions>
                  <TextBlock Text="能否访问 GitHub" FontSize="14" FontWeight="Bold" Foreground="{DynamicResource ColorTextPrimary}"/>
                  <TextBlock x:Name="netTag" Grid.Column="1" Text="检测中…" FontSize="13" FontWeight="Bold"/>
                </Grid>
                <TextBlock x:Name="netDetail" Text="" FontSize="12" Foreground="{DynamicResource ColorTextSecondary}" Margin="0,10,0,0" TextWrapping="Wrap"/>
              </StackPanel>
            </Border>
            <TextBlock x:Name="netHelp" Text="" FontSize="11" Foreground="{DynamicResource ColorWarnFg}" Margin="0,12,0,0" TextWrapping="Wrap"/>
            <StackPanel Orientation="Horizontal" Margin="0,18,0,0">
              <Button x:Name="btnNetRetry" Content="重新检测" Style="{StaticResource SecondaryButton}" Width="110" Height="36"/>
              <Button x:Name="btnNetNext" Content="下一步 ›" Style="{StaticResource PrimaryButton}" Width="130" Height="36" Margin="10,0,0,0"/>
            </StackPanel>
          </StackPanel>

          <!-- ═══ 4 选择位置页 ═══ -->
          <StackPanel x:Name="pageDir" Visibility="Collapsed">
            <TextBlock Text="选择安装位置" FontSize="22" FontWeight="Bold" Foreground="{DynamicResource ColorTextPrimary}"/>
            <TextBlock Text="DSH 会被装到你选的文件夹里（会自动创建一个 deepseek-harness 子文件夹）" FontSize="12" Foreground="{DynamicResource ColorTextSecondary}" Margin="0,6,0,0" TextWrapping="Wrap"/>
            <Border CornerRadius="6" Background="{DynamicResource ColorCard}" Padding="16,14" Margin="0,18,0,0">
              <StackPanel>
                <TextBlock Text="安装位置" FontSize="12" Foreground="{DynamicResource ColorTextMuted}"/>
                <Grid Margin="0,8,0,0">
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                  </Grid.ColumnDefinitions>
                  <Border Background="#1E1E1E" BorderBrush="#3A3A3A" BorderThickness="1" CornerRadius="4" Padding="10,8">
                    <TextBlock x:Name="dirPath" Text="（还没有选择）" FontSize="12" Foreground="{DynamicResource ColorTextSecondary}" TextTrimming="CharacterEllipsis"/>
                  </Border>
                  <Button x:Name="btnBrowse" Grid.Column="1" Content="选择文件夹…" Style="{StaticResource SecondaryButton}" Width="120" Height="32" Margin="10,0,0,0"/>
                </Grid>
                <TextBlock x:Name="dirHint" Text="默认位置：D:\deepseek-harness" FontSize="11" Foreground="{DynamicResource ColorTextMuted}" Margin="0,10,0,0"/>
              </StackPanel>
            </Border>
            <StackPanel Orientation="Horizontal" Margin="0,18,0,0">
              <Button x:Name="btnDirBack" Content="‹ 上一步" Style="{StaticResource SecondaryButton}" Width="110" Height="36"/>
              <Button x:Name="btnDirNext" Content="开始安装 ›" Style="{StaticResource PrimaryButton}" Width="130" Height="36" Margin="10,0,0,0"/>
            </StackPanel>
          </StackPanel>

          <!-- ═══ 5 安装页 ═══ -->
          <StackPanel x:Name="pageInstall" Visibility="Collapsed">
            <TextBlock x:Name="installTitle" Text="开始安装" FontSize="22" FontWeight="Bold" Foreground="{DynamicResource ColorTextPrimary}"/>
            <TextBlock x:Name="installStatus" Text="准备中…" FontSize="13" Foreground="{DynamicResource ColorAccent}" Margin="0,8,0,0"/>
            <TextBox x:Name="txtLog" IsReadOnly="True" FontFamily="Consolas" FontSize="11"
                     Background="#12141C" Foreground="#D0D7E5" BorderBrush="#2A2D42" BorderThickness="1"
                     Padding="10,8" TextWrapping="NoWrap" AcceptsReturn="True"
                     VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"
                     Height="300" Margin="0,14,0,0"/>
            <StackPanel Orientation="Horizontal" Margin="0,12,0,0">
              <Button x:Name="btnInstallBack" Content="‹ 上一步" Style="{StaticResource SecondaryButton}" Width="100" Height="34"/>
              <Button x:Name="btnCancelInstall" Content="取消安装" Style="{StaticResource SecondaryButton}" Width="110" Height="34" Margin="10,0,0,0"/>
              <Button x:Name="btnInstallNext" Content="下一步 ›" Style="{StaticResource PrimaryButton}" Width="130" Height="34" Margin="10,0,0,0" IsEnabled="False"/>
            </StackPanel>
          </StackPanel>

          <!-- ═══ 6 完成页 ═══ -->
          <StackPanel x:Name="pageDone" Visibility="Collapsed">
            <TextBlock Text="🎉 安装完成！" FontSize="24" FontWeight="Bold" Foreground="{DynamicResource ColorAccent}"/>
            <TextBlock x:Name="doneSummary" Text="" FontSize="13" Foreground="{DynamicResource ColorTextSecondary}" Margin="0,10,0,0" TextWrapping="Wrap"/>
            <Border CornerRadius="6" Background="{DynamicResource ColorCard}" Padding="16,14" Margin="0,18,0,0">
              <StackPanel>
                <TextBlock x:Name="doneDetail" Text="" FontSize="12" Foreground="{DynamicResource ColorTextPrimary}" TextWrapping="Wrap"/>
              </StackPanel>
            </Border>
            <StackPanel Orientation="Horizontal" Margin="0,22,0,0">
              <Button x:Name="btnLaunch" Content="🚀 启动 DSH 并打开界面" Style="{StaticResource PrimaryButton}" Width="220" Height="40"/>
              <Button x:Name="btnDoneClose" Content="完成" Style="{StaticResource SecondaryButton}" Width="110" Height="40" Margin="10,0,0,0"/>
            </StackPanel>
          </StackPanel>
        </Grid>
      </Grid>

      <!-- 底部状态栏 -->
      <TextBlock x:Name="lblStatus" Grid.Row="2" Text="就绪" FontSize="12" Foreground="{DynamicResource ColorTextSecondary}" Margin="24,0,24,20"/>
    </Grid>
  </Border>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader($xaml)
$window = [System.Windows.Markup.XamlReader]::Load($reader)

# 取控件
$titleBar      = $window.FindName('titleBar')
$btnMin        = $window.FindName('btnMin')
$btnClose      = $window.FindName('btnClose')
$step1 = $window.FindName('step1'); $step2 = $window.FindName('step2')
$step3 = $window.FindName('step3'); $step4 = $window.FindName('step4'); $step5 = $window.FindName('step5')
$pageWelcome = $window.FindName('pageWelcome')
$pageEnv     = $window.FindName('pageEnv')
$pageNet     = $window.FindName('pageNet')
$pageDir     = $window.FindName('pageDir')
$pageInstall = $window.FindName('pageInstall')
$pageDone    = $window.FindName('pageDone')
$envNodeVer = $window.FindName('envNodeVer'); $envNodeTag = $window.FindName('envNodeTag')
$envGitVer  = $window.FindName('envGitVer');  $envGitTag  = $window.FindName('envGitTag')
$envPnpmVer = $window.FindName('envPnpmVer'); $envPnpmTag = $window.FindName('envPnpmTag')
$envHelp    = $window.FindName('envHelp')
$btnEnvRetry = $window.FindName('btnEnvRetry'); $btnEnvNext = $window.FindName('btnEnvNext')
$btnWelcomeNext = $window.FindName('btnWelcomeNext')
$netTag   = $window.FindName('netTag');  $netDetail = $window.FindName('netDetail'); $netHelp = $window.FindName('netHelp')
$btnNetRetry = $window.FindName('btnNetRetry'); $btnNetNext = $window.FindName('btnNetNext')
$dirPath = $window.FindName('dirPath'); $dirHint = $window.FindName('dirHint')
$btnBrowse = $window.FindName('btnBrowse'); $btnDirBack = $window.FindName('btnDirBack'); $btnDirNext = $window.FindName('btnDirNext')
$installTitle = $window.FindName('installTitle'); $installStatus = $window.FindName('installStatus')
$txtLog = $window.FindName('txtLog')
$btnCancelInstall = $window.FindName('btnCancelInstall'); $btnInstallNext = $window.FindName('btnInstallNext')
$btnInstallBack = $window.FindName('btnInstallBack')
$doneSummary = $window.FindName('doneSummary'); $doneDetail = $window.FindName('doneDetail')
$btnLaunch = $window.FindName('btnLaunch'); $btnDoneClose = $window.FindName('btnDoneClose')
$lblStatus = $window.FindName('lblStatus')

# ---------- 全局状态 ----------
$script:netResult = $null        # 网络检测结果
$script:envOk     = $false       # 环境是否齐全
$script:pluginSource = $null     # 插件包来源目录

# ---------- 页面切换 ----------
function Show-SetupPage {
    param([string]$Name)
    $pages = @{
        welcome = $pageWelcome; env = $pageEnv; net = $pageNet
        dir = $pageDir; install = $pageInstall; done = $pageDone
    }
    foreach ($k in $pages.Keys) {
        $pages[$k].Visibility = if ($k -eq $Name) { 'Visible' } else { 'Collapsed' }
    }
    # 步骤指示
    $steps = @{ welcome = $step1; env = $step2; net = $step3; dir = $step4; install = $step5; done = $step5 }
    foreach ($k in $steps.Keys) {
        if ($k -eq $Name) {
            $steps[$k].Foreground = $window.Resources['ColorAccent']
            $steps[$k].FontWeight = 'Bold'
        } else {
            $steps[$k].Foreground = $window.Resources['ColorTextMuted']
            $steps[$k].FontWeight = 'Normal'
        }
    }
}

# 设置状态栏
function Set-Status([string]$Text) { $lblStatus.Text = $Text }

# ---------- 标题栏 / 窗口按钮 ----------
$titleBar.Add_MouseLeftButtonDown({
    param($s, $e)
    if ($e.LeftButton -eq 'Pressed') { try { $window.DragMove() } catch {} }
})
$btnMin.Add_Click({ $window.WindowState = 'Minimized' })
$btnClose.Add_Click({
    # 安装过程中不允许直接关（会打断安装）
    if ($script:Phase -in @('cloning','installing','finishing')) {
        [System.Windows.MessageBox]::Show('正在安装中，请先点击「取消安装」。', 'Orca DSH Launcher', 'OK', 'Information') | Out-Null
    } else {
        $window.Close()
    }
})

# ---------- 欢迎页 ----------
$btnWelcomeNext.Add_Click({
    Show-SetupPage 'env'
    Start-EnvCheck
})

# ---------- 环境检测 ----------
function Start-EnvCheck {
    Set-Status '正在检查电脑环境…'
    $envNodeTag.Text = '…'; $envGitTag.Text = '…'; $envPnpmTag.Text = '…'
    $envNodeVer.Text = '检查中…'; $envGitVer.Text = '检查中…'; $envPnpmVer.Text = '检查中…'
    $envHelp.Text = ''
    $nodeVer = Get-CommandVersion 'node'
    $gitVer  = Get-CommandVersion 'git'
    $pnpmVer = Get-CommandVersion 'pnpm'

    # 有 Node 但没有 pnpm 时，尝试用 corepack 自动启用（Node 自带）
    if ($nodeVer -and -not $pnpmVer) {
        try {
            $out = & corepack enable pnpm 2>&1
            if ($LASTEXITCODE -eq 0) { $pnpmVer = Get-CommandVersion 'pnpm' }
        } catch {}
    }

    $envNodeVer.Text = if ($nodeVer) { $nodeVer } else { '未安装' }
    $envGitVer.Text  = if ($gitVer)  { $gitVer }  else { '未安装' }
    $envPnpmVer.Text = if ($pnpmVer) { $pnpmVer } else { '未安装' }

    $envNodeTag.Text = if ($nodeVer) { '✅' } else { '❌' }
    $envNodeTag.Foreground = $window.Resources[$(if ($nodeVer) { 'ColorOkFg' } else { 'ColorErrFg' })]
    $envGitTag.Text = if ($gitVer) { '✅' } else { '❌' }
    $envGitTag.Foreground = $window.Resources[$(if ($gitVer) { 'ColorOkFg' } else { 'ColorErrFg' })]
    $envPnpmTag.Text = if ($pnpmVer) { '✅' } else { '❌' }
    $envPnpmTag.Foreground = $window.Resources[$(if ($pnpmVer) { 'ColorOkFg' } else { 'ColorErrFg' })]

    $missing = @()
    if (-not $nodeVer) { $missing += 'Node.js（下载地址：https://nodejs.org/zh-cn，装完重启本向导）' }
    if (-not $gitVer)  { $missing += 'Git（下载地址：https://git-scm.com/download/win，一路下一步装完）' }
    if (-not $pnpmVer) { $missing += 'pnpm（装好 Node.js 后，在命令提示符里输入：npm install -g pnpm）' }

    $script:envOk = ($missing.Count -eq 0)
    if ($missing.Count -gt 0) {
        $envHelp.Text = '还需要安装：' + ($missing -join '；')
        $envHelp.Foreground = $window.Resources['ColorWarnFg']
    } else {
        $envHelp.Text = '环境齐全，可以继续！'
        $envHelp.Foreground = $window.Resources['ColorOkFg']
    }
    Set-Status '环境检测完成'
}

$btnEnvRetry.Add_Click({ Start-EnvCheck })
$btnEnvNext.Add_Click({
    if (-not $script:envOk) {
        [System.Windows.MessageBox]::Show('还有东西没装好，先装好再继续哦。', 'Orca DSH Launcher', 'OK', 'Warning') | Out-Null
        return
    }
    Show-SetupPage 'net'
    Start-NetCheck
})

# ---------- 网络检测 ----------
function Start-NetCheck {
    Set-Status '正在检测网络…（需要几秒钟）'
    $netTag.Text = '检测中…'
    $netTag.Foreground = $window.Resources['ColorTextSecondary']
    $netDetail.Text = ''
    $netHelp.Text = ''
    $script:netResult = Test-GithubNetwork
    $r = $script:netResult
    $netDetail.Text = '测试结果：' + $r.detail
    if ($r.githubOk) {
        $netTag.Text = '✅ 网络良好'
        $netTag.Foreground = $window.Resources['ColorOkFg']
        $netHelp.Text = '可以正常下载 DSH，继续吧！'
        $netHelp.Foreground = $window.Resources['ColorOkFg']
        $btnNetNext.IsEnabled = $true
    } elseif ($r.github -or $r.codeload) {
        $netTag.Text = '⚠️ 网络部分受限'
        $netTag.Foreground = $window.Resources['ColorWarnFg']
        $netHelp.Text = 'GitHub 部分地址连不上，下载可能很慢或中途失败。建议：检查代理/VPN 设置，或换网络后重试。也可以先继续，失败了再回来处理。'
        $netHelp.Foreground = $window.Resources['ColorWarnFg']
        $btnNetNext.IsEnabled = $true
    } else {
        $netTag.Text = '❌ 无法访问 GitHub'
        $netTag.Foreground = $window.Resources['ColorErrFg']
        $netHelp.Text = '当前网络访问不了 GitHub，下载会失败。建议：① 检查是否开了代理/VPN（关掉或换节点试试）；② 更换网络（如手机热点）；③ 联系网络管理员。解决后点「重新检测」。'
        $netHelp.Foreground = $window.Resources['ColorErrFg']
        $btnNetNext.IsEnabled = $false
    }
    Set-Status '网络检测完成'
}

$btnNetRetry.Add_Click({ Start-NetCheck })
$btnNetNext.Add_Click({
    Show-SetupPage 'dir'
    # 默认位置（可用环境变量 ORCA_SETUP_DEFAULT_DIR 覆盖，供自动化测试用临时目录）
    $default = if ($env:ORCA_SETUP_DEFAULT_DIR) {
        Join-Path $env:ORCA_SETUP_DEFAULT_DIR 'deepseek-harness'
    } else {
        Join-Path 'D:\' 'deepseek-harness'
    }
    $dirHint.Text = '默认位置：' + $default + '（也可以点「选择文件夹…」自己定）'
    if (-not $script:DshDir) { $script:DshDir = $default }
    $dirPath.Text = $script:DshDir
    $dirPath.Foreground = $window.Resources['ColorTextPrimary']
})

# ---------- 选择位置 ----------
$btnBrowse.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = '选择 DSH 要安装到的文件夹'
    $dlg.ShowNewFolderButton = $true
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $script:DshDir = Join-Path $dlg.SelectedPath 'deepseek-harness'
        $dirPath.Text = $script:DshDir
        $dirPath.Foreground = $window.Resources['ColorTextPrimary']
    }
})
$btnDirBack.Add_Click({ Show-SetupPage 'net' })
$btnDirNext.Add_Click({
    if (-not $script:DshDir) {
        [System.Windows.MessageBox]::Show('请先选择一个安装位置。', 'Orca DSH Launcher', 'OK', 'Warning') | Out-Null
        return
    }
    # 插件包来源检查
    $script:pluginSource = Get-PluginSource -FallbackDir $script:SetupScriptDir
    if (-not $script:pluginSource) {
        [System.Windows.MessageBox]::Show('找不到插件文件包，请重新下载本程序后再试。', 'Orca DSH Launcher', 'OK', 'Error') | Out-Null
        return
    }
    Show-SetupPage 'install'
    Start-Install
})

# 启动已安装的 DSH 并打开浏览器（完成页按钮用）
function Start-DshAndOpen {
    param([string]$DshDir, [int]$Port = 3080)
    $r = Start-DshFromDir -DshDir $DshDir -Port $Port
    if (-not $r.ok) { return $false }
    if (Wait-PortReady -Port $Port -TimeoutSeconds 120) {
        Start-Process "http://127.0.0.1:$Port"
        return $true
    }
    return $false
}

# ---------- 安装流程（状态机：cloning → installing → building → finishing → done） ----------
function Start-Install {
    $script:Phase = 'idle'
    $installTitle.Text = '开始安装'
    $installStatus.Text = '准备中…'
    $installStatus.Foreground = $window.Resources['ColorAccent']
    $btnCancelInstall.IsEnabled = $true
    $btnInstallBack.IsEnabled = $true
    $btnInstallNext.IsEnabled = $false
    # 清空旧日志
    try { Remove-Item $script:InstallLogFile -Force -ErrorAction SilentlyContinue } catch {}

    $dshDir = $script:DshDir
    # 记录"安装开始前这个目录是否存在"——不存在 = 本次安装创建的，取消时可安全删除
    $script:DirExistedBefore = Test-Path $dshDir

    # 0) 准备目录
    $parent = Split-Path -Parent $dshDir
    if (-not (Test-Path $parent)) {
        # 父目录不存在时自动创建（避免小白因奇怪路径卡住）
        try {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
            Write-SetupLog ('[安装] 自动创建了文件夹：' + $parent)
        } catch {
            $installStatus.Text = '❌ 无法创建文件夹：' + $parent
            $script:Phase = 'failed'
            $script:PhaseError = '无法创建文件夹：' + $parent
            return
        }
    }

    # 1) 下载 DSH（git clone；目录里已有 .git 会自动跳过）
    $clone = Install-DshClone -DshDir $dshDir
    if (-not $clone.ok) {
        $installStatus.Text = '❌ ' + $clone.error
        $script:Phase = 'failed'
        $script:PhaseError = $clone.error
        return
    }
    if ($null -ne $clone.proc) {
        $script:Phase = 'cloning'
        $installStatus.Text = '正在下载 DSH 源码（git clone，取决于网速，请耐心等待）…'
        $script:Proc = $clone.proc
        $tickTimer.Start()
        return
    }

    # 目录已就绪，直接装依赖
    Start-PnpmInstall
}

# 装依赖（pnpm install）
function Start-PnpmInstall {
    $script:Phase = 'installing'
    $installStatus.Text = '正在安装依赖（pnpm install，通常需要 10~30 分钟，请耐心等待）…'
    $deps = Install-DshDeps -DshDir $script:DshDir
    if (-not $deps.ok) {
        $installStatus.Text = '❌ ' + $deps.error
        $script:Phase = 'failed'
        $script:PhaseError = $deps.error
        return
    }
    $script:Proc = $deps.proc
    $tickTimer.Start()
}

# 构建（pnpm run build，官方流程的一步）
function Begin-BuildPhase {
    $script:Phase = 'building'
    $installStatus.Text = '正在构建 DSH（pnpm run build，需要几分钟，请耐心等待）…'
    $script:Proc = Start-DshBuild -DshDir $script:DshDir
    $tickTimer.Start()
}

# 收尾：装插件 + 快捷方式
function Finish-Install {
    $script:Phase = 'finishing'
    $installStatus.Text = '正在安装 Orca 插件…'
    Write-SetupLog ''
    Write-SetupLog '第 4 步：安装 Orca DSH Launcher 插件'
    try {
        Install-OrcaPlugin -PluginSource $script:pluginSource -DshDir $script:DshDir | Out-Null
        $targetDir = Join-Path $env:USERPROFILE '.dsh\profiles\web\node_modules\orca-dsh-launcher'
        New-DesktopShortcut -PluginTargetDir $targetDir | Out-Null
        Write-SetupLog '[插件] 桌面图标已创建'
    } catch {
        Write-SetupLog ('[插件] 安装失败：' + $_.Exception.Message)
    }
    $script:Phase = 'done'
    $installStatus.Text = '✅ 安装完成！'
    $installStatus.Foreground = $window.Resources['ColorOkFg']
    $btnCancelInstall.IsEnabled = $false
    $btnInstallBack.IsEnabled = $false
    $btnInstallNext.IsEnabled = $true
    $tickTimer.Stop()
    # 显示完成页内容
    $doneSummary.Text = 'DSH 已装好，Orca 插件也已就位。'
    $doneDetail.Text = 'DSH 位置：' + $script:DshDir + "`n" + '插件位置：' + (Join-Path $env:USERPROFILE '.dsh\profiles\web\node_modules\orca-dsh-launcher') + "`n" + '以后在 DSH 里输入 /orca 就能用各种命令，右下角会有虎鲸托盘。'
    Set-Status '全部完成'
}

# 定时器：盯安装进程 + 刷新日志
$tickTimer = New-Object System.Windows.Threading.DispatcherTimer
$tickTimer.Interval = [TimeSpan]::FromMilliseconds(800)
$tickTimer.Add_Tick({
    # 刷新日志显示
    $lines = Get-SetupLogTail -Lines 100
    if ($lines.Count -gt 0) {
        $txtLog.Text = ($lines -join "`n")
        $txtLog.ScrollToEnd()
    }
    # 进程还在跑 → 等下一轮
    if ($script:Proc -and -not $script:Proc.HasExited) { return }

    if ($script:Phase -eq 'cloning') {
        if ($script:Proc.ExitCode -eq 0) {
            $installStatus.Text = '✅ DSH 源码下载完成'
            Start-PnpmInstall
        } else {
            $script:Phase = 'failed'
            $script:PhaseError = '下载 DSH 失败（退出码 ' + $script:Proc.ExitCode + '），请查看上方日志，检查网络后重试。'
            $installStatus.Text = '❌ 下载失败'
            $installStatus.Foreground = $window.Resources['ColorErrFg']
            $btnCancelInstall.IsEnabled = $false
            $btnInstallNext.IsEnabled = $true
            $tickTimer.Stop()
        }
    } elseif ($script:Phase -eq 'installing') {
        if ($script:Proc.ExitCode -eq 0) {
            $installStatus.Text = '✅ 依赖安装完成'
            Begin-BuildPhase
        } else {
            $script:Phase = 'failed'
            $script:PhaseError = '依赖安装失败（退出码 ' + $script:Proc.ExitCode + '），请查看上方日志。常见原因：网络中断、磁盘空间不足。'
            $installStatus.Text = '❌ 依赖安装失败'
            $installStatus.Foreground = $window.Resources['ColorErrFg']
            $btnCancelInstall.IsEnabled = $false
            $btnInstallNext.IsEnabled = $true
            $tickTimer.Stop()
        }
    } elseif ($script:Phase -eq 'building') {
        if ($script:Proc.ExitCode -eq 0) {
            $installStatus.Text = '✅ 构建完成'
            Finish-Install
        } else {
            $script:Phase = 'failed'
            $script:PhaseError = '构建 DSH 失败（退出码 ' + $script:Proc.ExitCode + '），请查看上方日志。常见原因：磁盘空间不足、Node 版本过旧。'
            $installStatus.Text = '❌ 构建失败'
            $installStatus.Foreground = $window.Resources['ColorErrFg']
            $btnCancelInstall.IsEnabled = $false
            $btnInstallNext.IsEnabled = $true
            $tickTimer.Stop()
        }
    }
})

$btnCancelInstall.Add_Click({
    if ($script:Proc) {
        # 杀整个进程树（cmd → git/pnpm 的子进程也要一起结束）
        try { taskkill /PID $script:Proc.Id /T /F 2>$null | Out-Null } catch {}
        $script:Proc = $null
    }
    $script:Phase = 'idle'
    $installStatus.Text = '已取消安装（可点「‹ 上一步」删除残留并重新选择位置）'
    $installStatus.Foreground = $window.Resources['ColorWarnFg']
    $btnCancelInstall.IsEnabled = $false
    $btnInstallNext.IsEnabled = $true
    $tickTimer.Stop()
})

# 「‹ 上一步」：取消安装 + 删除本次残留 + 回到选择位置页
# （只删"本次安装创建"的目录；安装前就存在的目录绝不删除）
$btnInstallBack.Add_Click({
    # 1) 安装进行中 → 先取消（杀整个进程树）
    if ($script:Proc) {
        try { taskkill /PID $script:Proc.Id /T /F 2>$null | Out-Null } catch {}
        $script:Proc = $null
    }
    $tickTimer.Stop()

    # 2) 询问是否删除残留（只删本次安装创建的目录）
    $dirInfo = $script:DshDir
    $canDelete = (-not $script:DirExistedBefore) -and (Test-Path $dirInfo)
    $msg = '要回到上一步吗？'
    if ($canDelete) {
        $msg += "`n`n本次安装创建了文件夹：`n" + $dirInfo + "`n`n是否删除它（包括已下载的文件）？"
    } elseif ($script:DirExistedBefore) {
        $msg += "`n`n（这个文件夹在安装前就存在，为了安全不会删除它）"
    }
    $ans = [System.Windows.MessageBox]::Show($msg, '上一步', 'YesNo', 'Question')
    if ($ans -ne 'Yes') { return }
    if ($canDelete) {
        try {
            Remove-Item $dirInfo -Recurse -Force -ErrorAction SilentlyContinue
            Write-SetupLog ('[安装] 已删除残留目录：' + $dirInfo)
        } catch {}
    }

    # 3) 回到选择位置页，复位状态
    $script:Phase = 'idle'
    $script:DshDir = ''
    Show-SetupPage 'dir'
    $installStatus.Text = ''
    $installStatus.Foreground = $window.Resources['ColorAccent']
    $btnCancelInstall.IsEnabled = $true
    $btnInstallNext.IsEnabled = $false
    Set-Status '已取消安装，可重新选择位置'
})

$btnInstallNext.Add_Click({
    if ($script:Phase -eq 'done') {
        Show-SetupPage 'done'
    } else {
        # 失败时回到上一步
        Show-SetupPage 'dir'
    }
})

# ---------- 完成页 ----------
$btnLaunch.Add_Click({
    $btnLaunch.IsEnabled = $false
    Set-Status '正在启动 DSH 并打开界面…'
    $ok = Start-DshAndOpen -DshDir $script:DshDir
    if ($ok) {
        Set-Status 'DSH 已启动，浏览器已打开'
    } else {
        Set-Status '启动超时，请稍后手动打开：http://127.0.0.1:3080'
        [System.Windows.MessageBox]::Show('DSH 启动较慢，稍后手动在浏览器打开：http://127.0.0.1:3080' + "`n" + '（或双击桌面「Orca DSH Launcher」打开管理窗口）', 'Orca DSH Launcher', 'OK', 'Information') | Out-Null
        $btnLaunch.IsEnabled = $true
    }
})
$btnDoneClose.Add_Click({ $window.Close() })

# ---------- 打开窗口 ----------
$window.Add_Loaded({
    Show-SetupPage 'welcome'
    Set-Status '欢迎使用'
})
$window.ShowDialog() | Out-Null
