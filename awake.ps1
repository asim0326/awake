# Awake.ps1 (PS2EXE-safe, idle-aware, Start/Stop, colored status)
# Keeps the PC (and your Teams/Slack "Available" status) awake by nudging the
# mouse 1px after a period of no input. Settings live in config.json next to
# the script/exe - see README.md.
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ErrorActionPreference = 'Stop'

try {
    # Folder of the script, or of Awake.exe when compiled with PS2EXE
    # ($PSScriptRoot isn't set inside a PS2EXE exe).
    if ($MyInvocation.MyCommand.CommandType -eq 'ExternalScript') {
        $basePath = Split-Path -Parent -Path $MyInvocation.MyCommand.Definition
    } else {
        $basePath = Split-Path -Parent -Path ([Environment]::GetCommandLineArgs()[0])
    }
    $configPath  = Join-Path $basePath 'config.json'
    $examplePath = Join-Path $basePath 'config.example.json'

    # Native helpers: idle time + mouse nudge via SendInput (avoids PowerShell '+' issues)
    $null = Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class Native
{
    [StructLayout(LayoutKind.Sequential)]
    public struct LASTINPUTINFO
    {
        public uint cbSize;
        public uint dwTime;
    }

    [DllImport("user32.dll")]
    static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);

    public static uint GetIdleTimeMs()
    {
        LASTINPUTINFO lii = new LASTINPUTINFO();
        lii.cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO));
        GetLastInputInfo(ref lii);
        return (uint)Environment.TickCount - lii.dwTime;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT
    {
        public uint type;
        public MOUSEINPUT mi;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSEINPUT
    {
        public int dx;
        public int dy;
        public uint mouseData;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    const uint INPUT_MOUSE = 0;
    const uint MOUSEEVENTF_MOVE = 0x0001;

    [DllImport("user32.dll", SetLastError = true)]
    static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

    public static void NudgeMouse(int pixels)
    {
        // Move by +N then -N pixels (very small), no clicks
        INPUT[] inputs = new INPUT[2];

        inputs[0].type = INPUT_MOUSE;
        inputs[0].mi.dx = pixels;
        inputs[0].mi.dy = 0;
        inputs[0].mi.dwFlags = MOUSEEVENTF_MOVE;

        inputs[1].type = INPUT_MOUSE;
        inputs[1].mi.dx = -pixels;
        inputs[1].mi.dy = 0;
        inputs[1].mi.dwFlags = MOUSEEVENTF_MOVE;

        SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT)));
    }

    [DllImport("kernel32.dll")]
    static extern uint SetThreadExecutionState(uint esFlags);
    const uint ES_CONTINUOUS       = 0x80000000;
    const uint ES_SYSTEM_REQUIRED  = 0x00000001;
    const uint ES_DISPLAY_REQUIRED = 0x00000002;

    public static void PreventSleep() { SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED); }
    public static void AllowSleep()   { SetThreadExecutionState(ES_CONTINUOUS); }
}
"@

    # Settings: built-in defaults, overridden by config.json
    function Get-AwakeSettings([switch]$DefaultsOnly) {
        $s = @{
            idleSeconds       = 180      # nudge after this long without input
            checkSeconds      = 30       # how often to check
            nudgePixels       = 1
            preventSleep      = $true    # also tell Windows not to sleep while Online
            startOnline       = $false   # start in the Online state
            showNotifications = $true
            icon              = 'eye.ico'
            appName           = 'Awake'
            onlineText        = 'Online'
            offlineText       = 'Offline'
            onlineColor       = 'Green'
            offlineColor      = 'Red'
        }
        if ($DefaultsOnly) { return $s }
        if (-not (Test-Path -LiteralPath $configPath)) {
            try {
                if (Test-Path -LiteralPath $examplePath) { Copy-Item -LiteralPath $examplePath -Destination $configPath }
                else { $s | ConvertTo-Json | Set-Content -LiteralPath $configPath -Encoding UTF8 }
            } catch { }   # read-only folder: just run on defaults
        }
        if (Test-Path -LiteralPath $configPath) {
            $json = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
            foreach ($p in $json.PSObject.Properties) {
                if ($p.Name.StartsWith('_') -or -not $s.ContainsKey($p.Name) -or $null -eq $p.Value) { continue }
                $current = $s[$p.Name]
                if ($current -is [bool]) {
                    $s[$p.Name] = if ($p.Value -is [string]) { [bool]::Parse($p.Value) } else { [bool]$p.Value }
                } elseif ($current -is [int]) {
                    $s[$p.Name] = [int]$p.Value
                } else {
                    $s[$p.Name] = [string]$p.Value
                }
            }
        }
        $s.idleSeconds  = [Math]::Max(10, $s.idleSeconds)
        $s.checkSeconds = [Math]::Max(1, $s.checkSeconds)
        $s.nudgePixels  = [Math]::Max(1, $s.nudgePixels)
        return $s
    }

    function Get-Color([string]$Name, [string]$Fallback) {
        try {
            $c = [System.Drawing.ColorTranslator]::FromHtml($Name)
            if ($c.IsEmpty) { throw 'empty' }
            return $c
        } catch { return [System.Drawing.ColorTranslator]::FromHtml($Fallback) }
    }

    # State
    $script:isOnline = $false
    $script:settings = $null

    [System.Windows.Forms.Application]::EnableVisualStyles()

    # Tray icon
    $tray = New-Object System.Windows.Forms.NotifyIcon
    $tray.Visible = $true

    # Context menu
    $menu = New-Object System.Windows.Forms.ContextMenuStrip

    # Colored status label
    $statusLabel = New-Object System.Windows.Forms.ToolStripLabel
    $statusLabel.Font = New-Object System.Drawing.Font($statusLabel.Font, [System.Drawing.FontStyle]::Bold)

    $startItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $startItem.Text = "Start"

    $stopItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $stopItem.Text = "Stop"

    $editItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $editItem.Text = "Edit settings..."

    $reloadItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $reloadItem.Text = "Reload settings"

    $exitItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $exitItem.Text = "Exit"

    $null = $menu.Items.Add($statusLabel)
    $null = $menu.Items.Add("-")
    $null = $menu.Items.Add($startItem)
    $null = $menu.Items.Add($stopItem)
    $null = $menu.Items.Add("-")
    $null = $menu.Items.Add($editItem)
    $null = $menu.Items.Add($reloadItem)
    $null = $menu.Items.Add("-")
    $null = $menu.Items.Add($exitItem)

    function Show-Tip([string]$Text) {
        if ($script:settings.showNotifications) {
            $tray.ShowBalloonTip(800, $script:settings.appName, $Text, "Info") | Out-Null
        }
    }

    function Set-TrayText([string]$Text) {
        # NotifyIcon.Text is limited to 63 characters
        if ($Text.Length -gt 63) { $Text = $Text.Substring(0, 63) }
        $tray.Text = $Text
    }

    function Set-Online {
        $script:isOnline = $true
        $statusLabel.Text = $script:settings.onlineText
        $statusLabel.ForeColor = Get-Color $script:settings.onlineColor 'Green'
        Set-TrayText "$($script:settings.appName) - $($script:settings.onlineText)"
        $startItem.Enabled = $false
        $stopItem.Enabled  = $true
        if ($script:settings.preventSleep) { [Native]::PreventSleep() }
    }

    function Set-Offline {
        $script:isOnline = $false
        $statusLabel.Text = $script:settings.offlineText
        $statusLabel.ForeColor = Get-Color $script:settings.offlineColor 'Red'
        Set-TrayText "$($script:settings.appName) - $($script:settings.offlineText)"
        $startItem.Enabled = $true
        $stopItem.Enabled  = $false
        [Native]::AllowSleep()
    }

    # Timer
    $script:timer = New-Object System.Windows.Forms.Timer

    function Apply-Settings([switch]$DefaultsOnly) {
        $script:settings = Get-AwakeSettings -DefaultsOnly:$DefaultsOnly
        $iconPath = [Environment]::ExpandEnvironmentVariables($script:settings.icon)
        if (-not [IO.Path]::IsPathRooted($iconPath)) { $iconPath = Join-Path $basePath $iconPath }
        if (Test-Path -LiteralPath $iconPath) {
            $tray.Icon = New-Object System.Drawing.Icon($iconPath)
        } else {
            $tray.Icon = [System.Drawing.SystemIcons]::Application
        }
        $script:timer.Interval = $script:settings.checkSeconds * 1000
        if ($script:isOnline) { Set-Online } else { Set-Offline }
    }

    $null = $script:timer.Add_Tick({
        try {
            if (-not $script:isOnline) { return }

            $idle = [Native]::GetIdleTimeMs()
            if ($idle -ge ($script:settings.idleSeconds * 1000)) {
                [Native]::NudgeMouse($script:settings.nudgePixels)
            }
            if ($script:settings.preventSleep) { [Native]::PreventSleep() }
        } catch {
            # Never crash into JIT dialogs; ignore tick errors
        }
    })

    # Menu actions
    $null = $startItem.Add_Click({
        $script:timer.Start()
        Set-Online
        Show-Tip $script:settings.onlineText
    })

    $null = $stopItem.Add_Click({
        $script:timer.Stop()
        Set-Offline
        Show-Tip $script:settings.offlineText
    })

    $null = $editItem.Add_Click({
        if (-not (Test-Path -LiteralPath $configPath)) { Get-AwakeSettings | Out-Null }
        Start-Process notepad.exe -ArgumentList "`"$configPath`""
    })

    $null = $reloadItem.Add_Click({
        try {
            Apply-Settings
            Show-Tip 'Settings reloaded'
        } catch {
            [System.Windows.Forms.MessageBox]::Show(
                "Could not load config.json:`r`n`r`n$($_.Exception.Message)`r`n`r`nTip: write paths with / or \\ in JSON.",
                "$($script:settings.appName) - Settings",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
        }
    })

    $null = $exitItem.Add_Click({
        $script:timer.Stop()
        [Native]::AllowSleep()
        $tray.Visible = $false
        $tray.Dispose()
        [System.Windows.Forms.Application]::Exit()
    })

    $tray.ContextMenuStrip = $menu

    try {
        Apply-Settings
    } catch {
        # A broken config.json shouldn't stop Awake from starting: warn and run on defaults
        Apply-Settings -DefaultsOnly
        [System.Windows.Forms.MessageBox]::Show(
            "Could not load config.json - using default settings.`r`n`r`n$($_.Exception.Message)`r`n`r`nTip: write paths with / or \\ in JSON.",
            "Awake - Settings",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
    }

    # Default state on open: Offline, unless startOnline is set
    if ($script:settings.startOnline) {
        $script:timer.Start()
        Set-Online
    } else {
        Set-Offline
    }

    [System.Windows.Forms.Application]::Run() | Out-Null
}
catch {
    [System.Windows.Forms.MessageBox]::Show(
        $_.Exception.Message + "`r`n`r`n" + $_.ScriptStackTrace,
        "Awake - Error",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
}
