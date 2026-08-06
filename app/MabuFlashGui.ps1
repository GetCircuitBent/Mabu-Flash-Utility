<#
  MabuFlashGui.ps1: WPF front-end for the Mabu flash utility.

  GUI shell for the `executable` branch: connect screen, two progress bars
  (Flashing / Validating), a live log, and blocking prompt cards, all driven
  through the UI-provider contract in app/EXECUTABLE.md. The same window will
  later drive the real flash core; for now `-Simulate` runs a fake flow so the
  UX can be reviewed without hardware.

  Usage:
    powershell -ExecutionPolicy Bypass -File app\MabuFlashGui.ps1 -Simulate

  Threading model (the reliable PS 5.1 pattern):
    * WPF pumps on the main thread (ShowDialog).
    * The flow runs in a background runspace and ONLY enqueues plain-data
      messages onto a synchronized queue; it never touches WPF directly.
    * A DispatcherTimer on the UI thread drains the queue and does every UI
      mutation, so there is no cross-runspace scriptblock/affinity hazard.
    * Prompts: the worker enqueues a message carrying a ManualResetEventSlim,
      then blocks on it; the button click (UI thread) sets the result and
      signals the event, unblocking the worker.
#>
[CmdletBinding()]
param(
    [switch] $Simulate,          # run a fake flow (no hardware/tools required)
    [switch] $SkipMabu,          # skip Mabu factory mode (installed by default)
    [switch] $WipeData,
    [switch] $NoWipe
)

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

# ---- Shared state bag (crosses the UI/worker thread boundary by reference) ----
$sync = [hashtable]::Synchronized(@{})
$sync.Simulate = [bool]$Simulate
$sync.Options  = @{ SkipMabu = [bool]$SkipMabu; WipeData = [bool]$WipeData; NoWipe = [bool]$NoWipe }
$sync.Queue    = [System.Collections.Queue]::Synchronized([System.Collections.Queue]::new())
# Where app/lib/* lives, so the worker runspace can dot-source the core.
# Robust across -File, dot-sourcing, and ps2exe (where $PSScriptRoot and
# $MyInvocation.MyCommand.Path are both empty; the exe's own folder comes from
# the entry assembly location instead). Prefer whichever candidate actually
# contains lib\MabuFlashCore.ps1 so an odd working directory can't fool us.
$entryDir = try {
    $asm = [System.Reflection.Assembly]::GetEntryAssembly()
    if ($asm -and $asm.Location) { Split-Path -Parent $asm.Location } else { $null }
} catch { $null }
$appCandidates = @(
    $PSScriptRoot,
    $(if ($MyInvocation.MyCommand.Path) { Split-Path -Parent $MyInvocation.MyCommand.Path }),
    $entryDir
) | Where-Object { $_ }
$sync.AppDir = $appCandidates | Where-Object { Test-Path (Join-Path $_ 'lib\MabuFlashCore.ps1') } | Select-Object -First 1
if (-not $sync.AppDir) {
    $sync.AppDir = if ($PSScriptRoot) { $PSScriptRoot } elseif ($entryDir) { $entryDir } else { (Get-Location).Path }
}

