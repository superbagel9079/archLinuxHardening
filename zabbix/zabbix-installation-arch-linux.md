# Zabbix Server Deployment on Arch Linux (Apache/PHP-FPM/MariaDB)

## Part I - System Preparation & Installation

We begin by installing the core components. Arch Linux splits the Zabbix stack into the server, the frontend, and the agent.

```bash
# Update the system first
sudo pacman -Syu

# Install Zabbix components, Database, Web Server, and PHP tools
sudo pacman -S zabbix-server zabbix-frontend-php zabbix-agent apache mariadb php php-fpm php-gd fping
```

>[!NOTE] 
>Package Roles Explained:
>
| Package               | Purpose                                                                    |
| --------------------- | -------------------------------------------------------------------------- |
| `zabbix-server`       | The core monitoring daemon that processes checks, triggers, and alerts     |
| `zabbix-frontend-php` | The PHP-based web interface served by Apache                               |
| `zabbix-agent`        | The local agent allowing the Zabbix server to monitor itself               |
| `apache`              | The HTTP server (called `httpd` in its service unit)                       |
| `mariadb`             | The relational database storing all configuration, history, and trend data |
| `php` / `php-fpm`     | The PHP interpreter and FastCGI process manager                            |
| `php-gd`              | Image rendering library required for Zabbix graphs                         |
| `fping`               | ICMP ping utility used by Zabbix for host availability checks              |

### B - Granting `fping` the Correct Capabilities

Zabbix uses `fping` for all ICMP-based checks (Simple Checks, host availability). `fping` requires raw socket access, which is a privileged operation. Without this step, **every ICMP check will fail silently**.

```bash
sudo setcap cap_net_raw+ep /usr/bin/fping
```

> [!NOTE] 
> This uses POSIX capabilities rather than the legacy `setuid root` approach. It grants only the `CAP_NET_RAW` capability — the minimum privilege required — rather than full root access. This is the modern, least-privilege method. Reference: `capabilities(7)` man page.

Verify:

```bash
getcap /usr/bin/fping
```

Expected output:

```
/usr/bin/fping cap_net_raw=ep
```

## Part II - Database Configuration (MariaDB)

### A - Initialization and Securing

MariaDB ships without a data directory on Arch. We must initialize it before the service can start.

```bash
sudo mariadb-install-db --user=mysql --basedir=/usr --datadir=/var/lib/mysql
```

Start and enable the service:

```bash
sudo systemctl enable --now mariadb
```

Run the hardening script. This removes anonymous users, disables remote root login, and drops the test database.

```bash
sudo mariadb-secure-installation
```

When prompted:

| Prompt                                | Recommended Response | Reason                                                                                  |
| ------------------------------------- | -------------------- | --------------------------------------------------------------------------------------- |
| Switch to unix_socket authentication? | `n`                  | Password authentication is sufficient for local service accounts                        |
| Change the root password?             | `Y`                  | Set a strong password — the Zabbix installer will need it to create the database schema |
| Remove anonymous users?               | `Y`                  | Prevents unauthenticated database access                                                |
| Disallow root login remotely?         | `Y`                  | Root should only connect from localhost                                                 |
| Remove test database?                 | `Y`                  | Eliminates an unnecessary attack surface                                                |
| Reload privilege tables now?          | `Y`                  | Applies all changes immediately                                                         |
### B - Production Tuning and Character Set

Zabbix **requires** the `utf8mb4` character set with `utf8mb4_bin` collation. This is not optional — the schema import will fail or produce corrupted data without it.

Create a dedicated configuration drop-in file. Do not edit the main `my.cnf` — Arch's package manager may overwrite it on update.

Create and edit `/etc/my.cnf.d/zabbix.cnf`:

