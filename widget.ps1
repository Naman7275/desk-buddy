# Desktop widget for tasks.md. Start it with "Start widget.vbs" (no console window).
# Test mode: widget.ps1 -LogFile <copy of tasks.md> -Today 2026-11-03   (simulates another day on a copy)
# Screenshot: add -Snapshot out.png (and -OpenLeave to show the leave panel); renders the widget to a PNG and exits.
param([string]$LogFile, [string]$Today, [string]$Snapshot, [switch]$OpenLeave)

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class WorkLogIdle {
  [StructLayout(LayoutKind.Sequential)] struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
  [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO p);
  public static uint IdleMs() {
    var l = new LASTINPUTINFO(); l.cbSize = (uint)Marshal.SizeOf(l);
    return GetLastInputInfo(ref l) ? (uint)Environment.TickCount - l.dwTime : uint.MaxValue;
  }
}
public static class WorkLogWin {
  [StructLayout(LayoutKind.Sequential)] struct RECT { public int L, T, R, B; }
  [StructLayout(LayoutKind.Sequential)] struct MONITORINFO { public int cbSize; public RECT rcMonitor; public RECT rcWork; public uint dwFlags; }
  [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint f);
  [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr h, uint f);
  [DllImport("user32.dll")] static extern bool GetMonitorInfo(IntPtr m, ref MONITORINFO mi);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, System.Text.StringBuilder s, int n);
  [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int i);
  [DllImport("user32.dll")] static extern int SetWindowLong(IntPtr h, int i, int v);
  // Tool windows stay out of Alt+Tab and are shown on every virtual desktop.
  public static void MakeToolWindow(IntPtr h) { SetWindowLong(h, -20, (GetWindowLong(h, -20) | 0x80) & ~0x40000); }
  // Re-assert always-on-top without moving, resizing or stealing focus (Windows sometimes drops it).
  public static void KeepOnTop(IntPtr h) { SetWindowPos(h, new IntPtr(-1), 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0010); }
  // True while a fullscreen app (slideshow, video, game) is in front; the desktop itself doesn't count.
  public static bool ForegroundIsFullscreen() {
    IntPtr f = GetForegroundWindow();
    if (f == IntPtr.Zero) return false;
    var cls = new System.Text.StringBuilder(64); GetClassName(f, cls, 64);
    string c = cls.ToString();
    if (c == "Progman" || c == "WorkerW" || c == "Shell_TrayWnd") return false;
    RECT r; if (!GetWindowRect(f, out r)) return false;
    var mi = new MONITORINFO(); mi.cbSize = Marshal.SizeOf(mi);
    if (!GetMonitorInfo(MonitorFromWindow(f, 2), ref mi)) return false;
    return r.L <= mi.rcMonitor.L && r.T <= mi.rcMonitor.T && r.R >= mi.rcMonitor.R && r.B >= mi.rcMonitor.B;
  }
}
'@

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$TestMode = [bool]$LogFile
$LogPath = if ($TestMode) { (Resolve-Path $LogFile).Path } else { Join-Path $Root 'tasks.md' }
$SettingsPath = Join-Path (Split-Path $LogPath) 'widget-settings.json'
$LeavePath = Join-Path (Split-Path $LogPath) 'leaves.md'
$ErrorLog = Join-Path $Root 'widget-error.log'
. (Join-Path $Root 'worklog-core.ps1')
if ($Today) { $script:TodayOverride = [datetime]::ParseExact($Today, 'yyyy-MM-dd', $null) }

