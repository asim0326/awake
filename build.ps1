<#
    build.ps1  -  Compile awake.ps1 into Awake.exe (tray app, no console window)
    using PS2EXE (https://github.com/MScholtes/PS2EXE).

    Run:  powershell -NoProfile -ExecutionPolicy Bypass -File build.ps1

    Ship Awake.exe together with eye.ico (and optionally config.example.json).
#>
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

if (-not (Get-Module -ListAvailable -Name ps2exe)) {
    Write-Host 'PS2EXE is not installed. It is a free module from the PowerShell Gallery:'
    Write-Host '  https://www.powershellgallery.com/packages/ps2exe'
    $answer = Read-Host 'Install it now for the current user? [y/N]'
    if ($answer -notmatch '^(y|yes)$') { Write-Host 'Cancelled.'; exit 1 }
    Install-Module -Name ps2exe -Scope CurrentUser -Force
}
Import-Module ps2exe

Invoke-PS2EXE -InputFile awake.ps1 -OutputFile Awake.exe -IconFile eye.ico `
    -NoConsole -STA -Title 'Awake' -Product 'Awake' -Description 'Keeps your PC awake' -Version '1.1.0'

Write-Host "Built $(Join-Path $PSScriptRoot 'Awake.exe')" -ForegroundColor Green
