[CmdletBinding()]
param(
    [string]$EnvPath = "$PSScriptRoot\.env",
    [string]$ComposeFile = "$PSScriptRoot\docker-compose.yml",
    [switch]$Recreate
)

$ErrorActionPreference = "Stop"

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw "Docker CLI was not found. Install and start Docker Desktop, then run this script again."
}

docker info *> $null
if ($LASTEXITCODE -ne 0) {
    $dockerDesktop = Get-Process "com.docker.backend" -ErrorAction SilentlyContinue
    if (-not $dockerDesktop) {
        throw "Docker Desktop is not running. Start Docker Desktop and rerun compose-up.ps1."
    }
    throw "Docker is installed but the Docker engine is not responding. Start Docker Desktop and try again."
}

if (-not (Test-Path $EnvPath)) {
    $examplePath = Join-Path $PSScriptRoot ".env.example"
    if (-not (Test-Path $examplePath)) {
        throw "Neither '$EnvPath' nor '$examplePath' exists."
    }
    Copy-Item $examplePath $EnvPath
    Write-Host "Created $EnvPath from .env.example."
}

function Get-EnvValues {
    param([string]$Path)
    $values = @{}
    foreach ($line in Get-Content $Path) {
        if ($line -match '^\s*([^#\s=]+)\s*=\s*(.*)\s*$') {
            $values[$matches[1]] = $matches[2]
        }
    }
    return $values
}

function Set-EnvValue {
    param([string]$Name, [string]$Value)
    $script:envValues[$Name] = $Value
    $escapedName = [regex]::Escape($Name)
    $found = $false
    $script:envLines = @($script:envLines | ForEach-Object {
        if ($_ -match "^$escapedName=") {
            $found = $true
            "$Name=$Value"
        } else {
            $_
        }
    })
    if (-not $found) { $script:envLines += "$Name=$Value" }
}

function New-SecurePassword {
    $bytes = New-Object byte[] 24
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    return [Convert]::ToBase64String($bytes).TrimEnd("=").Replace("+", "-").Replace("/", "_")
}

function Ensure-OpenSsl {
    $candidatePaths = @(
        "C:\Program Files\Git\usr\bin\openssl.exe",
        "C:\Program Files (x86)\Git\usr\bin\openssl.exe",
        "C:\Program Files\Git\bin\openssl.exe",
        "C:\Program Files (x86)\Git\bin\openssl.exe"
    )

    foreach ($candidate in $candidatePaths) {
        if (Test-Path $candidate) {
            $env:PATH = [System.IO.Path]::GetDirectoryName($candidate) + ";" + $env:PATH
            return
        }
    }

    $openssl = Get-Command openssl -ErrorAction SilentlyContinue
    if ($openssl) {
        return
    }

    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if ($winget) {
        $git = Get-Command git -ErrorAction SilentlyContinue
        if (-not $git) {
            Write-Host "OpenSSL not found. Installing Git for Windows (which bundles OpenSSL)..."
            & winget install --id Git.Git --accept-source-agreements --accept-package-agreements --exact -e
            if ($LASTEXITCODE -eq 0) {
                foreach ($candidate in $candidatePaths) {
                    if (Test-Path $candidate) {
                        $env:PATH = [System.IO.Path]::GetDirectoryName($candidate) + ";" + $env:PATH
                        return
                    }
                }
            }
        }

        Write-Host "OpenSSL not found. Installing via winget..."
        & winget install --id ShiningLight.OpenSSL --accept-source-agreements --accept-package-agreements --exact -e
        if ($LASTEXITCODE -eq 0) {
            $openssl = Get-Command openssl -ErrorAction SilentlyContinue
            if ($openssl) { return }
        }
    }

    $choco = Get-Command choco -ErrorAction SilentlyContinue
    if ($choco) {
        Write-Host "OpenSSL not found. Installing via Chocolatey..."
        & choco install openssl -y
        if ($LASTEXITCODE -eq 0) {
            $openssl = Get-Command openssl -ErrorAction SilentlyContinue
            if ($openssl) { return }
        }
    }

    throw "OpenSSL is required to export the local Swarm certificate. The script attempted to install it and also checked for Git for Windows' bundled OpenSSL, but it is still unavailable. Install Git for Windows or OpenSSL and rerun compose-up.ps1."
}