# One copy only: launching again just asks the running widget to come to the front.
$suffix = if ($TestMode) { 'Test' } else { '' }
$ShowSignal = New-Object System.Threading.EventWaitHandle($false, 'AutoReset', "Local\WorkLogWidgetShow$suffix")
$created = $false
$mutex = New-Object System.Threading.Mutex($true, "Local\WorkLogWidget$suffix", [ref]$created)
if (-not $created) { [void]$ShowSignal.Set(); exit }

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Work log" Width="340" SizeToContent="Height"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        ResizeMode="NoResize" ShowInTaskbar="False" FontFamily="Segoe UI Variable Text, Segoe UI">
  <Window.Resources>
    <Style x:Key="Icon" TargetType="Button">
      <Setter Property="Foreground" Value="#6B7280"/>
      <Setter Property="FontFamily" Value="Segoe Fluent Icons, Segoe MDL2 Assets"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="B" Width="28" Height="28" CornerRadius="8" Background="Transparent">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="B" Property="Background" Value="#12000000"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Tick" TargetType="CheckBox">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Border x:Name="Box" Width="18" Height="18" CornerRadius="9" BorderThickness="1.5"
                    BorderBrush="#B8BEC8" Background="Transparent">
              <Path x:Name="Mark" Data="M4,8.5 L7,11.5 L12,5.5" Stroke="White" StrokeThickness="2"
                    StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round" Visibility="Collapsed"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Box" Property="BorderBrush" Value="#22A55B"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Box" Property="Background" Value="#22A55B"/>
                <Setter TargetName="Box" Property="BorderBrush" Value="#22A55B"/>
                <Setter TargetName="Mark" Property="Visibility" Value="Visible"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Border x:Name="Card" CornerRadius="16" Background="#FFFFFFFF" BorderBrush="#1F000000" BorderThickness="1" Margin="10">
    <Border.Effect>
      <DropShadowEffect BlurRadius="24" ShadowDepth="4" Opacity="0.16" Color="Black"/>
    </Border.Effect>
    <StackPanel Margin="18,14,18,16">

      <Grid x:Name="Header" Background="Transparent" Cursor="SizeAll">
        <StackPanel>
          <TextBlock x:Name="DayText" Foreground="#8A909A" FontSize="11" FontWeight="SemiBold" Margin="0,0,86,0"
                     TextTrimming="CharacterEllipsis"/>
          <TextBlock x:Name="TitleText" Foreground="#111827" FontSize="20" FontWeight="SemiBold" Margin="0,2,0,0"/>
          <TextBlock x:Name="SummaryText" Foreground="#6B7280" FontSize="12" Margin="0,2,0,0" TextWrapping="Wrap"/>
        </StackPanel>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,-4,-8,0">
          <Button x:Name="PinBtn" Style="{StaticResource Icon}" Content="&#xE718;" ToolTip="Keep on top"/>
          <Button x:Name="MenuBtn" Style="{StaticResource Icon}" Content="&#xE712;" ToolTip="More"/>
          <Button x:Name="CloseBtn" Style="{StaticResource Icon}" Content="&#xE8BB;" FontSize="10" ToolTip="Close widget"/>
        </StackPanel>
      </Grid>

      <Border x:Name="NoteBox" CornerRadius="10" Background="#EEF4FF" BorderBrush="#D9E6FF" BorderThickness="1"
              Padding="12,9" Margin="0,12,0,0" Visibility="Collapsed">
        <Grid>
          <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
          <TextBlock Text="&#xE735;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" Foreground="#3B6FE0"
                     FontSize="12" Margin="0,2,9,0" VerticalAlignment="Top"/>
          <TextBlock x:Name="NoteText" Grid.Column="1" Foreground="#1E3A8A" FontSize="12.5" TextWrapping="Wrap" LineHeight="18"/>
        </Grid>
      </Border>

      <ScrollViewer MaxHeight="440" VerticalScrollBarVisibility="Auto" Margin="0,6,-6,0" Padding="0,0,6,0">
        <StackPanel x:Name="OpenList"/>
      </ScrollViewer>
      <TextBlock x:Name="EmptyText" Text="Nothing open. Add something below." Foreground="#9CA3AF"
                 FontSize="12.5" Margin="0,10,0,4" Visibility="Collapsed"/>

      <Border CornerRadius="10" Background="#F3F4F6" BorderBrush="#E5E7EB" BorderThickness="1"
              Padding="11,8" Margin="0,12,0,0">
        <Grid>
          <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
          <TextBlock Text="&#xE710;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" Foreground="#8A909A"
                     FontSize="12" VerticalAlignment="Center" Margin="0,0,9,0"/>
          <TextBlock x:Name="AddHint" Grid.Column="1" Text="Add a task  (try: tomorrow, Fri, next week)" Foreground="#9CA3AF"
                     FontSize="13" IsHitTestVisible="False" VerticalAlignment="Center"/>
          <TextBox x:Name="AddBox" Grid.Column="1" Background="Transparent" BorderThickness="0" Foreground="#111827"
                   CaretBrush="#111827" FontSize="13" VerticalAlignment="Center" Padding="-2,0,0,0"/>
        </Grid>
      </Border>

      <TextBlock x:Name="DoneHeader" Foreground="#8A909A" FontSize="11" FontWeight="SemiBold" Margin="0,16,0,6"
                 Visibility="Collapsed"/>
      <StackPanel x:Name="DoneList"/>

      <!-- Leave balance: one line, click to see history and log a leave. -->
      <Border x:Name="LeaveBar" CornerRadius="10" Background="#F2FBF6" BorderBrush="#D3F0DF" BorderThickness="1"
              Padding="11,8" Margin="0,14,0,0" Cursor="Hand" Visibility="Collapsed" ToolTip="Leave history">
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <TextBlock Text="&#xE709;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" Foreground="#16A34A"
                     FontSize="13" VerticalAlignment="Center" Margin="0,0,9,0"/>
          <TextBlock Grid.Column="1" Text="Leave balance" Foreground="#166534" FontSize="12.5" VerticalAlignment="Center"/>
          <TextBlock x:Name="LeaveSub" Grid.Column="2" Foreground="#6B7280" FontSize="11" VerticalAlignment="Center" Margin="0,0,8,0"/>
          <TextBlock x:Name="LeaveText" Grid.Column="3" Foreground="#14532D" FontSize="13" FontWeight="SemiBold" VerticalAlignment="Center"/>
          <TextBlock x:Name="LeaveChevron" Grid.Column="4" Text="&#xE70D;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets"
                     Foreground="#6B9E7E" FontSize="10" VerticalAlignment="Center" Margin="9,1,0,0"/>
        </Grid>
      </Border>
      <StackPanel x:Name="LeavePanel" Visibility="Collapsed" Margin="2,10,2,0">
        <TextBlock x:Name="LeaveSummary" Foreground="#6B7280" FontSize="11.5" TextWrapping="Wrap" Margin="0,0,0,4"/>
        <StackPanel x:Name="LeaveList"/>
        <Border CornerRadius="10" Background="#F3F4F6" BorderBrush="#E5E7EB" BorderThickness="1" Padding="11,7" Margin="-2,8,-2,0">
          <Grid>
            <TextBlock x:Name="LeaveHint" Text="Log a leave  (today, 12 Nov, 12-14 Nov, half Fri)" Foreground="#9CA3AF"
                       FontSize="12" IsHitTestVisible="False" VerticalAlignment="Center"/>
            <TextBox x:Name="LeaveBox" Background="Transparent" BorderThickness="0" Foreground="#111827"
                     CaretBrush="#111827" FontSize="12" VerticalAlignment="Center" Padding="-2,0,0,0"/>
          </Grid>
        </Border>
      </StackPanel>
    </StackPanel>
  </Border>
</Window>
'@

$win = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
foreach ($n in 'Card','Header','DayText','TitleText','SummaryText','PinBtn','MenuBtn','CloseBtn','NoteBox','NoteText',
               'OpenList','EmptyText','AddHint','AddBox','DoneHeader','DoneList',
               'LeaveBar','LeaveSub','LeaveText','LeaveChevron','LeavePanel','LeaveSummary','LeaveList','LeaveHint','LeaveBox') {
  Set-Variable -Name $n -Value $win.FindName($n)
}