```ini
[mysqld]

# --- Character Set ---
character-set-server  = utf8mb4
collation-server      = utf8mb4_bin

# --- InnoDB Tuning ---
# The buffer pool is the single most impactful MariaDB setting.
# Set this to 60-70% of the RAM *dedicated to MariaDB*.
# Example: On a server with 8 GB total RAM, 5 GB is appropriate.
# On a server with 4 GB total RAM, use 2G.
# On a server with 16 GB total RAM, use 10G.
# THERE IS NO UNIVERSAL DEFAULT. Measure your system.
innodb_buffer_pool_size = 2G

# Log file size controls crash recovery speed vs. write performance.
# 128M is a reasonable starting point for most workloads.
innodb_log_file_size    = 128M

# Store each InnoDB table in its own file. This improves manageability
# and allows space to be reclaimed when tables are dropped or truncated.
innodb_file_per_table   = 1

# --- Connection Limits ---
# Zabbix server opens (DBStartPollers + other internal processes) connections.
# 100 is adequate for a small-to-medium deployment.
max_connections = 100
```

>[!WARNING] 
**You must calculate `innodb_buffer_pool_size` for your specific hardware.** If this value exceeds your available physical RAM, MariaDB will either fail to start or force the kernel's OOM killer to terminate it. Check your available memory with `free -h` before setting this value.

Restart MariaDB to apply changes:

```bash
sudo systemctl restart mariadb
```

### C - Database and User Creation

Connect to MariaDB:

```bash
mariadb -u root -p
```

Execute the following. Replace `YOUR_SECURE_PASSWORD` with a strong, unique password.

```sql
CREATE DATABASE zabbix CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;
CREATE USER 'zabbix'@'localhost' IDENTIFIED BY 'YOUR_SECURE_PASSWORD';
GRANT ALL PRIVILEGES ON zabbix.* TO 'zabbix'@'localhost';
FLUSH PRIVILEGES;
EXIT;
```

> [!TIP]
> Generate a strong password with: `openssl rand -base64 32`

### D - Schema Import

The Zabbix package on Arch ships SQL files under `/usr/share/zabbix-server/mysql/`. Depending on the package version, this may be either three separate files or a single consolidated file. Check what exists:

```bash
ls /usr/share/zabbix-server/mysql/
```

**If you see `schema.sql`, `images.sql`, and `data.sql`** (legacy layout), import them in this exact order — order matters because of foreign key dependencies:

```bash
mariadb -u zabbix -p -D zabbix < /usr/share/zabbix-server/mysql/schema.sql
mariadb -u zabbix -p -D zabbix < /usr/share/zabbix-server/mysql/images.sql
mariadb -u zabbix -p -D zabbix < /usr/share/zabbix-server/mysql/data.sql
```

**If you see `create.sql.gz`** (modern layout), import with:

```bash
zcat /usr/share/zabbix-server/mysql/create.sql.gz | mariadb -u zabbix -p -D zabbix
```

> [!NOTE] 
> This import can take several minutes depending on disk speed. Do not interrupt it. A partial import will leave the database in an inconsistent state requiring a `DROP DATABASE` and reimport.

## Part III - PHP and PHP-FPM Configuration

### A - PHP Extensions and Settings

Edit `/etc/php/php.ini`. The following changes are required — Zabbix's frontend installer will refuse to proceed if these are not met.

**Extensions to uncomment** (remove the leading `;`):

```ini
extension=bcmath
extension=gd
extension=gettext
extension=mysqli
extension=sockets
```

> [!NOTE] 
> If you plan to use LDAP authentication against Active Directory or another directory, also uncomment:
> ```ini
> extension=ldap
> ```
> 

**Resource limits to adjust** — find each directive and modify its value:

```ini
post_max_size      = 16M
max_execution_time = 300
max_input_time     = 300
memory_limit       = 512M
```

|Directive|Default|Required|Reason|
|---|---|---|---|
|`post_max_size`|8M|16M|Allows importing larger XML configuration templates|
|`max_execution_time`|30|300|Complex dashboard renders and API calls need more time|
|`max_input_time`|60|300|Large form submissions (mass updates) require extended input parsing|
|`memory_limit`|128M|512M|Zabbix frontend operations (especially map rendering) are memory-intensive|