function Ensure-SwarmCertificate {
    param([string]$HostName)

    $certDirectory = Join-Path $PSScriptRoot "certs"
    New-Item -ItemType Directory -Path $certDirectory -Force | Out-Null

    $certPath = Join-Path $certDirectory "ssl-cert-snakeoil.pem"
    $keyPath = Join-Path $certDirectory "ssl-cert-snakeoil.key"

    if ((Test-Path $certPath) -and (Test-Path $keyPath)) {
        return
    }

    $cert = New-SelfSignedCertificate `
        -CertStoreLocation "Cert:\CurrentUser\My" `
        -FriendlyName "Smol Bootstrap Local" `
        -DnsName @(
            "localhost",
            "127.0.0.1",
            $HostName,
            "$HostName.swarm.com",
            "$HostName.mongodb.com",
            "$HostName.redis.com",
            "$HostName.mysql.com"
        )

    $certBytes = $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)
    $certPem = "-----BEGIN CERTIFICATE-----`n" + [System.Convert]::ToBase64String($certBytes, [System.Base64FormattingOptions]::InsertLineBreaks) + "`n-----END CERTIFICATE-----`n"
    Set-Content -Path $certPath -Value $certPem -Encoding ascii

    $privateKeyPem = $null
    $rsaPrivateKeyMethod = $cert.PSObject.Methods.Name -contains "GetRSAPrivateKey"
    if ($rsaPrivateKeyMethod) {
        try {
            $rsaKey = $cert.GetRSAPrivateKey()
            if ($null -ne $rsaKey) {
                $keyBytes = $rsaKey.ExportPkcs8PrivateKey()
                $privateKeyPem = "-----BEGIN PRIVATE KEY-----`n" + [System.Convert]::ToBase64String($keyBytes, [System.Base64FormattingOptions]::InsertLineBreaks) + "`n-----END PRIVATE KEY-----`n"
            }
        } catch {}
    }

    if (-not $privateKeyPem) {
        Ensure-OpenSsl
        $openssl = Get-Command openssl -ErrorAction SilentlyContinue
        if (-not $openssl) {
            throw "OpenSSL is still unavailable after installation. Install Git for Windows or OpenSSL, then rerun compose-up.ps1."
        }

        $configPath = Join-Path $certDirectory "openssl-san.cnf"
        @(
            "[ req ]",
            "distinguished_name = dn",
            "x509_extensions = v3_req",
            "prompt = no",
            "",
            "[ dn ]",
            "CN = localhost",
            "",
            "[ v3_req ]",
            "subjectAltName = @alt_names",
            "extendedKeyUsage = serverAuth",
            "",
            "[ alt_names ]",
            "DNS.1 = localhost",
            "IP.1 = 127.0.0.1",
            "DNS.2 = ${HostName}",
            "DNS.3 = ${HostName}.swarm.com",
            "DNS.4 = ${HostName}.mongodb.com",
            "DNS.5 = ${HostName}.redis.com",
            "DNS.6 = ${HostName}.mysql.com"
        ) | Set-Content -Path $configPath -Encoding ascii

        & $openssl req -x509 -newkey rsa:2048 -sha256 -nodes `
            -keyout $keyPath `
            -out $certPath `
            -days 365 `
            -config $configPath `
            -extensions v3_req `
            -subj "/CN=localhost"
        if ($LASTEXITCODE -ne 0) {
            throw "OpenSSL could not generate the local Swarm certificate."
        }

        Remove-Item -Path $configPath -Force -ErrorAction SilentlyContinue
    } else {
        Set-Content -Path $keyPath -Value $privateKeyPem -Encoding ascii
    }

    Write-Host "Local SSL certificate created."
    $cert | Remove-Item -Force -ErrorAction SilentlyContinue
}

$script:envLines = @(Get-Content $EnvPath)
$script:envValues = Get-EnvValues -Path $EnvPath

$hostname = [System.Net.Dns]::GetHostName()
if (-not $envValues["SERVER_HOSTNAME"] -or $envValues["SERVER_HOSTNAME"] -like "YOUR-*") {
    Set-EnvValue -Name "SERVER_HOSTNAME" -Value $hostname
}

$generated = @()
$credentials = @{
    "MONGO_ROOT_PASSWORD" = "MongoDB root password"
    "MONGO_EXPRESS_PASSWORD" = "Mongo Express password"
    "REDIS_PASSWORD" = "Redis password"
    "MYSQL_ROOT_PASSWORD" = "MySQL root password"
    "MYSQL_PASSWORD" = "MySQL application password"
}
foreach ($entry in $credentials.GetEnumerator()) {
    $value = $envValues[$entry.Key]
    if (-not $value -or $value -like "change-this-*") {
        $newValue = New-SecurePassword
        Set-EnvValue -Name $entry.Key -Value $newValue
        $generated += "$($entry.Value): $newValue"
    }
}

$requiredP4Values = @("P4D_PORT", "P4D_SUPER", "P4D_SUPER_PASSWD", "SWARM_PASSWD")
foreach ($name in $requiredP4Values) {
    $value = $envValues[$name]
    if (-not $value -or $value -like "change-this-*" -or $value -like "your-*-password") {
        throw "Set a real $name value in '$EnvPath' before starting the Compose Swarm service."
    }
}
if (-not $envValues["SWARM_HOST"] -or $envValues["SWARM_HOST"] -like "YOUR-*") {
    Set-EnvValue -Name "SWARM_HOST" -Value "$hostname.swarm.com"
}

Ensure-SwarmCertificate -HostName $hostname

$cleanupContainers = @("nginx-reverse-proxy", "mongo-express", "mongodb", "redis", "redisinsight", "adminer", "mysql", "helix-swarm")
foreach ($containerName in $cleanupContainers) {
    try {
        docker rm -f $containerName *> $null
    } catch {
        # ignore missing containers
    }
}

$cleanupVolumes = @("mongodb-data", "redis-data", "redisinsight-data", "mysql-data", "swarm-data")
foreach ($volumeName in $cleanupVolumes) {
    try {
        docker volume rm $volumeName *> $null
    } catch {
        # ignore missing volumes
    }
}

try {
    & docker compose --env-file $EnvPath -f $ComposeFile down --remove-orphans *> $null
} catch {
    # ignore if the compose project has not been started yet
}

Set-Content -Path $EnvPath -Value $script:envLines -Encoding ascii

Write-Host ""
if ($generated.Count -gt 0) {
    Write-Host "Generated and saved credentials in ${EnvPath}:"
    $generated | ForEach-Object { Write-Host "  $_" }
} else {
    Write-Host "Existing credentials in $EnvPath were preserved."
}
Write-Host ""
Write-Host "Starting the Compose stack..."
$composeArguments = @("compose", "--env-file", $EnvPath, "-f", $ComposeFile, "up", "-d")
if ($Recreate) { $composeArguments += "--force-recreate" }
& docker @composeArguments
if ($LASTEXITCODE -ne 0) {
    throw "Docker Compose failed to start the stack."
}

Write-Host ""
Write-Host "Compose stack is running. Use 'docker compose ps' to inspect it."
Write-Host "Credentials are stored in: $EnvPath"