# --------------------------------- XAML ---------------------------------------
# GCB brand: green-forward dark. bg #1A242D, surface #283845, module #384E60,
# primary green #179E19, Signal Orange #FF4F00 accent, text #F1F3F5, muted #A5B0B7.
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Mabu Flash Utility" Height="680" Width="760"
        WindowStartupLocation="CenterScreen" Background="#1A242D"
        FontFamily="Segoe UI" ResizeMode="CanMinimize">
  <Window.Resources>
    <Style TargetType="Button">
      <Setter Property="Background" Value="#179E19"/>
      <Setter Property="Foreground" Value="#FFFFFF"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Padding" Value="18,9"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border Background="{TemplateBinding Background}" CornerRadius="6" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Ghost" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="#384E60"/>
    </Style>
    <Style TargetType="ProgressBar">
      <Setter Property="Height" Value="22"/>
      <Setter Property="Background" Value="#283845"/>
      <Setter Property="Foreground" Value="#179E19"/>
      <Setter Property="BorderThickness" Value="0"/>
    </Style>
  </Window.Resources>

  <Grid Margin="0">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
    </Grid.RowDefinitions>

    <!-- ===================== BRAND HEADER ===================== -->
    <Border Grid.Row="0" Background="#1A242D" BorderBrush="#33454F" BorderThickness="0,0,0,1" Padding="30,16">
      <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
        <Image x:Name="BrandLogo" Height="50" Margin="0,0,18,0"
               Stretch="Uniform" RenderOptions.BitmapScalingMode="HighQuality"/>
        <StackPanel VerticalAlignment="Center">
          <TextBlock Text="Mabu Flash Utility" FontSize="25" FontWeight="Bold" Foreground="#FFFFFF"/>
          <TextBlock Text="Welcome to the Mabu Liberation Front!" FontSize="13.5"
                     Foreground="#FF4F00" Margin="0,3,0,0" TextWrapping="Wrap"/>
        </StackPanel>
      </StackPanel>
    </Border>

    <!-- ===================== CONNECT SCREEN ===================== -->
    <Grid x:Name="ConnectScreen" Grid.Row="1" Margin="34">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/><RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>
      <TextBlock Grid.Row="0" Text="Connect Your Mabu" FontSize="22" FontWeight="SemiBold" Foreground="#FFFFFF"/>
      <TextBlock Grid.Row="1" Margin="0,4,0,20" FontSize="14" Foreground="#A5B0B7" TextWrapping="Wrap"
                 Text="Liberate &amp; Provision a Mabu Tablet."/>
      <Border Grid.Row="2" Background="#283845" CornerRadius="8" Padding="22">
        <StackPanel>
          <TextBlock Text="Before You Start" FontSize="16" FontWeight="SemiBold" Foreground="#61CE70" Margin="0,0,0,12"/>
          <TextBlock Foreground="#F1F3F5" FontSize="13.5" TextWrapping="Wrap" Margin="0,0,0,8"
                     Text="1.  Plug the tablet into this PC with the USB harness."/>
          <TextBlock Foreground="#F1F3F5" FontSize="13.5" TextWrapping="Wrap" Margin="0,0,0,8"
                     Text="2.  Hold the ADKEY, then power the tablet on; keep holding until this app detects it. (First flash: catches the Rockchip Loader.)"/>
          <TextBlock Foreground="#F1F3F5" FontSize="13.5" TextWrapping="Wrap" Margin="0,0,0,8"
                     Text="3.  If it boots to Android instead, join it to Wi-Fi, then continue."/>
          <TextBlock x:Name="ConnectStatus" Margin="0,14,0,0" FontSize="13.5" FontWeight="SemiBold"
                     Foreground="#FFB020" Text="Waiting for device..." TextWrapping="Wrap"/>
        </StackPanel>
      </Border>
      <StackPanel Grid.Row="3" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,20,0,0">
        <Button x:Name="StartBtn" Content="Start Flashing" IsEnabled="False"/>
      </StackPanel>
    </Grid>

    <!-- ===================== PROGRESS SCREEN ===================== -->
    <Grid x:Name="ProgressScreen" Grid.Row="1" Margin="34" Visibility="Collapsed">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>
      <TextBlock Grid.Row="0" x:Name="PhaseTitle" Text="Flashing..." FontSize="24" FontWeight="Bold" Foreground="#FFFFFF"/>

      <StackPanel Grid.Row="1" Margin="0,22,0,0">
        <DockPanel Margin="0,0,0,6">
          <TextBlock Text="Flashing" Foreground="#A5B0B7" FontSize="13"/>
          <TextBlock x:Name="FlashPctText" Text="0%" Foreground="#A5B0B7" FontSize="13" HorizontalAlignment="Right"/>
        </DockPanel>
        <ProgressBar x:Name="FlashBar" Minimum="0" Maximum="100" Value="0"/>
        <TextBlock x:Name="FlashLabel" Text="" Foreground="#61CE70" FontSize="12.5" Margin="0,5,0,0"/>
      </StackPanel>

      <StackPanel Grid.Row="2" Margin="0,20,0,0">
        <DockPanel Margin="0,0,0,6">
          <TextBlock Text="Validating" Foreground="#A5B0B7" FontSize="13"/>
          <TextBlock x:Name="ValidatePctText" Text="0%" Foreground="#A5B0B7" FontSize="13" HorizontalAlignment="Right"/>
        </DockPanel>
        <ProgressBar x:Name="ValidateBar" Minimum="0" Maximum="100" Value="0" Foreground="#61CE70"/>
        <TextBlock x:Name="ValidateLabel" Text="" Foreground="#61CE70" FontSize="12.5" Margin="0,5,0,0"/>
      </StackPanel>

      <Border Grid.Row="3" Margin="0,22,0,0" Background="#141C24" CornerRadius="8">
        <ScrollViewer x:Name="LogScroll" VerticalScrollBarVisibility="Auto" Padding="14,10">
          <TextBlock x:Name="LogText" FontFamily="Consolas" FontSize="12" Foreground="#C7D0D6" TextWrapping="Wrap"/>
        </ScrollViewer>
      </Border>
      <TextBlock Grid.Row="4" x:Name="DoneBanner" Visibility="Collapsed" Margin="0,16,0,0"
                 FontSize="16" FontWeight="Bold" TextWrapping="Wrap"/>
      <StackPanel Grid.Row="5" x:Name="RetryPanel" Orientation="Horizontal" HorizontalAlignment="Right"
                  Margin="0,16,0,0" Visibility="Collapsed">
        <Button x:Name="RetryBtn" Content="Retry Flash"/>
      </StackPanel>
    </Grid>

    <!-- ===================== PROMPT OVERLAY ===================== -->
    <Grid x:Name="PromptOverlay" Grid.RowSpan="2" Background="#CC0D141B" Visibility="Collapsed">
      <Border Background="#283845" CornerRadius="10" Padding="28" MaxWidth="520"
              VerticalAlignment="Center" HorizontalAlignment="Center">
        <StackPanel>
          <TextBlock x:Name="PromptTitle" FontSize="18" FontWeight="Bold" Foreground="#FFFFFF" Margin="0,0,0,10"/>
          <TextBlock x:Name="PromptBody" FontSize="13.5" Foreground="#F1F3F5" TextWrapping="Wrap" Margin="0,0,0,20"/>
          <StackPanel x:Name="PromptButtons" Orientation="Horizontal" HorizontalAlignment="Right"/>
        </StackPanel>
      </Border>
    </Grid>
  </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$Window = [Windows.Markup.XamlReader]::Load($reader)
