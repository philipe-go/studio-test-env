[CmdletBinding()]
param(
    [string]$HostName = [System.Net.Dns]::GetHostName(),
    [string]$ContainerName = "nginx-reverse-proxy",
    [string]$ConfigDirectory = "$PSScriptRoot\nginx",
    [string]$Image = "nginx:1.27-alpine",
    [string]$MongoNetworkName = "mongodb-network",
    [string]$RedisNetworkName = "redis-network",
    [string]$MongoExpressContainerName = "mongo-express",
    [string]$RedisInsightContainerName = "redisinsight",
    [string]$SwarmContainerName = "helix-swarm",
    [int]$Port = 80,
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

$mongoContainer = docker ps -a --filter "name=^/$MongoExpressContainerName$" --format "{{.Names}}"
$redisContainer = docker ps -a --filter "name=^/$RedisInsightContainerName$" --format "{{.Names}}"
$swarmContainer = docker ps -a --filter "name=^/$SwarmContainerName$" --format "{{.Names}}"
if (-not $mongoContainer) {
    throw "Container '$MongoExpressContainerName' was not found. Run mongodb-docker.ps1 first or pass the correct container name."
}
if (-not $redisContainer) {
    throw "Container '$RedisInsightContainerName' was not found. Run redis-docker.ps1 first or pass the correct container name."
}
if (-not $swarmContainer) {
    throw "Container '$SwarmContainerName' was not found. Run swarm-docker.ps1 or the Compose stack first."
}

$mongoNetwork = docker network ls --filter "name=^$MongoNetworkName$" --format "{{.Name}}"
if (-not ($mongoNetwork -contains $MongoNetworkName)) {
    throw "Docker network '$MongoNetworkName' was not found. Run mongodb-docker.ps1 first or pass the correct network name."
}
$redisNetwork = docker network ls --filter "name=^$RedisNetworkName$" --format "{{.Name}}"
if (-not ($redisNetwork -contains $RedisNetworkName)) {
    throw "Docker network '$RedisNetworkName' was not found. Run redis-docker.ps1 first or pass the correct network name."
}

New-Item -ItemType Directory -Path $ConfigDirectory -Force | Out-Null
$configPath = Join-Path $ConfigDirectory "nginx.conf"
Set-EnvValue -Name "SERVER_HOSTNAME" -Value $HostName
Set-EnvValue -Name "HTTP_PORT" -Value $Port

$config = @"
server {
    listen 80;
    server_name $HostName.mongodb.com;

    location / {
        proxy_pass http://$MongoExpressContainerName`:8081;
        proxy_set_header Host `$host;
        proxy_set_header X-Real-IP `$remote_addr;
        proxy_set_header X-Forwarded-For `$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto `$scheme;
    }
}

server {
    listen 80;
    server_name $HostName.redis.com;

    location / {
        proxy_pass http://$RedisInsightContainerName`:5540;
        proxy_set_header Host `$host;
        proxy_set_header X-Real-IP `$remote_addr;
        proxy_set_header X-Forwarded-For `$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto `$scheme;
    }
}

server {
    listen 80;
    server_name $HostName.swarm.com;

    location / {
        proxy_pass http://$SwarmContainerName`:80;
        proxy_set_header Host `$host;
        proxy_set_header X-Real-IP `$remote_addr;
        proxy_set_header X-Forwarded-For `$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto `$scheme;
    }
}
"@

Set-Content -Path $configPath -Value $config -Encoding ascii

function Connect-ToNetwork {
    param(
        [string]$NetworkName,
        [string]$TargetContainer
    )

    $networks = docker inspect $TargetContainer --format '{{json .NetworkSettings.Networks}}'
    if ($networks -notmatch ('"' + [regex]::Escape($NetworkName) + '"')) {
        docker network connect $NetworkName $TargetContainer | Out-Null
    }
}

Connect-ToNetwork -NetworkName $MongoNetworkName -TargetContainer $MongoExpressContainerName
Connect-ToNetwork -NetworkName $RedisNetworkName -TargetContainer $RedisInsightContainerName
Connect-ToNetwork -NetworkName $RedisNetworkName -TargetContainer $SwarmContainerName

$existingProxy = docker ps -a --filter "name=^/$ContainerName$" --format "{{.Names}}"
if ($existingProxy) {
    if ($Recreate) {
        docker rm -f $ContainerName | Out-Null
        $existingProxy = $null
    } else {
        docker start $ContainerName | Out-Null
    }
}

if (-not $existingProxy) {
    docker pull $Image
    docker run --detach `
        --name $ContainerName `
        --restart unless-stopped `
        --network $MongoNetworkName `
        --publish "0.0.0.0:${Port}:80" `
        --mount "type=bind,source=$configPath,target=/etc/nginx/conf.d/default.conf,readonly" `
        $Image | Out-Null
}

Connect-ToNetwork -NetworkName $RedisNetworkName -TargetContainer $ContainerName

try {
    New-NetFirewallRule `
        -DisplayName "Nginx reverse proxy ($Port)" `
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
Write-Host "Nginx reverse proxy is running:"
Write-Host "  Mongo Express: http://${HostName}.mongodb.com"
Write-Host "  RedisInsight:  http://${HostName}.redis.com"
Write-Host "  P4 Code Review: http://${HostName}.swarm.com"
Write-Host ""
Write-Host "Generated config: $configPath"
Write-Host ""
Write-Host "For another machine to resolve these names, add these entries to its hosts file or configure DNS:"
Write-Host "  <server-ip> ${HostName}.mongodb.com"
Write-Host "  <server-ip> ${HostName}.redis.com"
Write-Host "  <server-ip> ${HostName}.swarm.com"
Write-Host "Nginx provides the routing, but it does not provide DNS name resolution. HTTPS requires a TLS certificate and reverse-proxy configuration."
