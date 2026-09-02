[CmdletBinding()]
param(
    [string]$ContainerName = "mysql",
    [string]$VolumeName = "mysql-data",
    [string]$NetworkName = "mysql-network",
    [string]$Image = "mysql:8.4",
    [string]$AdminerContainerName = "adminer",
    [string]$AdminerImage = "adminer:4.8.1",
    [int]$AdminerPort = 8082,
    [int]$Port = 3306,
    [string]$RootPassword,
    [string]$DatabaseName,
    [string]$DatabaseUser,
    [string]$DatabasePassword,
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
if ($existingContainer -and -not $RootPassword) {
    $storedEnvironment = @(docker inspect $ContainerName --format '{{range .Config.Env}}{{println .}}{{end}}')
    $storedRootPassword = $storedEnvironment | Where-Object { $_ -like "MYSQL_ROOT_PASSWORD=*" } | Select-Object -First 1
    if ($storedRootPassword) { $RootPassword = $storedRootPassword -replace '^MYSQL_ROOT_PASSWORD=', '' }
    if (-not $DatabaseName) {
        $storedDatabase = $storedEnvironment | Where-Object { $_ -like "MYSQL_DATABASE=*" } | Select-Object -First 1
        if ($storedDatabase) { $DatabaseName = $storedDatabase -replace '^MYSQL_DATABASE=', '' }
    }
    if (-not $DatabaseUser) {
        $storedUser = $storedEnvironment | Where-Object { $_ -like "MYSQL_USER=*" } | Select-Object -First 1
        if ($storedUser) { $DatabaseUser = $storedUser -replace '^MYSQL_USER=', '' }
    }
    if (-not $DatabasePassword) {
        $storedPassword = $storedEnvironment | Where-Object { $_ -like "MYSQL_PASSWORD=*" } | Select-Object -First 1
        if ($storedPassword) { $DatabasePassword = $storedPassword -replace '^MYSQL_PASSWORD=', '' }
    }
}

$rootPasswordWasGenerated = -not $RootPassword
if ($rootPasswordWasGenerated) {
    $RootPassword = New-SecurePassword
}

if ($DatabaseUser -and -not $DatabasePassword) {
    $DatabasePassword = New-SecurePassword
}

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
        Write-Host "MySQL container '$ContainerName' is already configured and has been started."
    }
}

if (-not $existingContainer) {
    docker pull $Image
    docker volume create $VolumeName | Out-Null

    $dockerArguments = @(
        "run", "--detach",
        "--name", $ContainerName,
        "--restart", "unless-stopped",
        "--network", $NetworkName,
        "--publish", "0.0.0.0:${Port}:3306",
        "--volume", "${VolumeName}:/var/lib/mysql",
        "--env", "MYSQL_ROOT_PASSWORD=$RootPassword"
    )

    if ($DatabaseName) {
        $dockerArguments += @("--env", "MYSQL_DATABASE=$DatabaseName")
    }
    if ($DatabaseUser) {
        if (-not $DatabaseName) {
            throw "-DatabaseName is required when -DatabaseUser is specified."
        }
        $dockerArguments += @("--env", "MYSQL_USER=$DatabaseUser")
        $dockerArguments += @("--env", "MYSQL_PASSWORD=$DatabasePassword")
    }

    $dockerArguments += $Image
    & docker @dockerArguments | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Could not start the MySQL container."
    }
    Write-Host "MySQL container '$ContainerName' has been started."
}

$hostName = [System.Net.Dns]::GetHostName()
Set-EnvValue -Name "MYSQL_ROOT_PASSWORD" -Value $RootPassword
Set-EnvValue -Name "MYSQL_DATABASE" -Value $DatabaseName
Set-EnvValue -Name "MYSQL_USER" -Value $DatabaseUser
Set-EnvValue -Name "MYSQL_PASSWORD" -Value $DatabasePassword
Set-EnvValue -Name "MYSQL_PORT" -Value $Port
Set-EnvValue -Name "ADMINER_PORT" -Value $AdminerPort
Set-EnvValue -Name "SERVER_HOSTNAME" -Value $hostName

$mysqlNetworks = docker inspect $ContainerName --format '{{json .NetworkSettings.Networks}}'
if ($mysqlNetworks -notmatch ('"' + [regex]::Escape($NetworkName) + '"')) {
    docker network connect $NetworkName $ContainerName | Out-Null
}

$existingAdminer = docker ps -a --filter "name=^/$AdminerContainerName$" --format "{{.Names}}"
if ($existingAdminer -and $Recreate) {
    docker rm -f $AdminerContainerName | Out-Null
    $existingAdminer = $null
}

if ($existingAdminer) {
    docker start $AdminerContainerName | Out-Null
} else {
    docker pull $AdminerImage
    docker run --detach `
        --name $AdminerContainerName `
        --restart unless-stopped `
        --network $NetworkName `
        --publish "0.0.0.0:${AdminerPort}:8080" `
        $AdminerImage | Out-Null
}

try {
    New-NetFirewallRule `
        -DisplayName "MySQL ($Port)" `
        -Direction Inbound `
        -Action Allow `
        -Protocol TCP `
        -LocalPort $Port `
        -Profile Private `
        -ErrorAction Stop | Out-Null
    Write-Host "Windows Firewall rule added for TCP port $Port on the Private profile."
    New-NetFirewallRule `
        -DisplayName "Adminer ($AdminerPort)" `
        -Direction Inbound `
        -Action Allow `
        -Protocol TCP `
        -LocalPort $AdminerPort `
        -Profile Private `
        -ErrorAction Stop | Out-Null
    Write-Host "Windows Firewall rule added for Adminer TCP port $AdminerPort on the Private profile."
} catch {
    Write-Warning "Could not add all firewall rules. Run this script as Administrator or allow TCP ports $Port and $AdminerPort manually."
}

$addresses = Get-NetIPAddress -AddressFamily IPv4 -PrefixOrigin Dhcp,Manual -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -notlike "169.254.*" -and $_.IPAddress -ne "127.0.0.1" } |
    Select-Object -ExpandProperty IPAddress -Unique

Write-Host ""
Write-Host "MySQL Community Server is listening on:"
Write-Host "  $hostName`:$Port"
foreach ($address in $addresses) {
    Write-Host "  ${address}:$Port"
}
Write-Host ""
if ($rootPasswordWasGenerated -and -not $existingContainer) {
    Write-Host "MySQL root username: root"
    Write-Host "MySQL root password: $RootPassword"
} else {
    Write-Host "The existing MySQL container's root password was not changed."
}
if ($DatabaseUser) {
    Write-Host "Application database user: $DatabaseUser"
    Write-Host "Application database: $DatabaseName"
}
Write-Host "Connect with a MySQL client using server '$hostName', port $Port, and the credentials above."
Write-Host "Adminer UI: http://${hostName}:${AdminerPort}"
Write-Host "In Adminer, use server '$ContainerName', username 'root' or the application user, and the corresponding password."
Write-Host "Keep ports $Port and $AdminerPort limited to your trusted network."