$sync.Window = $Window

foreach ($n in 'ConnectScreen','ConnectStatus','StartBtn','ProgressScreen','PhaseTitle',
                'FlashBar','FlashPctText','FlashLabel','ValidateBar','ValidatePctText','ValidateLabel',
                'LogScroll','LogText','DoneBanner','RetryPanel','RetryBtn',
                'PromptOverlay','PromptTitle','PromptBody','PromptButtons','BrandLogo') {
    $sync[$n] = $Window.FindName($n)
}

# Brand: the GCB text logo (wordmark) in the header; the cat mark as the square
# window/taskbar icon. Loaded from assets\logos at runtime; cosmetic, so
# degrade silently if an asset isn't found.
function New-FrozenBitmap([string]$Path) {
    $b = New-Object Windows.Media.Imaging.BitmapImage
    $b.BeginInit()
    $b.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $b.UriSource   = New-Object System.Uri($Path)
    $b.EndInit()
    $b.Freeze()
    return $b
}
try {
    $logoDir  = Join-Path (Split-Path $sync.AppDir -Parent) 'assets\logos'
    $textLogo = Join-Path $logoDir 'gcb-text-logo.png'
    $catLogo  = Join-Path $logoDir 'gcb-cat-logo.png'
    if ((Test-Path $textLogo) -and $sync.BrandLogo) { $sync.BrandLogo.Source = New-FrozenBitmap $textLogo }
    if (Test-Path $catLogo) { $Window.Icon = New-FrozenBitmap $catLogo }
} catch { }

