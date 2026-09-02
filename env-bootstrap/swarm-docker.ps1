[CmdletBinding()]
param(
    [string]$ContainerName = "helix-swarm",
    [string]$Image = "perforce/helix-swarm:latest",
    [string]$DataVolumeName = "swarm-data",
    [string]$ConfigDirectory = "$PSScriptRoot\swarm",
    [string]$P4DPort = "host.docker.internal:1666",
    [string]$P4Super,
    [string]$P4SuperPassword,
    [string]$SwarmUser = "swarm",
    [string]$SwarmPassword,
    [string]$SwarmHost = "$([System.Net.Dns]::GetHostName()).swarm.com",
    [string]$RedisContainerName = "redis",
    [string]$RedisPassword,
    [string]$RedisNetworkName = "redis-network",
    [int]$Port = 8083,
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

foreach ($name in @("P4Super", "P4SuperPassword", "SwarmPassword", "RedisPassword")) {
    if (-not (Get-Variable $name -ValueOnly)) {
        throw "-$name is required for the initial Swarm configuration."
    }
}

$redisContainer = docker ps -a --filter "name=^/$RedisContainerName$" --format "{{.Names}}"
if (-not $redisContainer) {
    throw "Redis container '$RedisContainerName' was not found. Start redis-docker.ps1 or the Compose stack first."
}

$redisNetwork = docker network ls --filter "name=^$RedisNetworkName$" --format "{{.Name}}"
if (-not ($redisNetwork -contains $RedisNetworkName)) {
    throw "Docker network '$RedisNetworkName' was not found. Start redis-docker.ps1 or the Compose stack first."
}

$redisNetworks = docker inspect $RedisContainerName --format '{{json .NetworkSettings.Networks}}'
if ($redisNetworks -notmatch ('"' + [regex]::Escape($RedisNetworkName) + '"')) {
    docker network connect $RedisNetworkName $RedisContainerName | Out-Null
}

New-Item -ItemType Directory -Path $ConfigDirectory -Force | Out-Null
$envPath = Join-Path $ConfigDirectory ".env"
$envContent = @"
P4D_PORT=$P4DPort
P4D_SUPER=$P4Super
P4D_SUPER_PASSWD=$P4SuperPassword
SWARM_USER=$SwarmUser
SWARM_PASSWD=$SwarmPassword
SWARM_HOST=$SwarmHost
SWARM_REDIS=$RedisContainerName
SWARM_REDIS_PORT=6379
SWARM_REDIS_PASSWD=$RedisPassword
"@
Set-Content -Path $envPath -Value $envContent.Trim() -Encoding ascii
Set-EnvValue -Name "P4D_PORT" -Value $P4DPort
Set-EnvValue -Name "P4D_SUPER" -Value $P4Super
Set-EnvValue -Name "P4D_SUPER_PASSWD" -Value $P4SuperPassword
Set-EnvValue -Name "SWARM_USER" -Value $SwarmUser
Set-EnvValue -Name "SWARM_PASSWD" -Value $SwarmPassword
Set-EnvValue -Name "SWARM_HOST" -Value $SwarmHost
Set-EnvValue -Name "SWARM_REDIS" -Value $RedisContainerName
Set-EnvValue -Name "SWARM_REDIS_PORT" -Value 6379
Set-EnvValue -Name "SWARM_REDIS_PASSWD" -Value $RedisPassword

$existingContainer = docker ps -a --filter "name=^/$ContainerName$" --format "{{.Names}}"
if ($existingContainer) {
    if ($Recreate) {
        docker rm -f $ContainerName | Out-Null
        $existingContainer = $null
    } else {
        docker start $ContainerName | Out-Null
        Write-Host "Swarm container '$ContainerName' is already configured and has been started."
    }
}

if (-not $existingContainer) {
    docker volume create $DataVolumeName | Out-Null
    docker pull $Image
    docker run --detach `
        --name $ContainerName `
        --network $RedisNetworkName `
        --network-alias $ContainerName `
        --restart unless-stopped `
        --publish "0.0.0.0:${Port}:80" `
        --volume "${DataVolumeName}:/opt/perforce/swarm/data" `
        --env-file $envPath `
        $Image | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Could not start the Swarm container."
    }
    Write-Host "P4 Code Review container '$ContainerName' has been started."
}

try {
    New-NetFirewallRule `
        -DisplayName "P4 Code Review ($Port)" `
        -Direction Inbound `
        -Action Allow `
        -Protocol TCP `
        -LocalPort $Port `
        -Profile Private `
        -ErrorAction Stop | Out-Null
} catch {
    Write-Warning "Could not add the firewall rule. Run this script as Administrator or allow TCP port $Port manually."
}

Write-Host ""
Write-Host "P4 Code Review is available at http://$SwarmHost and http://<server-ip>:$Port."
Write-Host "Swarm data volume: $DataVolumeName"
Write-Host "Swarm configuration file: $envPath"
Write-Host "P4 Server: $P4DPort"
Write-Host "Redis: $RedisContainerName`:6379"
Write-Host ""
Write-Host "The initial configuration is stored in the mounted data volume. Protect '$envPath' because it contains passwords."
Write-Host "Perforce super and Swarm users must already be valid or be created during initial configuration."