# Desk buddy: a small always-on-top plush mascot (3D render in .\mascot, animated here). Click it to show/hide the widget; drag to move; badge = today's count.
[xml]$petXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Work log buddy" Width="260" Height="170" WindowStyle="None" AllowsTransparency="True"
        Background="Transparent" ResizeMode="NoResize" ShowInTaskbar="False" Topmost="True"
        FontFamily="Segoe UI Variable Text, Segoe UI">
  <Grid>
    <Border x:Name="Bubble" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,112,30"
            Background="White" CornerRadius="12" Padding="11,7" BorderBrush="#1F000000" BorderThickness="1"
            Visibility="Collapsed" MaxWidth="150">
      <Border.Effect><DropShadowEffect BlurRadius="12" ShadowDepth="2" Opacity="0.15"/></Border.Effect>
      <StackPanel>
        <TextBlock x:Name="BubbleTitle" FontSize="12.5" FontWeight="SemiBold" Foreground="#111827" TextWrapping="Wrap"/>
        <TextBlock x:Name="BubbleText" FontSize="11.5" Foreground="#6B7280" TextWrapping="Wrap" Margin="0,1,0,0"/>
      </StackPanel>
    </Border>

    <Canvas x:Name="PetRoot" Width="110" Height="160" HorizontalAlignment="Right" VerticalAlignment="Bottom"
            Background="#01FFFFFF" Cursor="Hand" RenderTransformOrigin="0.5,0.95">
      <Canvas.RenderTransform><ScaleTransform x:Name="HoverScale" ScaleX="1" ScaleY="1"/></Canvas.RenderTransform>
      <Canvas.Triggers>
        <EventTrigger RoutedEvent="Loaded">
          <BeginStoryboard>
            <Storyboard>
              <!-- breathing: a soft squash and stretch from the feet -->
              <DoubleAnimation Storyboard.TargetName="Breathe" Storyboard.TargetProperty="ScaleY" From="1" To="1.025"
                               Duration="0:0:1.6" AutoReverse="True" RepeatBehavior="Forever">
                <DoubleAnimation.EasingFunction><SineEase EasingMode="EaseInOut"/></DoubleAnimation.EasingFunction>
              </DoubleAnimation>
              <DoubleAnimation Storyboard.TargetName="Breathe" Storyboard.TargetProperty="ScaleX" From="1" To="0.985"
                               Duration="0:0:1.6" AutoReverse="True" RepeatBehavior="Forever">
                <DoubleAnimation.EasingFunction><SineEase EasingMode="EaseInOut"/></DoubleAnimation.EasingFunction>
              </DoubleAnimation>
              <!-- slow side-to-side sway -->
              <DoubleAnimation Storyboard.TargetName="Sway" Storyboard.TargetProperty="Angle" From="-1.6" To="1.6"
                               Duration="0:0:3.2" AutoReverse="True" RepeatBehavior="Forever">
                <DoubleAnimation.EasingFunction><SineEase EasingMode="EaseInOut"/></DoubleAnimation.EasingFunction>
              </DoubleAnimation>
              <DoubleAnimation Storyboard.TargetName="ShadowScale" Storyboard.TargetProperty="ScaleX" From="1" To="0.94"
                               Duration="0:0:1.6" AutoReverse="True" RepeatBehavior="Forever"/>
            </Storyboard>
          </BeginStoryboard>
        </EventTrigger>
      </Canvas.Triggers>

      <Ellipse Canvas.Left="20" Canvas.Top="146" Width="70" Height="10" RenderTransformOrigin="0.5,0.5">
        <Ellipse.Fill>
          <RadialGradientBrush>
            <GradientStop Color="#55000000" Offset="0"/>
            <GradientStop Color="#00000000" Offset="1"/>
          </RadialGradientBrush>
        </Ellipse.Fill>
        <Ellipse.RenderTransform><ScaleTransform x:Name="ShadowScale"/></Ellipse.RenderTransform>
      </Ellipse>

      <Image x:Name="Sprite" Canvas.Left="3" Canvas.Top="16" Width="104" Height="135"
             RenderOptions.BitmapScalingMode="HighQuality" RenderTransformOrigin="0.5,0.97">
        <Image.RenderTransform>
          <TransformGroup>
            <ScaleTransform x:Name="Breathe"/>
            <ScaleTransform x:Name="Squish"/>
            <RotateTransform x:Name="Sway"/>
            <RotateTransform x:Name="Wiggle"/>
            <TranslateTransform x:Name="Hop"/>
          </TransformGroup>
        </Image.RenderTransform>
      </Image>

      <!-- badge -->
      <Border x:Name="Badge" Canvas.Left="84" Canvas.Top="6" MinWidth="24" Height="24" CornerRadius="12"
              Background="#EF4444" BorderBrush="White" BorderThickness="2" Padding="5,0">
        <TextBlock x:Name="BadgeText" Foreground="White" FontSize="11.5" FontWeight="Bold"
                   HorizontalAlignment="Center" VerticalAlignment="Center"/>
      </Border>
    </Canvas>
  </Grid>
</Window>
'@

$pet = $null
if (-not $TestMode) {
  $pet = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $petXaml))
  foreach ($n in 'Bubble','BubbleTitle','BubbleText','PetRoot','HoverScale','Hop','Badge','BadgeText','Sprite','Squish','Wiggle') {
    Set-Variable -Name $n -Value $pet.FindName($n)
  }
  # Faces: open / blink / happy frames of the same render.
  $Faces = @{}
  foreach ($f in 'open', 'blink', 'happy') {
    $bi = New-Object Windows.Media.Imaging.BitmapImage
    $bi.BeginInit(); $bi.CacheOption = 'OnLoad'; $bi.UriSource = New-Object Uri (Join-Path $Root "mascot\buddy-$f.png"); $bi.EndInit()
    $Faces[$f] = $bi
  }
  $Sprite.Source = $Faces['open']
}

$bc = New-Object Windows.Media.BrushConverter
function Brush($hex) { $bc.ConvertFromString($hex) }
$Dot = '  ' + [char]0x00B7 + '  '

function Write-ErrorLog($err) {
  Add-Content -Path $ErrorLog -Value ("[{0}] {1}" -f (Get-Date -Format s), $err)
}

function New-SectionHeader($text, $color, $first) {
  $h = New-Object Windows.Controls.TextBlock
  $h.Text = $text
  $h.FontSize = 11
  $h.FontWeight = 'SemiBold'
  $h.Foreground = Brush $color
  $h.Margin = if ($first) { '0,8,0,2' } else { '0,14,0,2' }
  $h
}

