[CmdletBinding()]
param(
    [string]$InstallDirectory = "$env:ProgramFiles\Perforce",
    [string]$ServerRoot = "$env:ProgramData\Perforce\root",
    [string]$LogDirectory = "$env:ProgramData\Perforce\logs",
    [string]$DownloadUrl = "https://ftp.perforce.com/perforce/r25.1/bin.ntx64/p4d.exe",
    [int]$Port = 1666,
    [switch]$ReDownload
)

$ErrorActionPreference = "Stop"

if (-not (Get-Command Invoke-WebRequest -ErrorAction SilentlyContinue)) {
    throw "Invoke-WebRequest is not available in this PowerShell session."
}

function Set-EnvValue {
    param([string]$Name, [string]$Value)
    $envPath = Join-Path $PSScriptRoot ".env"
    $lines = if (Test-Path $envPath) { @(Get-Content $envPath) } else { @() }
    $escapedName = [regex]::Escape($Name)
    $found = $false
    $lines = @($lines | ForEach-Object {
        if ($_ -match "^$escapedName=") { $found = $true; "$Name=$Value" } else { $_ }
    })
    if (-not $found) { $lines += "$Name=$Value" }
    Set-Content -Path $envPath -Value $lines -Encoding ascii
}

New-Item -ItemType Directory -Path $InstallDirectory -Force | Out-Null
New-Item -ItemType Directory -Path $ServerRoot -Force | Out-Null
New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null

$serverPath = Join-Path $InstallDirectory "p4d.exe"
$tempPath = "$serverPath.download"
Set-EnvValue -Name "P4_PORT" -Value $Port
Set-EnvValue -Name "P4_INSTALL_DIRECTORY" -Value $InstallDirectory
Set-EnvValue -Name "P4_SERVER_ROOT" -Value $ServerRoot
Set-EnvValue -Name "P4_LOG_DIRECTORY" -Value $LogDirectory
Set-EnvValue -Name "P4_DOWNLOAD_URL" -Value $DownloadUrl

if (-not (Test-Path $serverPath) -or $ReDownload) {
    Write-Host "Downloading p4d from $DownloadUrl"
    Invoke-WebRequest -Uri $DownloadUrl -OutFile $tempPath
    Move-Item -Path $tempPath -Destination $serverPath -Force
}

if (-not (Test-Path $serverPath)) {
    throw "p4d.exe was not installed at '$serverPath'."
}

try {
    New-NetFirewallRule `
        -DisplayName "Perforce Helix Core ($Port)" `
        -Direction Inbound `
        -Action Allow `
        -Protocol TCP `
        -LocalPort $Port `
        -Profile Private `
        -ErrorAction Stop | Out-Null
} catch {
    Write-Warning "Could not add the firewall rule. Allow TCP port $Port manually on the Private profile."
}

$hostName = [System.Net.Dns]::GetHostName()
$addresses = Get-NetIPAddress -AddressFamily IPv4 -PrefixOrigin Dhcp,Manual -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -notlike "169.254.*" -and $_.IPAddress -ne "127.0.0.1" } |
    Select-Object -ExpandProperty IPAddress -Unique

Write-Host ""
Write-Host "Perforce Helix Core server executable is ready."
Write-Host "Server root: $ServerRoot"
Write-Host "p4d executable: $serverPath"
Write-Host ""
Write-Host "Connect using P4PORT=${hostName}:${Port}"
foreach ($address in $addresses) {
    Write-Host "Connect using P4PORT=${address}:${Port}"
}
Write-Host ""
Write-Host "Perforce uses native TCP, not HTTP/HTTPS; configure DNS or the client hosts file for friendly hostnames."
Write-Host "Starting p4d directly. Press Ctrl+C to stop the server."

& $serverPath `
    -r $ServerRoot `
    -p $Port `
    -L (Join-Path $LogDirectory "server.log") `
    -J (Join-Path $LogDirectory "journal")
