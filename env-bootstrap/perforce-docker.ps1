[CmdletBinding()]
param(
    [string]$ContainerName = "perforce",
    [string]$VolumeName = "perforce-data",
    [string]$Image = "perforce/helix-p4d:latest",
    [int]$Port = 1666,
    [string]$ServerId = "master",
    [string]$CaseSensitivity = "sensitive",
    [switch]$Recreate
)

$ErrorActionPreference = "Stop"

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw "Docker CLI was not found. Install and start Docker Desktop, then run this script again."
}

docker info *> $null
if ($LASTEXITCODE -ne 0) {
    throw "Docker is installed but the Docker engine is not running. Start Docker Desktop and try again."
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

$existingContainer = docker ps -a --filter "name=^/$ContainerName$" --format "{{.Names}}"
if ($existingContainer) {
    if ($Recreate) {
        docker rm -f $ContainerName | Out-Null
        $existingContainer = $null
    } else {
        docker start $ContainerName | Out-Null
        Write-Host "Perforce container '$ContainerName' is already configured and has been started."
    }
}

if (-not $existingContainer) {
    docker pull $Image
    docker volume create $VolumeName | Out-Null
    docker run --detach `
        --name $ContainerName `
        --restart unless-stopped `
        --publish "0.0.0.0:${Port}:1666" `
        --volume "${VolumeName}:/opt/perforce/servers" `
        --env "P4SERVER_ID=$ServerId" `
        --env "CASE_SENSITIVE=$CaseSensitivity" `
        $Image | Out-Null
    Write-Host "Perforce container '$ContainerName' has been started."
}

$hostName = [System.Net.Dns]::GetHostName()
Set-EnvValue -Name "P4_CONTAINER_NAME" -Value $ContainerName
Set-EnvValue -Name "P4_PORT" -Value $Port
Set-EnvValue -Name "P4_SERVER_ID" -Value $ServerId
Set-EnvValue -Name "P4_CASE_SENSITIVITY" -Value $CaseSensitivity

try {
    New-NetFirewallRule `
        -DisplayName "Perforce ($Port)" `
        -Direction Inbound `
        -Action Allow `
        -Protocol TCP `
        -LocalPort $Port `
        -Profile Private `
        -ErrorAction Stop | Out-Null
    Write-Host "Windows Firewall rule added for TCP port $Port on the Private profile."
} catch {
    Write-Warning "Could not add the firewall rule. Run this script as Administrator or allow TCP port $Port manually."
}

$hostName = [System.Net.Dns]::GetHostName()
$addresses = Get-NetIPAddress -AddressFamily IPv4 -PrefixOrigin Dhcp,Manual -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -notlike "169.254.*" -and $_.IPAddress -ne "127.0.0.1" } |
    Select-Object -ExpandProperty IPAddress -Unique

Write-Host ""
Write-Host "Perforce Helix Server is listening on:"
Write-Host "  $hostName`:$Port"
foreach ($address in $addresses) {
    Write-Host "  ${address}:$Port"
}
Write-Host ""
Write-Host "Docker container: $ContainerName"
Write-Host "Persistent volume: $VolumeName"
Write-Host "Connect with P4PORT=${hostName}:${Port} or P4PORT=<server-ip>:${Port}."
Write-Host "Perforce uses native TCP, not HTTP/HTTPS; add the server hostname to DNS or the client hosts file if needed."