$brush    = New-Object Windows.Media.BrushConverter
$sevColor = @{ info='#C7D0D6'; ok='#61CE70'; warn='#FFB020'; fail='#FF4F00'; section='#FFFFFF' }

# ---------------- Queue drain: ALL WPF mutation happens here (UI thread) -------
function Update-FromQueue {
    while ($sync.Queue.Count -gt 0) {
        $m = $sync.Queue.Dequeue()
        switch ($m.type) {
            'section' {
                $sync.PhaseTitle.Text = $m.name
                Add-LogLine 'section' $m.name
            }
            'log'   { Add-LogLine $m.sev $m.msg }
            'flash' {
                $v = [math]::Min(100,[math]::Max(0,[double]$m.pct))
                $sync.FlashBar.Value = $v
                $sync.FlashPctText.Text = ("{0:0}%" -f $v)
                if ($m.label) { $sync.FlashLabel.Text = $m.label }
            }
            'validate' {
                $v = [math]::Min(100,[math]::Max(0,[double]$m.pct))
                $sync.ValidateBar.Value = $v
                $sync.ValidatePctText.Text = ("{0:0}%" -f $v)
                if ($m.label) { $sync.ValidateLabel.Text = $m.label }
            }
            'prompt' { Show-Prompt $m }
            'done'   {
                $sync.DoneBanner.Text = $m.summary
                $sync.DoneBanner.Foreground = $brush.ConvertFromString($(if ($m.ok) { '#61CE70' } else { '#FF4F00' }))
                $sync.DoneBanner.Visibility = 'Visible'
                $sync.PhaseTitle.Text = if ($m.ok) { 'Done' } else { 'Stopped' }
                $sync.RetryPanel.Visibility = if ($m.ok) { 'Collapsed' } else { 'Visible' }
            }
        }
    }
}

function Add-LogLine([string]$sev,[string]$msg) {
    $stamp  = (Get-Date).ToString('HH:mm:ss')
    $prefix = if ($sev -eq 'section') { '== ' } else { '   ' }
    $col    = $sevColor[$sev]; if (-not $col) { $col = '#C7D0D6' }
    $run = New-Object Windows.Documents.Run("$stamp $prefix$msg`r`n")
    $run.Foreground = $brush.ConvertFromString($col)
    [void]$sync.LogText.Inlines.Add($run)
    $sync.LogScroll.ScrollToEnd()
}

function Show-Prompt($m) {
    $sync.PromptTitle.Text = $m.title
    $sync.PromptBody.Text  = $m.body
    $sync.PromptButtons.Children.Clear()
    $first = $true
    foreach ($b in $m.buttons) {
        $btn = New-Object Windows.Controls.Button
        $btn.Content = $b
        $btn.Margin  = '10,0,0,0'
        if (-not $first) { $btn.Style = $sync.Window.FindResource('Ghost') }
        $choice = $b; $evt = $m.evt
        $btn.Add_Click({
            $sync.PromptResult = $choice
            $sync.PromptOverlay.Visibility = 'Collapsed'
            $evt.Set()
        }.GetNewClosure())
        [void]$sync.PromptButtons.Children.Add($btn)
        $first = $false
    }
    $sync.PromptOverlay.Visibility = 'Visible'
}

# ---- DispatcherTimer: pump the queue ~20x/sec on the UI thread ----
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(50)
$timer.Add_Tick({ Update-FromQueue })
$timer.Start()

