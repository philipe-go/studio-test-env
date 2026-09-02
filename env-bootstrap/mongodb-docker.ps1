[CmdletBinding()]
param(
    [string]$ContainerName = "mongodb",
    [string]$VolumeName = "mongodb-data",
    [string]$Image = "mongo:8",
    [int]$Port = 27017,
    [string]$MongoUser = "admin",
    [string]$MongoPassword,
    [string]$ExpressContainerName = "mongo-express",
    [string]$ExpressImage = "mongo-express:1.0.2-20-alpine3.19",
    [string]$ExpressUser = "admin",
    [string]$ExpressPassword,
    [int]$ExpressPort = 8081,
    [string]$NetworkName = "mongodb-network",
    [switch]$Recreate,
    [switch]$SkipExpress
)

$ErrorActionPreference = "Stop"

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw "Docker CLI was not found. Install and start Docker Desktop, then run this script again."
}

docker info *> $null
if ($LASTEXITCODE -ne 0) {
    throw "Docker is installed but the Docker engine is not running. Start Docker Desktop and try again."
}

function New-SecurePassword {
    $bytes = New-Object byte[] 24
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    return [Convert]::ToBase64String($bytes).TrimEnd("=").Replace("+", "-").Replace("/", "_")
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

$existingContainer = docker ps -a --filter "name=^/$ContainerName$" --format "{{.Names}}"
if ($existingContainer -and -not $MongoPassword) {
    $storedMongoPassword = docker inspect $ContainerName --format '{{range .Config.Env}}{{println .}}{{end}}' |
        Where-Object { $_ -like "MONGO_INITDB_ROOT_PASSWORD=*" } |
        Select-Object -First 1
    if ($storedMongoPassword) {
        $MongoPassword = $storedMongoPassword -replace '^MONGO_INITDB_ROOT_PASSWORD=', ''
    }
}

$mongoPasswordWasGenerated = -not $MongoPassword
if ($mongoPasswordWasGenerated) {
    $MongoPassword = New-SecurePassword
}

$existingExpressContainer = docker ps -a --filter "name=^/$ExpressContainerName$" --format "{{.Names}}"
if ($existingExpressContainer -and -not $ExpressPassword) {
    $storedExpressPassword = docker inspect $ExpressContainerName --format '{{range .Config.Env}}{{println .}}{{end}}' |
        Where-Object { $_ -like "ME_CONFIG_BASICAUTH_PASSWORD=*" } |
        Select-Object -First 1
    if ($storedExpressPassword) {
        $ExpressPassword = $storedExpressPassword -replace '^ME_CONFIG_BASICAUTH_PASSWORD=', ''
    }
}

$expressPasswordWasGenerated = -not $ExpressPassword
if ($expressPasswordWasGenerated) {
    $ExpressPassword = New-SecurePassword
}

$hostName = [System.Net.Dns]::GetHostName()
Set-EnvValue -Name "MONGO_ROOT_USERNAME" -Value $MongoUser
Set-EnvValue -Name "MONGO_ROOT_PASSWORD" -Value $MongoPassword
Set-EnvValue -Name "MONGO_EXPRESS_USERNAME" -Value $ExpressUser
Set-EnvValue -Name "MONGO_EXPRESS_PASSWORD" -Value $ExpressPassword
Set-EnvValue -Name "MONGO_PORT" -Value $Port
Set-EnvValue -Name "MONGO_EXPRESS_PORT" -Value $ExpressPort
Set-EnvValue -Name "SERVER_HOSTNAME" -Value $hostName

$existingNetwork = docker network ls --filter "name=^$NetworkName$" --format "{{.Name}}"
if (-not $existingNetwork) {
    docker network create $NetworkName | Out-Null
}

if ($existingContainer) {
    if ($Recreate) {
        docker rm -f $ContainerName | Out-Null
        $existingContainer = $null
    } else {
        docker start $ContainerName | Out-Null
        Write-Host "MongoDB container '$ContainerName' is already configured and has been started."
    }
}

if (-not $existingContainer) {
    docker pull $Image
    docker volume create $VolumeName | Out-Null
    docker run --detach `
        --name $ContainerName `
        --restart unless-stopped `
        --network $NetworkName `
        --publish "0.0.0.0:${Port}:27017" `
        --volume "${VolumeName}:/data/db" `
        --env "MONGO_INITDB_ROOT_USERNAME=$MongoUser" `
        --env "MONGO_INITDB_ROOT_PASSWORD=$MongoPassword" `
        $Image | Out-Null
    Write-Host "MongoDB container '$ContainerName' has been started."
}

if (-not $SkipExpress) {
    $existingExpress = docker ps -a --filter "name=^/$ExpressContainerName$" --format "{{.Names}}"
    if ($existingExpress -and $Recreate) {
        docker rm -f $ExpressContainerName | Out-Null
        $existingExpress = $null
    }

    $mongoNetworks = docker inspect $ContainerName --format '{{json .NetworkSettings.Networks}}'
    if ($mongoNetworks -notmatch ('"' + [regex]::Escape($NetworkName) + '"')) {
        docker network connect $NetworkName $ContainerName | Out-Null
    }

    if ($existingExpress) {
        docker start $ExpressContainerName | Out-Null
    } else {
        docker pull $ExpressImage
        docker run --detach `
            --name $ExpressContainerName `
            --restart unless-stopped `
            --network $NetworkName `
            --publish "0.0.0.0:${ExpressPort}:8081" `
            --env "ME_CONFIG_MONGODB_SERVER=$ContainerName" `
            --env "ME_CONFIG_MONGODB_PORT=27017" `
            --env "ME_CONFIG_MONGODB_ADMINUSERNAME=$MongoUser" `
            --env "ME_CONFIG_MONGODB_ADMINPASSWORD=$MongoPassword" `
            --env "ME_CONFIG_BASICAUTH_USERNAME=$ExpressUser" `
            --env "ME_CONFIG_BASICAUTH_PASSWORD=$ExpressPassword" `
            $ExpressImage | Out-Null
    }
}

try {
    New-NetFirewallRule `
        -DisplayName "MongoDB ($Port)" `
        -Direction Inbound `
        -Action Allow `
        -Protocol TCP `
        -LocalPort $Port `
        -Profile Private `
        -ErrorAction Stop | Out-Null
    if (-not $SkipExpress) {
        New-NetFirewallRule `
            -DisplayName "Mongo Express ($ExpressPort)" `
            -Direction Inbound `
            -Action Allow `
            -Protocol TCP `
            -LocalPort $ExpressPort `
            -Profile Private `
            -ErrorAction Stop | Out-Null
    }
} catch {
    Write-Warning "Could not add all firewall rules. Run this script as Administrator or allow TCP ports $Port and $ExpressPort manually."
}

$addresses = Get-NetIPAddress -AddressFamily IPv4 -PrefixOrigin Dhcp,Manual -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -notlike "169.254.*" -and $_.IPAddress -ne "127.0.0.1" } |
    Select-Object -ExpandProperty IPAddress -Unique

Write-Host ""
Write-Host "MongoDB connection strings:"
Write-Host "  mongodb://${MongoUser}:${MongoPassword}@${hostName}:${Port}/?authSource=admin"
foreach ($address in $addresses) {
    Write-Host "  mongodb://${MongoUser}:${MongoPassword}@${address}:${Port}/?authSource=admin"
}
Write-Host ""
if ($mongoPasswordWasGenerated -and -not $existingContainer) {
    Write-Host "MongoDB username: $MongoUser"
    Write-Host "MongoDB password: $MongoPassword"
} else {
    Write-Host "The existing MongoDB container's credentials were not changed."
}
if (-not $SkipExpress) {
    Write-Host "Mongo Express UI: http://${hostName}:${ExpressPort}"
    foreach ($address in $addresses) {
        Write-Host "Mongo Express UI: http://${address}:${ExpressPort}"
    }
    Write-Host "Mongo Express username: $ExpressUser"
    if ($expressPasswordWasGenerated -and -not $existingExpress) {
        Write-Host "Mongo Express password: $ExpressPassword"
    } else {
        Write-Host "The existing Mongo Express UI password was not changed."
    }
}
Write-Host "Keep these ports limited to your trusted network. HTTPS requires a TLS reverse proxy and DNS in front of the UI."