function New-OpenRow($item, $faded) {
  $g = New-Object Windows.Controls.Grid
  $g.Margin = '0,5,0,5'
  $g.Background = Brush '#00000000'
  if ($faded) { $g.Opacity = 0.7 }
  foreach ($w in 'Auto', '*', 'Auto') {
    $c = New-Object Windows.Controls.ColumnDefinition; $c.Width = $w; $g.ColumnDefinitions.Add($c)
  }

  $cb = New-Object Windows.Controls.CheckBox
  $cb.Style = $win.Resources['Tick']
  $cb.Margin = '0,1,12,0'
  $cb.VerticalAlignment = 'Top'
  $cb.Tag = $item

  $t = New-Object Windows.Controls.TextBlock
  $t.Text = $item.Text
  $t.TextWrapping = 'Wrap'
  $t.FontSize = 13.5
  $t.Foreground = Brush '#1F2937'
  [Windows.Controls.Grid]::SetColumn($t, 1)

  $a = New-Object Windows.Controls.TextBlock
  $a.FontSize = 11
  $a.Margin = '10,2,0,0'
  $a.VerticalAlignment = 'Top'
  # A due date wins over the age label: overdue/today in red, tomorrow in blue, later as a weekday or date.
  if ($null -ne $item.Due) {
    $d = $item.Due
    if ($d -lt 0) { $a.Text = "overdue $(-$d)d"; $a.Foreground = Brush '#DC2626' }
    elseif ($d -eq 0) { $a.Text = 'due today'; $a.Foreground = Brush '#DC2626' }
    elseif ($d -eq 1) { $a.Text = 'tomorrow'; $a.Foreground = Brush '#3B6FE0' }
    elseif ($d -lt 7) { $a.Text = (Get-Today).AddDays($d).ToString('ddd'); $a.Foreground = Brush '#6B7280' }
    else { $a.Text = (Get-Today).AddDays($d).ToString('d MMM'); $a.Foreground = Brush '#9CA3AF' }
    $a.FontWeight = if ($d -le 1) { 'SemiBold' } else { 'Normal' }
  } else {
    if ($null -eq $item.Age) { $a.Text = '' }
    elseif ($item.Age -le 0) { $a.Text = 'new' }
    elseif ($item.Age -eq 1) { $a.Text = 'yesterday' }
    else { $a.Text = "$($item.Age)d" }
    if ($item.Age -gt 5) { $a.Foreground = Brush '#D97706'; $a.ToolTip = "Open for $($item.Age) days" }
    else { $a.Foreground = Brush '#9CA3AF' }
  }
  [Windows.Controls.Grid]::SetColumn($a, 2)

  # Tick: strike through briefly, then log it as done.
  $cb.Add_Checked({
    param($s, $e)
    $row = $s.Parent
    $row.Children[1].TextDecorations = [Windows.TextDecorations]::Strikethrough
    $row.Opacity = 0.55
    $timer = New-Object Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(450)
    $timer.Tag = $s.Tag
    $timer.Add_Tick({ param($ts, $te) $ts.Stop(); try { Complete-Task $ts.Tag } catch { Write-ErrorLog $_ }; Render })
    $timer.Start()
  })

  $menu = New-Object Windows.Controls.ContextMenu
  $drop = New-Object Windows.Controls.MenuItem
  $drop.Header = 'Drop (no longer needed)'
  $drop.Tag = $item
  $drop.Add_Click({ param($s, $e) try { Drop-Task $s.Tag } catch { Write-ErrorLog $_ }; Render })
  [void]$menu.Items.Add($drop)
  $g.ContextMenu = $menu

  [void]$g.Children.Add($cb); [void]$g.Children.Add($t); [void]$g.Children.Add($a)
  $g
}

function New-DoneRow($text) {
  $t = New-Object Windows.Controls.TextBlock
  $t.Text = $text
  $t.TextWrapping = 'Wrap'
  $t.FontSize = 12.5
  $t.Margin = '30,2,0,2'
  $t.Foreground = Brush '#9CA3AF'
  $t.TextDecorations = [Windows.TextDecorations]::Strikethrough
  $t.Cursor = [Windows.Input.Cursors]::Hand
  $t.ToolTip = 'Click to reopen'
  $t.Tag = $text
  $t.Add_MouseLeftButtonUp({ param($s, $e) try { Restore-Task $s.Tag } catch { Write-ErrorLog $_ }; Render })
  $t
}

function Render {
  try {
    $s = Get-State
    $script:LastWrite = if (Test-Path $LogPath) { (Get-Item $LogPath).LastWriteTimeUtc } else { $null }
    $script:RenderDay = Get-Today

    $open = @($s.Open)
    $dueNow   = @($open | Where-Object { $null -ne $_.Due -and $_.Due -le 0 } | Sort-Object Due)
    $carried  = @($open | Where-Object { $null -eq $_.Due -and $_.Age -ge 1 } | Sort-Object Age -Descending)
    $fresh    = @($open | Where-Object { $null -eq $_.Due -and -not ($_.Age -ge 1) })
    $upcoming = @($open | Where-Object { $_.Due -ge 1 } | Sort-Object Due)
    $todayCount = $dueNow.Count + $carried.Count + $fresh.Count

    $day = (Get-Today).ToString('dddd, d MMMM').ToUpper()
    $DayText.Text = if ($script:Greeting) { "GOOD MORNING$Dot$day" } else { $day }
    $TitleText.Text = if ($todayCount -gt 0) { "$todayCount for today" } elseif ($upcoming.Count) { 'Nothing due today' } else { 'All clear' }

    $parts = @()
    if ($dueNow.Count) { $parts += "$($dueNow.Count) due today" }
    if ($carried.Count) { $parts += "$($carried.Count) left from before" }
    if ($upcoming.Count) { $parts += "$($upcoming.Count) coming up" }
    $SummaryText.Text = $parts -join $Dot
    $SummaryText.Visibility = if ($parts.Count) { 'Visible' } else { 'Collapsed' }
    Update-Pet $todayCount $dueNow.Count $TitleText.Text $SummaryText.Text

    $OpenList.Children.Clear()
    $first = $true
    $carriedTitle = if (@($carried | Where-Object { $_.Age -gt 1 }).Count) { 'LEFT FROM BEFORE' } else { 'LEFT FROM YESTERDAY' }
    foreach ($sec in @(
        @{ Title = 'DUE TODAY'; Color = '#DC2626'; Items = $dueNow; Faded = $false },
        @{ Title = $carriedTitle; Color = '#D97706'; Items = $carried; Faded = $false },
        @{ Title = 'ADDED TODAY'; Color = '#8A909A'; Items = $fresh; Faded = $false },
        @{ Title = 'COMING UP'; Color = '#8A909A'; Items = $upcoming; Faded = $true })) {
      if (-not $sec.Items.Count) { continue }
      [void]$OpenList.Children.Add((New-SectionHeader "$($sec.Title)  $($sec.Items.Count)" $sec.Color $first))
      foreach ($item in $sec.Items) { [void]$OpenList.Children.Add((New-OpenRow $item $sec.Faded)) }
      $first = $false
    }
    $EmptyText.Visibility = if ($open.Count -eq 0) { 'Visible' } else { 'Collapsed' }

    if ($s.Note) { $NoteText.Text = $s.Note; $NoteBox.Visibility = 'Visible' } else { $NoteBox.Visibility = 'Collapsed' }

    $DoneList.Children.Clear()
    $doneCount = @($s.Done).Count
    foreach ($d in $s.Done) { [void]$DoneList.Children.Add((New-DoneRow $d)) }
    $DoneHeader.Text = "DONE TODAY  $doneCount"
    $DoneHeader.Visibility = if ($doneCount) { 'Visible' } else { 'Collapsed' }
  } catch { Write-ErrorLog $_ }
  Render-Leave
}

