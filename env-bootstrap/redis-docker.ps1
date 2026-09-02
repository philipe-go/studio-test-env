[CmdletBinding()]
param(
    [string]$ContainerName = "redis",
    [string]$VolumeName = "redis-data",
    [string]$Image = "redis:7-alpine",
    [int]$Port = 6379,
    [string]$InsightContainerName = "redisinsight",
    [int]$InsightPort = 5540,
    [string]$InsightImage = "redis/redisinsight:latest",
    [string]$NetworkName = "redis-network",
    [string]$Password,
    [switch]$Recreate,
    [switch]$SkipInsight
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
        } else {
            $_
        }
    })
    if (-not $found) { $lines += "$Name=$Value" }
    Set-Content -Path $envPath -Value $lines -Encoding ascii
}

$existingNetwork = docker network ls --filter "name=^$NetworkName$" --format "{{.Name}}"
if (-not $existingNetwork) {
    docker network create $NetworkName | Out-Null
}

$passwordWasGenerated = -not $Password
if ($passwordWasGenerated) {
    $bytes = New-Object byte[] 24
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $Password = [Convert]::ToBase64String($bytes).TrimEnd("=").Replace("+", "-").Replace("/", "_")
}

$existingContainer = docker ps -a --filter "name=^/$ContainerName$" --format "{{.Names}}"
if ($existingContainer -and -not $Password) {
    $command = @(docker inspect $ContainerName --format '{{json .Config.Cmd}}' | ConvertFrom-Json)
    $passwordIndex = [Array]::IndexOf($command, "--requirepass")
    if ($passwordIndex -ge 0 -and $passwordIndex + 1 -lt $command.Count) {
        $Password = $command[$passwordIndex + 1]
    }
}

if ($existingContainer) {
    if ($Recreate) {
        docker rm -f $ContainerName | Out-Null
        $existingContainer = $null
    } else {
        docker start $ContainerName | Out-Null
        Write-Host "Redis container '$ContainerName' is already configured and has been started."
    }
} else {
    docker pull $Image
    docker volume create $VolumeName | Out-Null
    docker run --detach `
        --name $ContainerName `
        --restart unless-stopped `
        --network $NetworkName `
        --publish "0.0.0.0:${Port}:6379" `
        --volume "${VolumeName}:/data" `
        $Image `
        redis-server --appendonly yes --requirepass $Password | Out-Null
    Write-Host "Redis container '$ContainerName' has been started."
}

$hostName = [System.Net.Dns]::GetHostName()
Set-EnvValue -Name "REDIS_PASSWORD" -Value $Password
Set-EnvValue -Name "REDIS_PORT" -Value $Port
Set-EnvValue -Name "REDISINSIGHT_PORT" -Value $InsightPort
Set-EnvValue -Name "SERVER_HOSTNAME" -Value $hostName

if (-not $SkipInsight) {
    $insightContainer = docker ps -a --filter "name=^/$InsightContainerName$" --format "{{.Names}}"
    if ($insightContainer -and $Recreate) {
        docker rm -f $InsightContainerName | Out-Null
        $insightContainer = $null
    }

    $redisNetworks = docker inspect $ContainerName --format '{{json .NetworkSettings.Networks}}'
    if ($redisNetworks -notmatch ('"' + [regex]::Escape($NetworkName) + '"')) {
        docker network connect $NetworkName $ContainerName | Out-Null
    }

    if ($insightContainer) {
        docker start $InsightContainerName | Out-Null
    } else {
        docker volume create "${InsightContainerName}-data" | Out-Null
        docker pull $InsightImage
        docker run --detach `
            --name $InsightContainerName `
            --restart unless-stopped `
            --network $NetworkName `
            --publish "0.0.0.0:${InsightPort}:5540" `
            --volume "${InsightContainerName}-data:/data" `
            $InsightImage | Out-Null
    }
}

try {
    New-NetFirewallRule `
        -DisplayName "Redis ($Port)" `
        -Direction Inbound `
        -Action Allow `
        -Protocol TCP `
        -LocalPort $Port `
        -Profile Private `
        -ErrorAction Stop | Out-Null
    Write-Host "Windows Firewall rule added for TCP port $Port on the Private profile."
    if (-not $SkipInsight) {
        New-NetFirewallRule `
            -DisplayName "RedisInsight ($InsightPort)" `
            -Direction Inbound `
            -Action Allow `
            -Protocol TCP `
            -LocalPort $InsightPort `
            -Profile Private `
            -ErrorAction Stop | Out-Null
        Write-Host "Windows Firewall rule added for RedisInsight TCP port $InsightPort on the Private profile."
    }
} catch {
    Write-Warning "Could not add all firewall rules. Run this script as Administrator or allow TCP ports $Port and $InsightPort manually."
}

$addresses = Get-NetIPAddress -AddressFamily IPv4 -PrefixOrigin Dhcp,Manual -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -notlike "169.254.*" -and $_.IPAddress -ne "127.0.0.1" } |
    Select-Object -ExpandProperty IPAddress -Unique

Write-Host ""
Write-Host "Redis is listening on:"
Write-Host "  redis://:${Password}@${hostName}:${Port}"
foreach ($address in $addresses) {
    Write-Host "  redis://:${Password}@${address}:${Port}"
}
Write-Host ""
if ($passwordWasGenerated -and -not $existingContainer) {
    Write-Host "Authentication password: $Password"
} else {
    Write-Host "The existing container's authentication password was not changed."
}
Write-Host "Use the password with Redis clients; do not expose port $Port beyond your trusted network."
if (-not $SkipInsight) {
    Write-Host "RedisInsight UI: http://${hostName}:${InsightPort}"
    Write-Host "In RedisInsight, add Redis at redis://${ContainerName}:6379 using the password above."
}
Write-Host "A URL such as https://redis.$hostName is not a native Redis endpoint. It requires DNS plus an HTTPS/TLS proxy in front of Redis."