# --------------------- UI-provider contract (built in worker) -----------------
# Self-contained: references ONLY $sync (shared by reference). Recreated inside
# the worker runspace from source so its closures belong to that runspace, but
# it never touches WPF; it only enqueues plain-data messages.
$NewWorkerUi = {
    @{
        Section  = { param($name)      $sync.Queue.Enqueue(@{ type='section'; name=$name }) }
        Log      = { param($sev,$msg)  $sync.Queue.Enqueue(@{ type='log'; sev=$sev; msg=$msg }) }
        Flash    = { param($pct,$lbl)  $sync.Queue.Enqueue(@{ type='flash'; pct=$pct; label=$lbl }) }
        Validate = { param($pct,$lbl)  $sync.Queue.Enqueue(@{ type='validate'; pct=$pct; label=$lbl }) }
        Done     = { param($ok,$sum)   $sync.Queue.Enqueue(@{ type='done'; ok=$ok; summary=$sum }) }
        Prompt   = { param($title,$body,$buttons)
            $evt = New-Object System.Threading.ManualResetEventSlim($false)
            $sync.PromptResult = $null
            $sync.Queue.Enqueue(@{ type='prompt'; title=$title; body=$body; buttons=$buttons; evt=$evt })
            $evt.Wait()
            return $sync.PromptResult
        }
    }
}.ToString()

# ------------------------------ Worker flows ----------------------------------
$SimulateFlow = {
    $ui = $sync.Ui
    & $ui.Log 'info' 'Simulation mode: no device is being touched.'
    $phases = @(
        @{ name='Loader Detection';                  pct=10;  secs=2; log=@(,@('ok','Detected State A (active Esper DPC) over ADB.'),@('info','Rebooting into Loader...'),@('ok','Loader caught after 6s.')) }
        @{ name='Loader Driver Binding (WinUSB)';     pct=18;  secs=1; log=@(,@('ok','PID 320A bound to WinUSB; rkdeveloptool ready.')) }
        @{ name='Applying Liberation Patches';        pct=32;  secs=3; log=@(,@('info','Writing parameter + adbd + 3x EOCD + 2x init...'),@('ok','All 8 patches written.')) }
        @{ name='Resetting Loader between Phases';    pct=40;  secs=2; log=@(,@('info','Booting to Android, re-entering Loader via ADB.'),@('ok','Loader re-caught after 5s.')) }
        @{ name='Wiping Head of /data (96 MB)';       pct=62;  secs=4; log=@(,@('info','Zeroing 96 MB...'),@('ok','/data head zeroed; vold will reformat on boot.')) }
        @{ name='Provisioning Transport (Wi-Fi ADB)'; pct=76;  secs=2; log=@(,@('ok','Wi-Fi ADB up at 192.168.0.18:5555.')) }
        @{ name='Installing User Apps';               pct=88;  secs=3; log=@(,@('ok','F-Droid installed.'),@('ok','Lawnchair installed + set as home.')) }
        @{ name='SELinux Policy Fix';                 pct=100; secs=2; log=@(,@('ok','Policy patched (03f180a2); reset issued.')) }
    )
    foreach ($p in $phases) {
        & $ui.Section $p.name
        foreach ($l in $p.log) { Start-Sleep -Milliseconds 500; & $ui.Log $l[0] $l[1] }
        if ($p.name -like 'Wiping*') {
            $choice = & $ui.Prompt 'Wi-Fi Needed after Wipe' `
                "The /data wipe clears the tablet's Wi-Fi credentials. On the tablet, join Wi-Fi, then press Continue." `
                @('Continue','Cancel')
            if ($choice -eq 'Cancel') { & $ui.Log 'warn' 'Canceled by user.'; & $ui.Done $false 'Canceled.'; return }
        }
        Start-Sleep -Seconds $p.secs
        & $ui.Flash $p.pct $p.name
    }
    & $ui.Section 'Self-Test'
    $checks = 'No device owner','init.esper.rc zeroed','Esper DPC absent','dm-verity disabled',
              'F-Droid installed','Lawnchair installed','Lawnchair is home','Factory mode installed',
              'SELinux enforcing','SELinux policy patched','Wi-Fi ADB reachable'
    for ($i=0; $i -lt $checks.Count; $i++) {
        Start-Sleep -Milliseconds 350
        & $ui.Log 'ok' "[PASS] $($checks[$i])"
        & $ui.Validate ((($i+1)/$checks.Count)*100) $checks[$i]
    }
    & $ui.Log 'ok' 'Self-test: 11 passed  0 failed  0 warnings'
    & $ui.Done $true 'Unit liberated, provisioned, and validated.'
}.ToString()