**Timezone** - this is critical. Zabbix correlates events and renders graphs using PHP's timezone. A mismatch between this and the system clock will produce confusing graph offsets.

```ini
date.timezone = "UTC"
```

Replace `UTC` with your actual timezone. The list of valid values is at [php.net/manual/en/timezones.php](https://www.php.net/manual/en/timezones.php).

### B - PHP-FPM Pool Configuration

Edit `/etc/php/php-fpm.d/www.conf`. The critical settings are the socket path and its ownership. Apache runs as the `http` user on Arch, so PHP-FPM's socket must be readable and writable by that user.

```ini
listen = /run/php-fpm/php-fpm.sock
listen.owner = http
listen.group = http
listen.mode  = 0660
```

The default process manager settings in Arch's `www.conf` are:

```ini
pm = dynamic
pm.max_children = 5
pm.start_servers = 2
pm.min_spare_servers = 1
pm.max_spare_servers = 3
```

> [!TIP] 
> These defaults are adequate for a single-administrator setup. If multiple users will have dashboards open simultaneously or if you use the Zabbix API heavily, increase `pm.max_children` to `10` or `15` and scale the spare server values proportionally. Each PHP-FPM child consumes roughly 30-60 MB of RAM when serving Zabbix pages.

### C - Start PHP-FPM

```bash
sudo systemctl enable --now php-fpm
```

Verify the socket was created:

```bash
ls -la /run/php-fpm/php-fpm.sock
```

You should see ownership as `http:http` with `0660` permissions.

## Part IV - Apache Configuration

### A - Enable Required Modules

Edit `/etc/httpd/conf/httpd.conf`. Find and **uncomment** the following lines (remove the leading `#`):

```apache
LoadModule proxy_module modules/mod_proxy.so
LoadModule proxy_fcgi_module modules/mod_proxy_fcgi.so
LoadModule remoteip_module modules/mod_remoteip.so
LoadModule rewrite_module modules/mod_rewrite.so
```

| Module                         | Purpose                                                                                                                              |
| ------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------ |
| `mod_proxy` + `mod_proxy_fcgi` | Required to forward `.php` requests to PHP-FPM over the Unix socket                                                                  |
| `mod_remoteip`                 | Replaces the client IP in logs and `$_SERVER` with the real IP from `X-Forwarded-For`, since this server sits behind a reverse proxy |
| `mod_rewrite`                  | URL rewriting — used by Zabbix for clean URLs                                                                                        |

## B - Server-Level Hardening

In `/etc/httpd/conf/httpd.conf`, set:

```apache
ServerSignature Off
ServerTokens Prod
```

These directives prevent Apache from leaking version information in error pages and HTTP response headers.

### C - Create the Virtual Host

Create `/etc/httpd/conf/extra/zabbix.conf`:

> [!WARNING] 
> You **must** replace `10.X.X.X` with the actual IP address of your reverse proxy. This is the mechanism that tells Apache which source is trusted to set the `X-Forwarded-For` header. If this is wrong or missing, either all clients appear with the proxy's IP, or worse, an attacker can forge their IP.

```apache
<VirtualHost *:80>
    ServerName zabbix.yourdomain.com

    DocumentRoot "/usr/share/webapps/zabbix"

    # --- Reverse Proxy Trust ---
    # Only trust X-Forwarded-For from our known reverse proxy.
    RemoteIPHeader X-Forwarded-For
    RemoteIPInternalProxy 10.X.X.X

    # --- Base Directory Access ---
    <Directory "/usr/share/webapps/zabbix">
        Options FollowSymLinks
        AllowOverride None
        Require all granted
        DirectoryIndex index.php index.html
    </Directory>

    # --- PHP-FPM Handler ---
    <FilesMatch \.php$>
        SetHandler "proxy:unix:/run/php-fpm/php-fpm.sock|fcgi://localhost/"
    </FilesMatch>

    # --- Deny Access to Sensitive Directories ---
    # These directories contain PHP includes and configuration.
    # They must NEVER be served directly to a browser.
    <DirectoryMatch "^/usr/share/webapps/zabbix/(conf|app|include|local)/">
        Require all denied
    </DirectoryMatch>
    
    # --- Logging ---
    ErrorLog "/var/log/httpd/zabbix_error.log"
    CustomLog "/var/log/httpd/zabbix_access.log" common

</VirtualHost>
```

>[!NOTE] 
**Why no separate log files?** Apache on Arch Linux, when managed by `systemd`, already captures `stdout`/`stderr` into the journal. Adding `ErrorLog` and `CustomLog` directives creates a second logging pathway that requires its own `logrotate` configuration. We avoid this by relying on `journald`, which handles rotation automatically. Access the logs with:

```bash
journalctl -u httpd --since today
```

If you have a specific need for file-based logs (such as feeding them to a SIEM or log aggregator), add the directives back **and** configure `logrotate` — covered in Part X.

### D - Include the Virtual Host

Add the following line at the **bottom** of `/etc/httpd/conf/httpd.conf`:

```apache
Include conf/extra/zabbix.conf
```

### E - Validate and Start Apache

Test the configuration for syntax errors before starting:

```bash
httpd -t
```

Expected output: `Syntax OK`. If you see errors, resolve them before proceeding.

```bash
sudo systemctl enable --now httpd
```

## Part V - Zabbix Server Configuration

### A - Server Daemon Configuration

Edit `/etc/zabbix/zabbix_server.conf`. Most of this file is comments — the relevant directives are:

```ini
DBName=zabbix
DBUser=zabbix
DBPassword=YOUR_SECURE_PASSWORD

LogFile=/var/log/zabbix/zabbix_server.log
LogFileSize=1

FpingLocation=/usr/bin/fping
Fping6Location=/usr/bin/fping6
```

> [!WARNING] 
> **`AllowUnsupportedDBVersions`** — You will likely see a startup error stating that your MariaDB version is not supported. This is because Zabbix officially supports MySQL, and MariaDB's version numbering has diverged. To resolve this, add:
> ```ini
> AllowUnsupportedDBVersions=1
> ```
> 
> Understand what this does: it **suppresses a safety check**. If a future Arch update pushes a MariaDB version with breaking SQL behavior, Zabbix will not warn you — it will start and potentially produce incorrect data. After every `pacman -Syu` that updates MariaDB, verify that Zabbix is functioning correctly.

|Directive|Value|Rationale|
|---|---|---|
|`LogFile`|`/var/log/zabbix/zabbix_server.log`|Standard log location|
|`LogFileSize`|`1`|Enables Zabbix's internal log rotation at 1 MB. The daemon will rotate the file itself. Set to `0` **only** if you configure external rotation via `logrotate`.|
|`FpingLocation`|`/usr/bin/fping`|Explicit path. Zabbix will not search `$PATH` — it needs the absolute location.|

### B - Ensure the Log Directory Exists

```bash
sudo mkdir -p /var/log/zabbix
sudo chown zabbix:zabbix /var/log/zabbix
```

### C - Start the Zabbix Server

```bash
sudo systemctl enable --now zabbix-server-mysql
```

Verify it started correctly:

```bash
systemctl status zabbix-server-mysql
```

Check the log for errors:

```bash
cat /var/log/zabbix/zabbix_server.log
```

A healthy startup will show lines about database connections, cache loading, and pollers starting. If you see `cannot parse DBPassword` or `connection refused`, recheck Part II-C and Part V-A.

## Part VI - Zabbix Agent Configuration (Self-Monitoring)

The agent was installed in Part I but must be configured and started. Without it, the Zabbix server cannot monitor the host it runs on.

Edit `/etc/zabbix/zabbix_agentd.conf`:

```ini
Server=127.0.0.1
ServerActive=127.0.0.1
Hostname=zabbix-server
```

|Directive|Purpose|
|---|---|
|`Server`|Allows passive checks from this IP (the Zabbix server, running locally)|
|`ServerActive`|Target for active checks (the agent pushes data to this address)|
|`Hostname`|Must match exactly the host name you configure in the Zabbix frontend|

Start and enable:

```bash
sudo systemctl enable --now zabbix-agent
```

## Part VIII - Frontend Setup and Finalization

### A - Nginx Reverse Proxy Prerequisites

Before running the web installer, your Nginx reverse proxy must be configured to forward requests to this backend.

### B - Access the Web Installer

Navigate to `https://zabbix.yourdomain.com` through your reverse proxy. The Zabbix web installer will guide you through the final configuration.

When prompted for database details:

|Field|Value|
|---|---|
|Database type|MySQL|
|Database host|localhost|
|Database port|3306 (default)|
|Database name|zabbix|
|Database user|zabbix|
|Database password|The password from Part II-C|

### C - Configuration File Write

The web installer will attempt to write `zabbix.conf.php` to `/usr/share/webapps/zabbix/conf/`. By default, this directory is **not writable** by the `http` user — this is correct and intentional.

You have two options:

**Option A - Temporarily grant write access (simpler):**

```bash
sudo chown http:http /usr/share/webapps/zabbix/conf
```

Complete the web installer, then immediately revoke:

```bash
sudo chown root:root /usr/share/webapps/zabbix/conf
```

**Option B - Manual placement (more secure):**

The web installer will offer a download link for the generated file. Download it, then upload it to the server:

```bash
sudo cp zabbix.conf.php /usr/share/webapps/zabbix/conf/
sudo chown root:root /usr/share/webapps/zabbix/conf/zabbix.conf.php
sudo chmod 644 /usr/share/webapps/zabbix/conf/zabbix.conf.php
```

> [!NOTE] 
> The `http` user only needs to **read** this file at runtime, not write to it. Ownership by `root` with `644` permissions is the correct final state.

### D - Default Login Credentials

|Field|Value|
|---|---|
|Username|Admin|
|Password|zabbix|

## Part XIII - Service Verification

Restart all services to apply every configuration change:

```bash
sudo systemctl restart mariadb
sudo systemctl restart php-fpm
sudo systemctl restart httpd
```

Verify each service is running:

```bash
systemctl status mariadb --no-pager
systemctl status php-fpm --no-pager
systemctl status httpd --no-pager
```

All three must show `active (running)`.

Test the full chain from the server itself:

```bash
curl -H "Host: zabbix.yourdomain.com" http://localhost
```

Expected output: HTML content of the Main Page (or a 301 redirect to it).

Test from the outside by navigating to:

```
https://zabbix.yourdomain.com
```

You should see the Zabbix's Login Page served over HTTPS.

## Part X - Log Rotation (Optional — File-Based Logging)

If you chose to set `LogFileSize=0` in `zabbix_server.conf` (disabling Zabbix's internal rotation) or if you added Apache `ErrorLog`/`CustomLog` directives, you **must** configure `logrotate`.

Install `logrotate` if not already present:

```bash
sudo pacman -S logrotate
```

Create `/etc/logrotate.d/zabbix`:

```
/var/log/zabbix/*.log {
    weekly
    rotate 12
    compress
    delaycompress
    missingok
    notifempty
    create 0640 zabbix zabbix
    postrotate
        systemctl kill -s HUP zabbix-server-mysql.service
    endscript
}
```

If you use file-based Apache logs, create `/etc/logrotate.d/httpd-zabbix`:

```
/var/log/httpd/zabbix*.log {
    weekly
    rotate 12
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root root
    postrotate
        systemctl reload httpd.service
    endscript
}
```

> [!TIP] 
> `logrotate` on Arch is triggered by a systemd timer (`logrotate.timer`), which is enabled by default. Verify with:

```bash
sudo systemctl status logrotate.timer
```