function New-LeaveRow($e) {
  $g = New-Object Windows.Controls.Grid
  $g.Margin = '0,3,0,3'
  $g.Background = Brush '#00000000'
  foreach ($w in '*', 'Auto') { $c = New-Object Windows.Controls.ColumnDefinition; $c.Width = $w; $g.ColumnDefinitions.Add($c) }
  $t = New-Object Windows.Controls.TextBlock
  $t.FontSize = 12.5
  $t.Text = if ($e.Exact) { $e.Date.ToString('ddd, d MMM') } else { $e.Date.ToString('MMMM') }
  if ($e.Note -and -not $e.Exact) { $t.ToolTip = $e.Note } elseif ($e.Note) { $t.Text += "$Dot$($e.Note)" }
  $t.TextTrimming = 'CharacterEllipsis'
  $t.Foreground = Brush $(if ($e.Planned) { '#1D4ED8' } else { '#374151' })
  $a = New-Object Windows.Controls.TextBlock
  $a.FontSize = 11.5
  $a.Margin = '10,1,0,0'
  $n = Format-Days ([Math]::Abs($e.Days))
  $a.Text = if ($e.Days -lt 0) { "+$n back" } elseif ($e.Days -eq 0.5) { 'half day' } elseif ($e.Days -eq 1) { '1 day' } else { "$n days" }
  if ($e.Planned) { $a.Text += '  planned' }
  $a.Foreground = Brush $(if ($e.Planned) { '#3B6FE0' } else { '#9CA3AF' })
  [Windows.Controls.Grid]::SetColumn($a, 1)
  $menu = New-Object Windows.Controls.ContextMenu
  $rm = New-Object Windows.Controls.MenuItem
  $rm.Header = 'Remove this leave'
  $rm.Tag = $e
  $rm.Add_Click({ param($s, $ev) try { Remove-Leave $s.Tag } catch { Write-ErrorLog $_ }; Render-Leave })
  [void]$menu.Items.Add($rm)
  $g.ContextMenu = $menu
  [void]$g.Children.Add($t); [void]$g.Children.Add($a)
  $g
}

# Leave line at the bottom: balance today, planned days, and (expanded) recent history with a box to log more.
function Render-Leave {
  try {
    $script:LeaveWrite = if (Test-Path $LeavePath) { (Get-Item $LeavePath).LastWriteTimeUtc } else { $null }
    $l = Get-LeaveState
    if (-not $l) { $LeaveBar.Visibility = 'Collapsed'; $LeavePanel.Visibility = 'Collapsed'; return }
    $LeaveBar.Visibility = 'Visible'
    $b = Format-Days $l.Balance
    $LeaveText.Text = if ($l.Balance -eq 1) { '1 day' } else { "$b days" }
    $LeaveText.Foreground = Brush $(if ($l.Balance -lt 0) { '#DC2626' } else { '#14532D' })
    $sub = @()
    if ($l.CreditedToday) { $sub += "+$(Format-Days $l.Rate) today" }
    if ($l.Planned) { $sub += "$(Format-Days $l.Planned) planned" }
    $LeaveSub.Text = $sub -join $Dot
    $after = if ($l.Planned) { "$Dot$(Format-Days ($l.Balance - $l.Planned)) after planned" } else { '' }
    $LeaveSummary.Text = "Earned $(Format-Days $l.Earned)$Dot" + "used $(Format-Days $l.Used)$after$Dot" +
                         "+$(Format-Days $l.Rate) on $($l.NextCredit.ToString('d MMM'))"
    $LeaveList.Children.Clear()
    $planned = @($l.Entries | Where-Object { $_.Planned } | Sort-Object Date)
    $past = @($l.Entries | Where-Object { -not $_.Planned } | Select-Object -First 5)
    foreach ($e in $planned + $past) { [void]$LeaveList.Children.Add((New-LeaveRow $e)) }
    $open = $LeavePanel.Visibility -eq 'Visible'
    $LeaveChevron.Text = if ($open) { [string][char]0xE70E } else { [string][char]0xE70D }
  } catch { Write-ErrorLog $_ }
}

function Save-Settings {
  $cfg = @{ Left = $win.Left; Top = $win.Top; Topmost = $script:Pinned; LastGreetDay = $script:LastGreetDay }
  if ($pet) { $cfg.PetLeft = $pet.Left; $cfg.PetTop = $pet.Top }
  $cfg | ConvertTo-Json | Set-Content -Path $SettingsPath -Encoding UTF8
}

# Badge: red with the count when something is due/overdue, blue when only carry-overs, green tick when clear.
function Update-Pet($count, $dueCount, $title, $summary) {
  if (-not $pet) { return }
  if ($count -eq 0) { $BadgeText.Text = [string][char]0x2713; $Badge.Background = Brush '#22A55B' }
  else { $BadgeText.Text = "$count"; $Badge.Background = if ($dueCount) { Brush '#EF4444' } else { Brush '#3B6FE0' } }
  $BubbleTitle.Text = $title
  $BubbleText.Text = if ($summary) { $summary } else { 'Click me to open your list' }
  if ($null -ne $script:PetCount -and $count -ne $script:PetCount) { Invoke-PetHop 1 }
  $script:PetCount = $count
}

function Invoke-PetHop($times) {
  if (-not $pet) { return }
  $a = New-Object Windows.Media.Animation.DoubleAnimation(0, -12, [Windows.Duration][TimeSpan]::FromMilliseconds(170))
  $a.AutoReverse = $true
  $a.RepeatBehavior = New-Object Windows.Media.Animation.RepeatBehavior([double]$times)
  $a.EasingFunction = New-Object Windows.Media.Animation.QuadraticEase
  $Hop.BeginAnimation([Windows.Media.TranslateTransform]::YProperty, $a)
}

function Set-Face($kind) {
  if (-not $pet) { return }
  $script:Face = $kind
  $Sprite.Source = $Faces[$kind]
}

# Quick left-right wiggle (the morning hello and the occasional fidget).
function Invoke-PetWiggle {
  if (-not $pet) { return }
  $a = New-Object Windows.Media.Animation.DoubleAnimationUsingKeyFrames
  $a.Duration = [Windows.Duration][TimeSpan]::FromMilliseconds(900)
  $t = 0
  foreach ($v in 0, -7, 6, -5, 4, -2, 0) {
    [void]$a.KeyFrames.Add((New-Object Windows.Media.Animation.EasingDoubleKeyFrame($v, [Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds($t)))))
    $t += 150
  }
  $Wiggle.BeginAnimation([Windows.Media.RotateTransform]::AngleProperty, $a)
}

# Click feedback: a soft squash at the feet.
function Invoke-PetSquish {
  if (-not $pet) { return }
  $y = New-Object Windows.Media.Animation.DoubleAnimation(1, 0.9, [Windows.Duration][TimeSpan]::FromMilliseconds(90))
  $y.AutoReverse = $true
  $x = New-Object Windows.Media.Animation.DoubleAnimation(1, 1.06, [Windows.Duration][TimeSpan]::FromMilliseconds(90))
  $x.AutoReverse = $true
  $Squish.BeginAnimation([Windows.Media.ScaleTransform]::ScaleYProperty, $y)
  $Squish.BeginAnimation([Windows.Media.ScaleTransform]::ScaleXProperty, $x)
}