$RealFlow = {
    # Real flash: dot-source the UI-agnostic core and run it against the queue
    # provider. The repo root (parent of app/) is passed as -Root so the core's
    # relative paths (apks/, scripts/, tools/) resolve. Invoke-MabuFlash owns its
    # own try/catch and calls Done, so we only guard the load here.
    $ui = $sync.Ui
    try {
        . (Join-Path $sync.AppDir 'lib\MabuFlashCore.ps1')
    } catch {
        & $ui.Log 'fail' "Could not load MabuFlashCore.ps1: $_"
        & $ui.Done $false 'Flash core failed to load.'
        return
    }
    $repoRoot = Split-Path $sync.AppDir -Parent
    $opt = $sync.Options
    Invoke-MabuFlash -Ui $ui -Root $repoRoot `
        -SkipMabu:$opt.SkipMabu -WipeData:$opt.WipeData -NoWipe:$opt.NoWipe
}.ToString()

# --------------------- Start (or re-fire) the worker runspace ------------------
function Start-Flow {
    # Re-entrant: also used by the Retry button after a failed run, so reset
    # every piece of progress UI and tear down the previous runspace first.
    if ($sync.PS) { try { $sync.PS.Stop(); $sync.PS.Dispose() } catch {} }

    $sync.ConnectScreen.Visibility  = 'Collapsed'
    $sync.ProgressScreen.Visibility = 'Visible'
    $sync.LogText.Inlines.Clear()
    $sync.FlashBar.Value = 0;    $sync.FlashPctText.Text = '0%';    $sync.FlashLabel.Text = ''
    $sync.ValidateBar.Value = 0; $sync.ValidatePctText.Text = '0%'; $sync.ValidateLabel.Text = ''
    $sync.DoneBanner.Visibility = 'Collapsed'
    $sync.RetryPanel.Visibility = 'Collapsed'
    $sync.PhaseTitle.Text = 'Flashing...'

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'; $rs.ThreadOptions = 'ReuseThread'; $rs.Open()
    $rs.SessionStateProxy.SetVariable('sync', $sync)
    $rs.SessionStateProxy.SetVariable('NewWorkerUi', $NewWorkerUi)
    $rs.SessionStateProxy.SetVariable('SimulateFlow', $SimulateFlow)
    $rs.SessionStateProxy.SetVariable('RealFlow', $RealFlow)

    $ps = [powershell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddScript({
        # Recreate scriptblocks from source so they belong to THIS runspace.
        $sync.Ui = & ([scriptblock]::Create($NewWorkerUi))
        $flow    = [scriptblock]::Create($(if ($sync.Simulate) { $SimulateFlow } else { $RealFlow }))
        try { & $flow }
        catch {
            $sync.Queue.Enqueue(@{ type='log'; sev='fail'; msg="Unhandled error: $_" })
            $sync.Queue.Enqueue(@{ type='done'; ok=$false; summary='Flash aborted on an unexpected error.' })
        }
    })
    $sync.PS = $ps
    $sync.Handle = $ps.BeginInvoke()
}

# ------------------------------ Wire up events --------------------------------
$sync.StartBtn.Add_Click({ Start-Flow })
$sync.RetryBtn.Add_Click({ Start-Flow })

if ($Simulate) {
    $sync.ConnectStatus.Text = 'Simulation mode: no device required.'
    $sync.ConnectStatus.Foreground = $brush.ConvertFromString('#61CE70')
    $sync.StartBtn.IsEnabled = $true
} else {
    $sync.ConnectStatus.Text = 'Plug in the tablet (hold ADKEY through power-on for a first flash, or join Wi-Fi if it boots to Android), then click Start Flashing.'
    $sync.ConnectStatus.Foreground = $brush.ConvertFromString('#FFB020')
    $sync.StartBtn.IsEnabled = $true
}

$Window.Add_Closed({
    $timer.Stop()
    if ($sync.PS) { try { $sync.PS.Stop(); $sync.PS.Dispose() } catch {} }
})
[void]$Window.ShowDialog()
