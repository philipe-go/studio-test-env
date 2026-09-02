# Docker Services

These PowerShell scripts run MongoDB, MySQL, Redis, browser-based database UIs, an Nginx reverse proxy, and a host-native Perforce Helix Core server on Windows.

## General Instructions

### Recommended: Start Everything with Docker Compose

1. Install and start Docker Desktop.
2. Open PowerShell in this directory.
3. Create the shared environment file and replace every example password:

```powershell
Copy-Item .env.example .env
notepad .env
```

4. Set `SERVER_HOSTNAME` to the Windows hostname of the Docker machine. If using host-native Perforce, keep `P4D_PORT=host.docker.internal:1666` so the Swarm container can reach it.
5. Start all Docker services. This wrapper creates missing database/UI passwords, writes them to `.env`, and then runs Docker Compose:

```powershell
.\compose-up.ps1
docker compose ps
```

Do not use `docker compose up -d` as the first command when `.env` does not contain credentials. Docker Compose reads `.env` but cannot generate or write passwords back to it. After `.env` has been initialized, direct Compose commands are also available.

This starts [MongoDB and Mongo Express](#mongodb), [Redis and RedisInsight](#redis), [MySQL and Adminer](#mysql-community-server), [P4 Code Review](#p4-code-review-container-standalone), and [Nginx](#nginx-reverse-proxy). The host-native [Perforce Helix Core server](#perforce-helix-core-server-host-native) is separate and must already be running when Swarm starts.

### Alternative: Run Individual Bootstrap Scripts

The individual scripts write their effective users, passwords, ports, hostnames, and service settings to the shared `.env` file. Run them in this order when not using Compose:

```powershell
.\perforce-install.ps1   # Optional host-native P4 Server
.\mongodb-docker.ps1
.\redis-docker.ps1
.\mysql-docker.ps1
.\swarm-docker.ps1
.\nginx-docker.ps1
```

The scripts preserve unrelated `.env` entries. Treat `.env` and `swarm\.env` as secrets because they contain passwords.

### Friendly URLs, DNS, Hosts File, and Nginx

Nginx routes browser UIs by hostname:

```text
http://smol.mongodb.com   -> Mongo Express
http://smol.redis.com     -> RedisInsight
http://smol.mysql.com     -> Adminer
http://smol.swarm.com     -> P4 Code Review
```

Nginx does not create DNS records. On every client machine, edit `C:\Windows\System32\drivers\etc\hosts` as Administrator and map the names to the Docker host's LAN IP:

```text
192.168.1.50 smol.mongodb.com
192.168.1.50 smol.redis.com
192.168.1.50 smol.mysql.com
192.168.1.50 smol.swarm.com
```

Replace `192.168.1.50` with the server's LAN IP, then apply and test the mappings:

```powershell
ipconfig /flushdns
Resolve-DnsName smol.mongodb.com
Resolve-DnsName smol.redis.com
Resolve-DnsName smol.mysql.com
Resolve-DnsName smol.swarm.com
```

The editable Compose Nginx template is [nginx-compose.conf.template](nginx-compose.conf.template). After changing it, reload Nginx:

```powershell
docker compose up -d --force-recreate nginx
```

For larger networks, create equivalent DNS records instead of editing each hosts file. The `.com` names above are local names in this setup; they do not require public DNS when hosts-file or private DNS records are used.

## Compose Stack

The Docker services can be started together with `docker-compose.yml`. This stack includes MongoDB, Mongo Express, Redis, RedisInsight, MySQL, Adminer, and Nginx.

Create the environment file and set the machine hostname and passwords:

```powershell
cd C:\Users\lipin\Documents\Programming\Smol-Bootstrap
Copy-Item .env.example .env
notepad .env
```

Start all Docker services and generate missing credentials:

```powershell
.\compose-up.ps1
```

Stop the stack without deleting data:

```powershell
docker compose down
```

View status and logs:

```powershell
docker compose ps
docker compose logs -f nginx
```

The Compose file uses named volumes for database data. Do not use `docker compose down -v` unless you intentionally want to delete all MongoDB, Redis, and MySQL data.

### Friendly URLs

Nginx routes the browser UIs to these URLs:


The Nginx template is [nginx-compose.conf.template](nginx-compose.conf.template). Edit it to add or change HTTP routes, then apply the configuration:

```powershell
docker compose up -d --force-recreate nginx
```

`SERVER_HOSTNAME` is substituted into the template when the Nginx container starts. The generated configuration exists inside the container at `/etc/nginx/conf.d/default.conf`.

### DNS or Hosts File

Nginx routes requests based on the hostname, but it cannot create DNS records. A client machine must translate each friendly hostname to the LAN IP of the machine running Docker. For a small Windows network, apply the mapping on every client machine that will use these URLs.

1. Find the Docker host's LAN IPv4 address with `ipconfig` (for example, `192.168.1.50`).
2. Find the value of `SERVER_HOSTNAME` in the server's `.env` file (for example, `MYPC`).
3. On each Windows client, open Notepad as Administrator and open `C:\Windows\System32\drivers\etc\hosts`.
4. Add these lines, replacing the example IP and hostname:

```text
192.168.1.50 <server-hostname>.mongodb.com
192.168.1.50 <server-hostname>.redis.com
192.168.1.50 <server-hostname>.mysql.com
192.168.1.50 <server-hostname>.swarm.com
```

Save the file, then clear the client DNS cache and test the mappings:

```powershell
ipconfig /flushdns
Resolve-DnsName <server-hostname>.mongodb.com
Resolve-DnsName <server-hostname>.redis.com
Resolve-DnsName <server-hostname>.mysql.com
Resolve-DnsName <server-hostname>.swarm.com
```

The result should show `192.168.1.50` for each name. Then open the friendly URLs in a browser. For a larger network, create equivalent DNS records in the network DNS server instead of editing every hosts file.

The Compose file publishes only Nginx's HTTP port `80` for the UIs. Database ports `27017`, `6379`, and `3306` remain published for native clients; restrict them with Windows Firewall if they should not be reachable from the LAN. HTTPS requires a TLS certificate and additional Nginx `listen 443 ssl` configuration.

The Compose stack and the individual `*-docker.ps1` scripts use the same container names and host ports. Use one workflow or the other, not both at the same time. The host-native `perforce-install.ps1` is independent; `perforce-docker.ps1` remains a separate alternative and is not included in this Compose stack.

### P4 Code Review in Compose

The Compose `swarm` service uses the official `perforce/helix-swarm:latest` image and persists its configuration and data in the `swarm-data` volume. It requires access to a running P4 Server and Redis. The default `.env.example` assumes the P4 Server is the host-native server from `perforce-install.ps1`, reachable from Docker as `host.docker.internal:1666`.

Set these values in `.env` before starting the stack:

```text
P4D_PORT=host.docker.internal:1666
P4D_SUPER=super
P4D_SUPER_PASSWD=your-p4-super-password
SWARM_USER=swarm
SWARM_PASSWD=your-swarm-password
SWARM_HOST=YOUR-WINDOWS-HOSTNAME.swarm.com
```

The P4 superuser must have super privileges, and the Swarm user must be valid or be created during initial configuration. The Swarm container stores its resulting configuration under `/opt/perforce/swarm/data`; do not delete `swarm-data` unless you intend to remove the Swarm configuration.

The Compose URL is `http://<SERVER_HOSTNAME>.swarm.com`. The Swarm container is not exposed directly on a host port; Nginx routes to it internally.

## P4 Code Review Container (Standalone)

Script: `swarm-docker.ps1`

This script starts the same official P4 Code Review image outside the full Compose stack. It requires an existing Redis container and a reachable P4 Server.

```powershell
.\swarm-docker.ps1 `
    -P4Super super `
    -P4SuperPassword 'your-p4-super-password' `
    -SwarmPassword 'your-swarm-password' `
    -RedisPassword 'your-redis-password'
```

By default, it connects to the host-native P4 Server at `host.docker.internal:1666`, uses Redis container `redis` on `redis-network`, publishes Swarm on port `8083`, and persists data in the Docker volume `swarm-data`. Open `http://<hostname>.swarm.com` after configuring the standalone Nginx script, or use `http://<server-ip>:8083` directly.

Useful options:

```powershell
# Use a different P4 Server address or UI port
.\swarm-docker.ps1 -P4DPort 'p4server:1666' -Port 8084

# Recreate the container while preserving the swarm-data volume
.\swarm-docker.ps1 -Recreate
```

The generated Swarm environment file is stored at `swarm\.env`. It contains passwords and should be protected. The official Perforce setup flow uses this file for initial configuration and then stores the resulting configuration in the mounted Swarm data directory.

## Prerequisites

- Docker Desktop installed and running
- PowerShell
- Run the scripts from an elevated PowerShell terminal when Windows Firewall rules should be created
- The server machine and client machines must be on the same trusted network

Run the services in this order:

```powershell
cd <directory>/env-bootstrap
Copy-Item .env.example .env
notepad .env
.\compose-up.ps1
```

Alternatively, start the services individually with the bootstrap scripts:

```powershell
cd C:\Users\lipin\Documents\Programming\Smol-Bootstrap
.\mongodb-docker.ps1
.\redis-docker.ps1
.\nginx-docker.ps1
```

Passwords are generated automatically when they are not provided. Save the credentials printed by the scripts.

## MySQL Community Server

Script: `mysql-docker.ps1`

Downloads and starts the official MySQL Community Server Docker image with persistent storage and Adminer, a browser-based MySQL administration UI.

```powershell
cd C:\Users\lipin\Documents\Programming\Smol-Bootstrap
.\mysql-docker.ps1
```

Default settings:

- MySQL endpoint: `<server-hostname>:3306`
- Adminer UI: `http://<server-hostname>:8082`
- Docker container: `mysql`
- Adminer container: `adminer`
- Docker network: `mysql-network`
- Data volume: `mysql-data`
- Image: `mysql:8.4`
- Adminer image: `adminer:4.8.1`
- Root username: `root`

The script generates a root password if one is not supplied. Save the password printed at the end of the run.

Useful options:

```powershell
# Use an explicit root password
.\mysql-docker.ps1 -RootPassword 'change-this-password'

# Create an application database and user on first initialization
.\mysql-docker.ps1 -DatabaseName appdb -DatabaseUser appuser -DatabasePassword 'change-this-user-password'

# Recreate the container while keeping the named data volume
.\mysql-docker.ps1 -Recreate

# Use a different port or persistent data volume
.\mysql-docker.ps1 -Port 3307 -VolumeName mysql-production-data

# Use a different Adminer port
.\mysql-docker.ps1 -AdminerPort 8083
```

Connect from another machine with a MySQL client using the server's LAN IP or hostname, port `3306`, and the printed credentials. The Windows Firewall rule allows TCP `3306` on the Private profile. Keep this port restricted to the trusted network.

Open Adminer at `http://<server-hostname>:8082` from another machine. Log in with:

- System: `MySQL`
- Server: `mysql`
- Username: `root` or the application user
- Password: the corresponding password printed by the script
- Database: the initialized database name, if one was supplied

Adminer is connected to MySQL through the Docker network, so the server name inside Adminer is `mysql`, not the host machine's name or IP. The Windows Firewall rule also allows TCP `8082` on the Private profile.

MySQL initialization variables are applied only when the data volume is empty. Re-running with different passwords, database names, or users does not modify an existing database. Use SQL or a MySQL administration tool to change an existing installation.

## Perforce Helix Core Server (Host-Native)

Script: `perforce-install.ps1`

Downloads the Perforce `p4d.exe` server directly to the Windows host and executes it in the current PowerShell session. This does not use Docker or create a Windows service.

Run PowerShell as Administrator when using the default `C:\Program Files` install directory:

```powershell
cd C:\Users\lipin\Documents\Programming\Smol-Bootstrap
.\perforce-install.ps1
```

Default settings:

- Perforce endpoint: `P4PORT=<server-hostname>:1666`
- Executable: `C:\Program Files\Perforce\p4d.exe`
- Server root and depot metadata: `C:\ProgramData\Perforce\root`
- Server log and journal files: `C:\ProgramData\Perforce\logs`
- Windows Firewall rule: TCP `1666` on the Private profile

Useful options:

```powershell
# Download a specific p4d build or use a different official download URL
.\perforce-install.ps1 -DownloadUrl 'https://ftp.perforce.com/perforce/r25.1/bin.ntx64/p4d.exe'

# Re-download p4d and execute the new binary while keeping server data
.\perforce-install.ps1 -ReDownload

# Use a custom port and data location
.\perforce-install.ps1 -Port 1667 -ServerRoot 'D:\Perforce\root' -LogDirectory 'D:\Perforce\logs'
```

The script remains attached while `p4d.exe` is running. Press `Ctrl+C` to stop the server. To run it in the background, start it from a separate process or configure Windows Task Scheduler yourself; this script deliberately does not install or manage a Windows service.

View the server log from another PowerShell window:

```powershell
Get-Content C:\ProgramData\Perforce\logs\server.log -Tail 50
```

Connect from another machine with a Perforce client using `P4PORT=<server-ip>:1666` or a DNS name that resolves to the server. Perforce uses native TCP, not HTTP/HTTPS. For a friendly name, add a DNS record or a hosts-file entry such as:

```text
192.168.1.50 SERVERNAME.p4
```

Do not run `perforce-docker.ps1` at the same time on the same host and port. The native installer and container workflow are alternatives; stop or remove one before starting the other.

## MongoDB

Script: `mongodb-docker.ps1`

Starts MongoDB with persistent storage and Mongo Express, a web UI for inspecting MongoDB.

```powershell
.\mongodb-docker.ps1
```

Default endpoints:

- MongoDB: `mongodb://admin:<password>@<server-hostname>:27017/?authSource=admin`
- Mongo Express: `http://<server-hostname>:8081`
- Docker container: `mongodb`
- Docker network: `mongodb-network`
- Data volume: `mongodb-data`

Useful options:

```powershell
# Use explicit credentials
.\mongodb-docker.ps1 -MongoUser admin -MongoPassword 'change-this-password' -ExpressPassword 'change-this-ui-password'

# Recreate containers while keeping the named data volume
.\mongodb-docker.ps1 -Recreate

# Start MongoDB without Mongo Express
.\mongodb-docker.ps1 -SkipExpress
```

MongoDB initialization credentials are only applied when the data volume is first created. Re-running with a different password does not change an existing database user's password.

## Redis

Script: `redis-docker.ps1`

Starts Redis with AOF persistence and RedisInsight, a web UI for inspecting Redis.

```powershell
.\redis-docker.ps1
```

Default endpoints:

- Redis: `redis://:<password>@<server-hostname>:6379`
- RedisInsight: `http://<server-hostname>:5540`
- Docker container: `redis`
- Docker network: `redis-network`
- Data volumes: `redis-data` and `redisinsight-data`

Useful options:

```powershell
# Use an explicit Redis password
.\redis-docker.ps1 -Password 'change-this-password'

# Recreate containers while keeping named data volumes
.\redis-docker.ps1 -Recreate

# Start Redis without RedisInsight
.\redis-docker.ps1 -SkipInsight
```

In RedisInsight, add a database using host `redis`, port `6379`, and the Redis password printed by the script. The host `redis` works inside the Docker network; from another machine use the server hostname or IP.

## Nginx Reverse Proxy

Script: `nginx-docker.ps1`

Starts Nginx and routes friendly hostnames to the two browser UIs:

- `http://<server-hostname>.mongodb` -> Mongo Express on port `8081`
- `http://<server-hostname>.redis` -> RedisInsight on port `5540`

Start it after both database scripts:

```powershell
.\nginx-docker.ps1
```

The Nginx container is named `nginx-reverse-proxy` and listens on port `80`.

### Nginx Configuration

The editable configuration is generated here:

```text
C:\Users\lipin\Documents\Programming\Smol-Bootstrap\nginx\nginx.conf
```

To add another service, add another `server` block. For example:

```nginx
server {
    listen 80;
    server_name <server-hostname>.example;

    location / {
        proxy_pass http://some-container:3000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

After editing the file, recreate Nginx so the container mounts and loads the current configuration:

```powershell
.\nginx-docker.ps1 -Recreate
```

The script rewrites `nginx\nginx.conf` each time it runs. Keep custom changes backed up or update the script's `$config` template if they should persist.

### Name Resolution for the Standalone Nginx Script

Nginx handles HTTP routing, but it does not create DNS records. Every client machine must resolve the friendly names to the server's LAN IP address.

For a small network, add these lines to the client machine's hosts file, replacing `192.168.1.50` with the server's IP and `SERVERNAME` with the server hostname:

```text
192.168.1.50 smol.mongodb.com
192.168.1.50 smol.redis.com
```

On Windows, edit this file as Administrator:

```text
C:\Windows\System32\drivers\etc\hosts
```

For a larger network, create DNS records instead. Then use:

```text
http://smol.mongodb.com
http://smol.redis.com
```

These endpoints use HTTP. HTTPS requires a trusted TLS certificate, DNS records, and additional Nginx `listen 443 ssl` configuration.

## Troubleshooting

```powershell
# Check all containers
 docker ps -a

# View service logs
 docker logs mongodb
 docker logs mongo-express
 docker logs redis
 docker logs redisinsight
 docker logs nginx-reverse-proxy

# Check Nginx configuration inside the container
 docker exec nginx-reverse-proxy nginx -t
```

If a script reports that Docker is not running, start Docker Desktop first. If a client cannot connect, verify the Windows Firewall rule, the server's LAN IP, and the client's DNS or hosts-file entries.