function Show-PetBubble($seconds) {
  if (-not $pet) { return }
  $Bubble.Visibility = 'Visible'
  if ($script:BubbleTimer) { $script:BubbleTimer.Stop() }
  if ($seconds) {
    $script:BubbleTimer = New-Object Windows.Threading.DispatcherTimer
    $script:BubbleTimer.Interval = [TimeSpan]::FromSeconds($seconds)
    $script:BubbleTimer.Add_Tick({ param($s, $e) $s.Stop(); if (-not $PetRoot.IsMouseOver) { $Bubble.Visibility = 'Collapsed' } })
    $script:BubbleTimer.Start()
  }
}

# Puts the widget right beside the buddy (left of it, or right when there's no room), bottoms lined up, kept on its screen.
function Move-WidgetNearPet {
  if (-not $pet -or -not $pet.IsVisible) { return }
  $src = [Windows.PresentationSource]::FromVisual($pet)
  $k = if ($src) { $src.CompositionTarget.TransformToDevice.M11 } else { 1 }
  $px = New-Object Drawing.Point ([int](($pet.Left + $pet.Width - 55) * $k)), ([int](($pet.Top + $pet.Height / 2) * $k))
  $wa = [Windows.Forms.Screen]::FromPoint($px).WorkingArea
  $aL = $wa.Left / $k; $aT = $wa.Top / $k; $aR = $wa.Right / $k; $aB = $wa.Bottom / $k
  $win.UpdateLayout()
  $h = if ($win.ActualHeight -gt 0) { $win.ActualHeight } else { 520 }
  $budLeft = $pet.Left + $pet.Width - 110
  $x = $budLeft - $win.Width - 2
  if ($x -lt $aL + 4) { $x = $pet.Left + $pet.Width + 2 }
  $x = [Math]::Max($aL + 4, [Math]::Min($x, $aR - $win.Width - 4))
  $y = $pet.Top + $pet.Height - $h + 4
  $y = [Math]::Max($aT + 4, [Math]::Min($y, $aB - $h - 4))
  $win.Left = $x; $win.Top = $y
}

function Show-Widget {
  $win.Show()
  Move-WidgetNearPet
  $win.Topmost = $true; [void]$win.Activate(); $win.Topmost = ($script:Pinned -or $script:Greeting)
}

# Buddy click: hide the widget if it was just in front, otherwise bring it up.
function Switch-Widget {
  $wasFront = $win.IsVisible -and ($win.IsActive -or ((Get-Date) - $script:DeactivatedAt).TotalMilliseconds -lt 1200)
  if ($wasFront) { $win.Hide() } else { Show-Widget }
}

function Set-Pinned($on) {
  $script:Pinned = [bool]$on
  $win.Topmost = $on
  $PinBtn.Content = if ($on) { [string][char]0xE840 } else { [string][char]0xE718 }
  $PinBtn.Foreground = if ($on) { Brush '#3B6FE0' } else { Brush '#6B7280' }
}

# Morning hello: the first time each day you are actually at the laptop (logged in / unlocked and
# using it), bring the widget above everything with a blue outline. It settles back once he clicks elsewhere.
function Start-Greeting {
  $script:Greeting = $true
  $script:GreetStarted = Get-Date
  $script:LastGreetDay = (Get-Today).ToString('yyyy-MM-dd')
  Save-Settings
  $Card.BorderBrush = Brush '#3B6FE0'
  $Card.BorderThickness = 2
  $win.Show()
  $win.Topmost = $true
  [void]$win.Activate()
  Render
  if ($pet) {
    $BubbleTitle.Text = "Good morning! $($TitleText.Text)"; Show-PetBubble 12
    Set-Face 'happy'; Invoke-PetHop 3; Invoke-PetWiggle
    $script:FaceHoldUntil = (Get-Date).AddSeconds(4)
  }
}

function Stop-Greeting {
  if (-not $script:Greeting) { return }
  $script:Greeting = $false
  $Card.BorderBrush = Brush '#1F000000'
  $Card.BorderThickness = 1
  $win.Topmost = $script:Pinned
  Render
}

$StartupLink = Join-Path ([Environment]::GetFolderPath('Startup')) 'Desk Buddy.lnk'
function Set-StartWithWindows($on) {
  if ($on) {
    $sh = New-Object -ComObject WScript.Shell
    $lnk = $sh.CreateShortcut($StartupLink)
    $lnk.TargetPath = Join-Path $env:WINDIR 'System32\wscript.exe'
    $lnk.Arguments = '"' + (Join-Path $Root 'Start widget.vbs') + '"'
    $lnk.WorkingDirectory = $Root
    $lnk.Save()
  } elseif (Test-Path $StartupLink) { Remove-Item $StartupLink }
}

# Position: last saved spot, else top-right of the screen (test mode: top-left, so both can be seen).
$work = [Windows.SystemParameters]::WorkArea
$win.Left = if ($TestMode) { $work.Left + 16 } else { $work.Right - $win.Width - 16 }
$win.Top = $work.Top + 16
$script:Greeting = $false
$script:Locked = $false
$script:LastGreetDay = ''
Set-Pinned $false
if (Test-Path $SettingsPath) {
  try {
    $cfg = Get-Content $SettingsPath -Raw | ConvertFrom-Json
    $vs = [Windows.Forms.SystemInformation]::VirtualScreen
    if ($cfg.Left -ge $vs.Left - 100 -and $cfg.Left -le $vs.Right - 100 -and $cfg.Top -ge $vs.Top - 20 -and $cfg.Top -le $vs.Bottom - 80) {
      $win.Left = $cfg.Left; $win.Top = $cfg.Top
    }
    Set-Pinned ([bool]$cfg.Topmost)
    if ($cfg.LastGreetDay) { $script:LastGreetDay = [string]$cfg.LastGreetDay }
  } catch { Write-ErrorLog $_ }
}

