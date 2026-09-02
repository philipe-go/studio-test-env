[CmdletBinding()]
param(
    [string]$ContainerName = "horde",
    [string]$NetworkName = "horde-network",
    [string]$DataVolume = "horde-data",
    [string]$Image = "ghcr.io/epicgames/unrealhorde:latest",
    [int]$Port = 8085,
    [string]$HostName = [System.Net.Dns]::GetHostName(),
    [string]$BaseUrl,
    [string]$ContainerPort = "8080",
    [switch]$Recreate,
    [string[]]$AdditionalArgs = @()
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
        if ($_ -match "^$escapedName=") {
            $found = $true
            "$Name=$Value"
        } else { $_ }
    })
    if (-not $found) { $lines += "$Name=$Value" }
    Set-Content -Path $envPath -Value $lines -Encoding ascii
}

$existingNetwork = docker network ls --filter "name=^$NetworkName$" --format "{{.Name}}"
if (-not $existingNetwork) {
    docker network create $NetworkName | Out-Null
}

if (-not $BaseUrl) {
    $BaseUrl = "http://${HostName}:${Port}"
}

Set-EnvValue -Name "HORD_IMAGE" -Value $Image
Set-EnvValue -Name "HORD_PORT" -Value $Port
Set-EnvValue -Name "HORD_HOSTNAME" -Value $HostName
Set-EnvValue -Name "HORD_URL" -Value $BaseUrl

$existingContainer = docker ps -a --filter "name=^/$ContainerName$" --format "{{.Names}}"
if ($existingContainer -and $Recreate) {
    docker rm -f $ContainerName | Out-Null
    $existingContainer = $null
}

if (-not $existingContainer) {
    docker pull $Image
    docker volume create $DataVolume | Out-Null

    $dockerArguments = @(
        "run", "--detach",
        "--name", $ContainerName,
        "--restart", "unless-stopped",
        "--network", $NetworkName,
        "--publish", "0.0.0.0:${Port}:${ContainerPort}",
        "--volume", "${DataVolume}:/data",
        "--env", "HORD_HOST=${HostName}",
        "--env", "HORD_PORT=${ContainerPort}"
    )

    foreach ($argument in $AdditionalArgs) {
        $dockerArguments += $argument
    }

    $dockerArguments += $Image

    & docker @dockerArguments | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to start the Unreal Horde container. Adjust -Image or -AdditionalArgs to match the upstream Linux container run command."
    }

    Write-Host "Unreal Horde container '$ContainerName' has been started."
} else {
    docker start $ContainerName | Out-Null
    Write-Host "Unreal Horde container '$ContainerName' was already present and has been started."
}

try {
    New-NetFirewallRule `
        -DisplayName "Unreal Horde ($Port)" `
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

$addresses = Get-NetIPAddress -AddressFamily IPv4 -PrefixOrigin Dhcp,Manual -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -notlike "169.254.*" -and $_.IPAddress -ne "127.0.0.1" } |
    Select-Object -ExpandProperty IPAddress -Unique

Write-Host ""
Write-Host "Unreal Horde is listening on:"
Write-Host "  $BaseUrl"
foreach ($address in $addresses) {
    Write-Host "  http://${address}:${Port}"
}
Write-Host ""
Write-Host "Container name: $ContainerName"
Write-Host "Docker image: $Image"
Write-Host "Data volume: $DataVolume"
Write-Host "Docker network: $NetworkName"
Write-Host ""
Write-Host "Use -AdditionalArgs to pass the exact environment variables or flags shown in Epic's Linux instructions."
Write-Host "Example:"
Write-Host "  .\horde-docker.ps1 -Port 8085 -Image 'ghcr.io/epicgames/unrealhorde:latest' -AdditionalArgs @('--env', 'HORD_LOG_LEVEL=debug')"
Write-Host ""
Write-Host "If Epic's upstream image uses a different internal port or entrypoint, update the -ContainerPort and -AdditionalArgs values to match it."