# Buddy: last saved spot, else bottom-right just above the taskbar.
$script:DeactivatedAt = [datetime]::MinValue
if ($pet) {
  $pet.Left = $work.Right - $pet.Width - 12
  $pet.Top = $work.Bottom - $pet.Height - 8
  $vs = [Windows.Forms.SystemInformation]::VirtualScreen
  if ($cfg -and $null -ne $cfg.PetLeft -and $cfg.PetLeft -ge $vs.Left - 150 -and $cfg.PetLeft -le $vs.Right - 120 -and
      $cfg.PetTop -ge $vs.Top - 20 -and $cfg.PetTop -le $vs.Bottom - 60) {
    $pet.Left = $cfg.PetLeft; $pet.Top = $cfg.PetTop
  }

  $PetRoot.Add_MouseLeftButtonDown({
    $x = $pet.Left; $y = $pet.Top
    $pet.DragMove()
    if ([Math]::Abs($pet.Left - $x) -lt 4 -and [Math]::Abs($pet.Top - $y) -lt 4) { Invoke-PetSquish; Switch-Widget } else { Save-Settings }
  })
  # Hover: lean in a little and smile.
  $PetRoot.Add_MouseEnter({
    $a = New-Object Windows.Media.Animation.DoubleAnimation(1.07, [Windows.Duration][TimeSpan]::FromMilliseconds(140))
    $HoverScale.BeginAnimation([Windows.Media.ScaleTransform]::ScaleXProperty, $a)
    $HoverScale.BeginAnimation([Windows.Media.ScaleTransform]::ScaleYProperty, $a)
    Set-Face 'happy'
    Show-PetBubble 0
  })
  $PetRoot.Add_MouseLeave({
    $a = New-Object Windows.Media.Animation.DoubleAnimation(1.0, [Windows.Duration][TimeSpan]::FromMilliseconds(140))
    $HoverScale.BeginAnimation([Windows.Media.ScaleTransform]::ScaleXProperty, $a)
    $HoverScale.BeginAnimation([Windows.Media.ScaleTransform]::ScaleYProperty, $a)
    if ((Get-Date) -ge $script:FaceHoldUntil) { Set-Face 'open' }
    $Bubble.Visibility = 'Collapsed'
  })

  $petMenu = New-Object Windows.Controls.ContextMenu
  $pmOpen = New-Object Windows.Controls.MenuItem; $pmOpen.Header = 'Open my list'
  $pmOpen.Add_Click({ Show-Widget })
  $pmAdd = New-Object Windows.Controls.MenuItem; $pmAdd.Header = 'Add a task...'
  $pmAdd.Add_Click({ Show-Widget; [void]$AddBox.Focus() })
  $pmQuit = New-Object Windows.Controls.MenuItem; $pmQuit.Header = 'Quit (widget and buddy)'
  $pmQuit.Add_Click({ Save-Settings; [Windows.Application]::Current.Shutdown() })
  foreach ($i in $pmOpen, $pmAdd, $pmQuit) { [void]$petMenu.Items.Add($i) }
  $PetRoot.ContextMenu = $petMenu

  # Show on every virtual desktop, at the same spot.
  $pet.Add_SourceInitialized({ [WorkLogWin]::MakeToolWindow((New-Object Windows.Interop.WindowInteropHelper $pet).Handle) })

  # Blinks at natural, slightly random intervals (sometimes a double blink); now and then a little fidget.
  $script:Face = 'open'
  $script:FaceHoldUntil = Get-Date
  $script:Rng = New-Object Random
  $blink = New-Object Windows.Threading.DispatcherTimer
  $blink.Interval = [TimeSpan]::FromSeconds(3)
  $blink.Add_Tick({
    param($s, $e)
    $s.Interval = [TimeSpan]::FromMilliseconds($script:Rng.Next(2600, 6200))
    if (-not $pet.IsVisible) { return }
    if ((Get-Date) -ge $script:FaceHoldUntil -and $script:Face -eq 'happy' -and -not $PetRoot.IsMouseOver) { Set-Face 'open' }
    if ($script:Face -ne 'open') { return }
    $steps = if ($script:Rng.NextDouble() -lt 0.25) { 'blink', 'open', 'blink', 'open' } else { 'blink', 'open' }
    $script:BlinkSteps = [System.Collections.Queue]::new([object[]]$steps)
    $bt = New-Object Windows.Threading.DispatcherTimer
    $bt.Interval = [TimeSpan]::FromMilliseconds(120)
    $bt.Add_Tick({ param($t, $te) if ($script:BlinkSteps.Count) { Set-Face $script:BlinkSteps.Dequeue() } else { $t.Stop() } })
    Set-Face $script:BlinkSteps.Dequeue()
    $bt.Start()
    if ($script:Rng.NextDouble() -lt 0.08) { Invoke-PetWiggle }
  })
  $blink.Start()
}
$win.Add_SourceInitialized({ [WorkLogWin]::MakeToolWindow((New-Object Windows.Interop.WindowInteropHelper $win).Handle) })

# Lock/unlock tracking, so the morning hello never fires behind the lock screen.
Register-ObjectEvent -InputObject ([Microsoft.Win32.SystemEvents]) -EventName SessionSwitch -SourceIdentifier WorkLogSession | Out-Null

$Header.Add_MouseLeftButtonDown({ $win.DragMove(); Save-Settings })
$PinBtn.Add_Click({ Set-Pinned (-not $script:Pinned); Save-Settings })
# With the buddy around, X just tucks the widget away (click the buddy to bring it back).
if ($pet) { $CloseBtn.ToolTip = 'Hide (click the buddy to reopen)' }
$CloseBtn.Add_Click({ if ($pet) { $win.Hide() } else { $win.Close() } })
$win.Add_Deactivated({ $script:DeactivatedAt = Get-Date; Stop-Greeting })

$MenuBtn.Add_Click({
  $m = New-Object Windows.Controls.ContextMenu
  $open = New-Object Windows.Controls.MenuItem; $open.Header = 'Open tasks.md'
  $open.Add_Click({ Start-Process $LogPath })
  $openLeave = New-Object Windows.Controls.MenuItem; $openLeave.Header = 'Open leaves.md'
  $openLeave.Add_Click({ if (Test-Path $LeavePath) { Start-Process $LeavePath } })
  $reload = New-Object Windows.Controls.MenuItem; $reload.Header = 'Refresh'
  $reload.Add_Click({ Render })
  $boot = New-Object Windows.Controls.MenuItem; $boot.Header = 'Start with Windows'
  $boot.IsCheckable = $true; $boot.IsChecked = (Test-Path $StartupLink)
  $boot.Add_Click({ param($s, $e) try { Set-StartWithWindows $s.IsChecked } catch { Write-ErrorLog $_ } })
  # Opens a second widget on a throwaway copy, dated the next working day, to see how the morning will look.
  $preview = New-Object Windows.Controls.MenuItem; $preview.Header = 'Preview tomorrow morning'
  $preview.Add_Click({
    try {
      $dir = Join-Path $env:TEMP 'worklog-preview'
      New-Item -ItemType Directory -Force $dir | Out-Null
      Copy-Item $LogPath (Join-Path $dir 'tasks.md') -Force
      if (Test-Path $LeavePath) { Copy-Item $LeavePath (Join-Path $dir 'leaves.md') -Force }
      $next = (Get-Today).AddDays(1)
      while ($next.DayOfWeek -in 'Saturday', 'Sunday') { $next = $next.AddDays(1) }
      Start-Process powershell.exe -WindowStyle Hidden -ArgumentList '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass',
        '-File', ('"' + (Join-Path $Root 'widget.ps1') + '"'), '-LogFile', ('"' + (Join-Path $dir 'tasks.md') + '"'),
        '-Today', $next.ToString('yyyy-MM-dd')
    } catch { Write-ErrorLog $_ }
  })
  $preview.IsEnabled = -not $TestMode
  $quit = New-Object Windows.Controls.MenuItem; $quit.Header = 'Quit (widget and buddy)'
  $quit.Add_Click({ Save-Settings; [Windows.Application]::Current.Shutdown() })
  foreach ($i in $open, $openLeave, $reload, $preview, $boot, $quit) { [void]$m.Items.Add($i) }
  $m.PlacementTarget = $MenuBtn
  $m.IsOpen = $true
})

$LeaveBar.Add_MouseLeftButtonUp({
  $LeavePanel.Visibility = if ($LeavePanel.Visibility -eq 'Visible') { 'Collapsed' } else { 'Visible' }
  Render-Leave
})
$LeaveBox.Add_TextChanged({ $LeaveHint.Visibility = if ($LeaveBox.Text) { 'Collapsed' } else { 'Visible' } })
$LeaveBox.Add_KeyDown({
  param($s, $e)
  if ($e.Key -eq [Windows.Input.Key]::Enter) {
    $ok = $false
    try { $ok = Add-Leave $LeaveBox.Text } catch { Write-ErrorLog $_ }
    if ($ok) {
      $LeaveBox.Text = ''; $LeaveHint.Foreground = Brush '#9CA3AF'
      $LeaveHint.Text = 'Log a leave  (today, 12 Nov, 12-14 Nov, half Fri)'; Render-Leave
    }
    else { $LeaveHint.Foreground = Brush '#DC2626'; $LeaveBox.Text = ''; $LeaveHint.Text = "Didn't catch a date. Try: today, 12 Nov, 12-14 Nov" }
  } elseif ($e.Key -eq [Windows.Input.Key]::Escape) { $LeaveBox.Text = '' }
})

$AddBox.Add_TextChanged({ $AddHint.Visibility = if ($AddBox.Text) { 'Collapsed' } else { 'Visible' } })
$AddBox.Add_KeyDown({
  param($s, $e)
  if ($e.Key -eq [Windows.Input.Key]::Enter) {
    try { Add-Task $AddBox.Text } catch { Write-ErrorLog $_ }
    $AddBox.Text = ''
    Render
  } elseif ($e.Key -eq [Windows.Input.Key]::Escape) { $AddBox.Text = '' }
})

# Every 1.5 s: bring-to-front requests, lock state, morning hello, and edits made outside the widget.
$poll = New-Object Windows.Threading.DispatcherTimer
$poll.Interval = [TimeSpan]::FromSeconds(1.5)
$poll.Add_Tick({
  try {
    if ($ShowSignal.WaitOne(0)) { Show-Widget; [void]$AddBox.Focus() }
    if ($pet) {
      if ([WorkLogWin]::ForegroundIsFullscreen()) { if ($pet.IsVisible) { $pet.Hide() } }
      else {
        if (-not $pet.IsVisible) { $pet.Show() }
        [WorkLogWin]::KeepOnTop((New-Object Windows.Interop.WindowInteropHelper $pet).Handle)
      }
    }
    if ($script:Pinned -and $win.IsVisible) { [WorkLogWin]::KeepOnTop((New-Object Windows.Interop.WindowInteropHelper $win).Handle) }
    foreach ($ev in @(Get-Event -SourceIdentifier WorkLogSession -ErrorAction SilentlyContinue)) {
      $r = "$($ev.SourceEventArgs.Reason)"
      if ($r -eq 'SessionLock') { $script:Locked = $true }
      elseif ($r -eq 'SessionUnlock' -or $r -eq 'SessionLogon') { $script:Locked = $false }
      Remove-Event -EventIdentifier $ev.EventIdentifier
    }
    $todayKey = (Get-Today).ToString('yyyy-MM-dd')
    if ($script:LastGreetDay -ne $todayKey -and -not $script:Locked -and [WorkLogIdle]::IdleMs() -lt 5000) { Start-Greeting }
    if ($script:Greeting -and ((Get-Date) - $script:GreetStarted).TotalMinutes -ge 15) { Stop-Greeting }

    $lw = if (Test-Path $LogPath) { (Get-Item $LogPath).LastWriteTimeUtc } else { $null }
    if ($lw -ne $script:LastWrite -or (Get-Today) -ne $script:RenderDay) { Render }
    $lv = if (Test-Path $LeavePath) { (Get-Item $LeavePath).LastWriteTimeUtc } else { $null }
    if ($lv -ne $script:LeaveWrite) { Render-Leave }
  } catch { Write-ErrorLog $_ }
})
$poll.Start()

$win.Add_Closing({ Save-Settings })
if ($TestMode -and -not $Snapshot) { $win.Add_ContentRendered({ Start-Greeting }) }
if ($Snapshot) {
  if ($OpenLeave) { $LeavePanel.Visibility = 'Visible'; Render-Leave }
  $win.Add_ContentRendered({
    $win.Dispatcher.BeginInvoke([Action]{
      $el = $win.Content; $s = 2
      $rtb = New-Object Windows.Media.Imaging.RenderTargetBitmap ([int](($el.ActualWidth + 20) * $s)), ([int](($el.ActualHeight + 20) * $s)), (96 * $s), (96 * $s), ([Windows.Media.PixelFormats]::Pbgra32)
      $rtb.Render($el)
      $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder
      $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($rtb))
      $fs = [IO.File]::Create($Snapshot); $enc.Save($fs); $fs.Close()
      $win.Close()
    }, [Windows.Threading.DispatcherPriority]::ApplicationIdle) | Out-Null
  })
}
Render

# Test mode ends when its widget closes; the real one runs until "Quit" (the buddy keeps it alive).
$app = New-Object Windows.Application
$app.ShutdownMode = if ($pet) { 'OnExplicitShutdown' } else { 'OnLastWindowClose' }
$win.Show()
if ($pet) { $pet.Show() }
[void]$app.Run()
$mutex.ReleaseMutex()
