# Mediawiki Server Deployment on Arch Linux (Apache/PHP-FPM/MariaDB)

## Part I - System Preparation & Installation

We begin by installing the core components. MediaWiki on Arch Linux is distributed as a single package that includes the application and its bundled extensions (including VisualEditor and Parsoid).

```bash
# Update the system first
sudo pacman -Syu

# Install MediaWiki, Database, Web Server, and PHP tools
sudo pacman -S mediawiki apache mariadb php php-fpm php-intl php-gd php-apcu
```

> [!NOTE] 
> Package Roles Explained:
> 
|Package|Purpose|
|---|---|
|`mediawiki`|The wiki application, installed to `/usr/share/webapps/mediawiki`. Pulls in `php` as a dependency|
|`apache`|The HTTP server (called `httpd` in its service unit), serving as the backend behind an Nginx reverse proxy|
|`mariadb`|The relational database storing all wiki pages, user accounts, revisions, and metadata|
|`php` / `php-fpm`|The PHP interpreter and FastCGI Process Manager. Apache delegates all `.php` processing to PHP-FPM over a Unix socket|
|`php-intl`|The Internationalization extension — a hard requirement for MediaWiki's Unicode normalization and locale handling|
|`php-gd`|Image rendering library required for thumbnail generation, captcha images, and graph rendering|
|`php-apcu`|APCu userland cache. Provides a fast in-memory object cache that MediaWiki uses to avoid redundant database queries|

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

| Prompt                                | Recommended Response | Reason                                                                                     |
| ------------------------------------- | -------------------- | ------------------------------------------------------------------------------------------ |
| Switch to unix_socket authentication? | `n`                  | Password authentication is sufficient for local service accounts                           |
| Change the root password?             | `Y`                  | Set a strong password — the MediaWiki installer will need it to create the database schema |
| Remove anonymous users?               | `Y`                  | Prevents unauthenticated database access                                                   |
| Disallow root login remotely?         | `Y`                  | Root should only connect from localhost                                                    |
| Remove test database?                 | `Y`                  | Eliminates an unnecessary attack surface                                                   |
| Reload privilege tables now?          | `Y`                  | Applies all changes immediately                                                            |
### B - Production Tuning

The InnoDB storage engine benefits from the same tuning principles regardless of the application. MediaWiki stores all page revisions, file metadata, and internal caches in InnoDB tables — this is a write-heavy workload that benefits directly from a properly sized buffer pool.

Create a dedicated configuration drop-in file. Do not edit the main `my.cnf` — Arch's package manager may overwrite it on update.

Create and edit `/etc/my.cnf.d/mediawiki-server.cnf`:

```ini
[mysqld]

# --- Character Set ---
# NOTE: We do NOT set a server-wide character set here.
# MediaWiki requires CHARACTER SET binary COLLATE binary at the
# database level. This is enforced in the CREATE DATABASE statement.
# Setting utf8mb4 here would not break anything (the database-level
# override takes precedence), but it would be misleading.

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
innodb_log_file_size = 128M

# Store each InnoDB table in its own file. This improves manageability
# and allows space to be reclaimed when tables are dropped or truncated.
innodb_file_per_table = 1

# --- Connection Limits ---
# MediaWiki via PHP-FPM opens one connection per request.
# With pm.max_children = 5, you will rarely exceed 10 simultaneous
# connections. 50 is conservative headroom for future growth.
max_connections = 50
```

> [!WARNING] 
> **You must calculate `innodb_buffer_pool_size` for your specific hardware.** If this value exceeds your available physical RAM, MariaDB will either fail to start or force the kernel's OOM killer to terminate it. Check your available memory with `free -h` before setting this value.

Restart MariaDB to apply changes:

```bash
sudo systemctl restart mariadb
```

### C - Database and User Creation

Log in to MariaDB:

```bash
sudo mariadb -u root -p
```

> [!WARNING] 
> MediaWiki requires **binary collation**. Using a standard `utf8` or `utf8mb4` collation will cause data corruption on certain Unicode edge cases (particularly CJK characters and emoji in page titles). The `CHARACTER SET binary COLLATE binary` clause is mandatory. Reference: [MediaWiki Manual — Installation requirements](https://www.mediawiki.org/wiki/Manual:Installation_requirements)

Execute the following. Replace `YOUR_SECURE_PASSWORD` with a strong, unique password.

```sql
CREATE DATABASE mediawiki CHARACTER SET binary COLLATE binary;
CREATE USER 'mediawiki'@'localhost' IDENTIFIED BY 'your_secure_password_here';
GRANT ALL PRIVILEGES ON mediawiki.* TO 'mediawiki'@'localhost';
FLUSH PRIVILEGES;
EXIT;
```

> [!TIP]
> Generate a strong password with: `openssl rand -base64 32`

## Part III - PHP and PHP-FPM Configuration

### A - PHP Extensions and Settings

Edit `/etc/php/php.ini`. Locate and uncomment (remove the leading `;`) the following lines:

```ini
extension=iconv
extension=intl
extension=gd
extension=mysqli
```

> [!NOTE] 
> `iconv` is typically compiled in and enabled by default on Arch. Confirm by running `php -m | grep iconv`. If it appears in the output, no action is needed for that line. `mysqli` is the database driver that MediaWiki uses for all MariaDB/MySQL connections.

**Resource limits to adjust** — find each directive and modify its value:

```ini
post_max_size       = 20M
upload_max_filesize = 16M
max_execution_time  = 300
max_input_time      = 300
memory_limit        = 512M
```

| Directive             | Default | Required Value | Reason                                                                            |
| --------------------- | ------- | -------------- | --------------------------------------------------------------------------------- |
| `post_max_size`       | `8M`    | `20M`          | Must accommodate file uploads plus form overhead                                  |
| `upload_max_filesize` | `2M`    | `16M`          | Maximum size for a single uploaded file (images, PDFs)                            |
| `max_execution_time`  | `30`    | `300`          | Complex page renders, VisualEditor saves, and maintenance scripts need more time  |
| `max_input_time`      | `60`    | `300`          | Large form submissions (bulk edits) require extended input parsing                |
| `memory_limit`        | `128M`  | `256M`         | VisualEditor/Parsoid operations and large page transclusions are memory-intensive |

Edit `/etc/php/conf.d/apcu.ini` and ensure the following line is present and uncommented:

```ini
extension=apcu.so
```

**Timezone** - this is critical.  MediaWiki uses PHP's timezone for revision timestamps, log entries, and signature formatting.

```ini
date.timezone = "UTC"
```

Replace `UTC` with your actual timezone. The list of valid values is at [php.net/manual/en/timezones.php](https://www.php.net/manual/en/timezones.php).

### C - Sessions

Configure the session save path:

```ini
session.save_path = "/var/lib/php/sessions"
```

Create the directory and set ownership:

```bash
sudo mkdir -p /var/lib/php/sessions
sudo chown http:http /var/lib/php/sessions
sudo chmod 700 /var/lib/php/sessions
```

### D - PHP-FPM Pool Configuration

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

### D - Start PHP-FPM

```bash
sudo systemctl enable --now php-fpm
```

Verify the socket was created:

```bash
ls -la /run/php-fpm/php-fpm.sock
```

You should see ownership as `http:http` with `0660` permissions.

# Part IV - Apache Configuration

## A - Module Activation

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

Ensure the `mpm_event_module` is active (this is the default on Arch and the recommended MPM for use with PHP-FPM):

```apache
LoadModule mpm_event_module modules/mod_mpm_event.so
```

> [!WARNING]
> Do **not** enable `mpm_prefork_module` alongside `mpm_event_module`. Only one MPM can be active. `mpm_event` is the correct choice when using PHP-FPM as an external process manager. Reference: [Apache HTTP Server — MPM event](https://httpd.apache.org/docs/2.4/mod/event.html).

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
    ServerName wiki.yourdomain.com
    DocumentRoot "/usr/share/webapps/mediawiki"

    # --- Reverse Proxy Trust ---
    # Only trust X-Forwarded-For from our known Nginx reverse proxy.
    RemoteIPHeader X-Forwarded-For
    RemoteIPInternalProxy 10.X.X.X

    # --- Base Directory Access ---
    <Directory "/usr/share/webapps/mediawiki">
        Options FollowSymLinks
        AllowOverride None
        Require all granted
        DirectoryIndex index.php index.html
    </Directory>

    # --- PHP-FPM Handler ---
    <FilesMatch \.php$>
        SetHandler "proxy:unix:/run/php-fpm/php-fpm.sock|fcgi://localhost/"
    </FilesMatch>

    # --- Short URL Rewrites ---
    RewriteEngine On

    # Rewrite /wiki/Article_Title to index.php
    RewriteRule ^/?wiki(/.*)?$ /index.php [L]

    # Redirect bare domain to the Main Page
    RewriteRule ^/*$ /wiki/Main_Page [R=301,L]

    # --- Deny Access to Sensitive Directories ---
    # These directories contain PHP includes and configuration.
    # They must NEVER be served directly to a browser.
    <DirectoryMatch "^/usr/share/webapps/mediawiki/(cache|includes|maintenance|languages|serialized|tests|images/deleted)/">
        Require all denied
    </DirectoryMatch>

    <DirectoryMatch "^/usr/share/webapps/mediawiki/(bin|docs|extensions|includes|maintenance|mw-config|resources|serialized|tests)/">
        Require all denied
    </DirectoryMatch>

    # --- Logging ---
    ErrorLog "/var/log/httpd/mediawiki_error.log"
    CustomLog "/var/log/httpd/mediawiki_access.log" common
</VirtualHost>
```

>[!NOTE] 
**Why no separate log files?** Apache on Arch Linux, when managed by `systemd`, already captures `stdout`/`stderr` into the journal. Adding `ErrorLog` and `CustomLog` directives creates a second logging pathway that requires its own `logrotate` configuration. We avoid this by relying on `journald`, which handles rotation automatically. Access the logs with:

```bash
journalctl -u httpd --since today
```

If you have a specific need for file-based logs (such as feeding them to a SIEM or log aggregator), add the directives back **and** configure `logrotate` — covered in Part VII.

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

## Part V - MediaWiki Web Installer

### A - Nginx Reverse Proxy Prerequisites

Before running the web installer, your Nginx reverse proxy must be configured to forward requests to this backend.

### B - Run the Installer

Navigate to `https://wiki.yourdomain.com` through your reverse proxy. The MediaWiki web installer will walk you through the following steps:

| Step                | Action                                                                                                                      |
| ------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| Language            | Select the wiki's content language and installer language                                                                   |
| Welcome             | The installer checks PHP extensions and environment — all should pass green                                                 |
| Database connection | Select **MariaDB/MySQL**. Host: `localhost`. Database: `mediawiki`. User: `mediawiki`. Password: the one you set in Part II |
| Database settings   | Accept defaults (InnoDB, binary tables)                                                                                     |
| Wiki name           | Enter your wiki name (e.g., `My Wiki`)                                                                                      |
| Admin account       | Create the administrator username and password                                                                              |
| Options             | Enable file uploads. Choose **APCu** for the main cache if offered                                                          |
| Install             | The installer creates tables and populates the database                                                                     |

At the end, the installer generates a `LocalSettings.php` file and offers it for download.

### C - Place LocalSettings.php

Save the downloaded file to the server:

```bash
sudo mv /path/to/downloaded/LocalSettings.php /etc/webapps/mediawiki/LocalSettings.php
sudo chown root:http /etc/webapps/mediawiki/LocalSettings.php
sudo chmod 640 /etc/webapps/mediawiki/LocalSettings.php
```

> [!NOTE] 
> The `mediawiki` package includes a symlink at `/usr/share/webapps/mediawiki/LocalSettings.php` pointing to `/etc/webapps/mediawiki/LocalSettings.php`. Do not remove this symlink.

Verify the symlink:

```bash
ls -la /usr/share/webapps/mediawiki/LocalSettings.php
```

Expected output: `LocalSettings.php -> /etc/webapps/mediawiki/LocalSettings.php`

## Part VI - Post-Install Configuration (LocalSettings.php)

Edit `/etc/webapps/mediawiki/LocalSettings.php` and append or modify the following blocks.

### A - Server URL and Protocol

Because TLS is terminated at the Nginx proxy, MediaWiki must be told that the canonical URL uses HTTPS even though Apache receives plain HTTP:

```php
$wgServer = "https://wiki.yourdomain.com";
$wgForceHTTPS = true;
$wgCookieSecure = true;
```

> [!WARNING] 
> Without `$ wgServer` set to `https://`, MediaWiki will generate internal links using `http://`, causing mixed-content warnings or broken redirects. `$ wgCookieSecure` ensures session cookies are only sent over HTTPS.

### B - Short URLs

```php
$wgArticlePath = "/wiki/$1";
$wgUsePathInfo = true;
```

After this, articles will be accessible at `https://wiki.yourdomain.com/wiki/Article_Title`.

### C - File Uploads

Confirm that file uploads are enabled (the web installer may have already set this):

```php
$wgEnableUploads = true;
$wgUploadPath = "$wgScriptPath/images";
$wgUploadDirectory = "$IP/images";
```

Set the permissions on the upload directory:

```bash
sudo chown -R http:http /usr/share/webapps/mediawiki/images
sudo chmod -R 755 /usr/share/webapps/mediawiki/images
```

### D - Caching (APCu)

```php
$wgMainCacheType = CACHE_ACCEL;
$wgSessionCacheType = CACHE_DB;
$wgMemCachedServers = [];
```

> [!NOTE] 
> `CACHE_ACCEL` instructs MediaWiki to use the PHP accelerator cache — in our case, APCu. Session data is stored in the database rather than APCu because APCu is not shared across PHP-FPM worker restarts. Reference: [MediaWiki Manual — Caching](https://www.mediawiki.org/wiki/Manual:Caching).

### E - VisualEditor

Modern MediaWiki (1.35+) bundles both the VisualEditor extension and Parsoid. Enable VisualEditor by adding:

```php
wfLoadExtension( 'VisualEditor' );
$wgDefaultUserOptions['visualeditor-enable'] = 1;
$wgVisualEditorAvailableNamespaces = [
    NS_MAIN => true,
    NS_USER => true,
];
```

> [!NOTE] 
> Since MediaWiki 1.41, Parsoid runs as an internal service within the PHP process. No separate Parsoid service or Node.js installation is required. If your version is 1.40 or earlier, consult the [Parsoid setup documentation](https://www.mediawiki.org/wiki/Parsoid). Verify your version with `php /usr/share/webapps/mediawiki/maintenance/run.php version`.

Because the server is behind a reverse proxy that terminates TLS, Parsoid's internal API calls may fail if MediaWiki tries to reach itself over HTTPS. Add the following to ensure internal requests use the local HTTP endpoint:

```php
$wgVirtualRestConfig['modules']['parsoid'] = [
    'url' => 'http://localhost:80',
    'domain' => 'wiki.yourdomain.com',
];
```

### F - Reverse Proxy Trust

Tell MediaWiki to trust the `X-Forwarded-For` header from the Nginx proxy:

```php
$wgSquidServersNoPurge = ['10.X.X.X'];
$wgUseSquid = true;
```

> [!NOTE] 
> Despite the naming (`Squid`), these directives apply to any reverse proxy. `$wgSquidServersNoPurge` tells MediaWiki which IPs are trusted proxies, so it reads the real client IP from `X-Forwarded-For` instead of logging the proxy's IP for every request. Replace `10.X.X.X` with your Nginx proxy's IP.

---

## Part VII - Service Verification

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
curl -H "Host: wiki.yourdomain.com" http://localhost/wiki/Main_Page
```

Expected output: HTML content of the Main Page (or a 301 redirect to it).

Test from the outside by navigating to:

```
https://wiki.yourdomain.com/wiki/Main_Page
```

You should see the wiki's Main Page served over HTTPS.

---

## Part VIII - Log Rotation

Since we defined custom `ErrorLog` and `CustomLog` directives in the Apache virtual host, we must configure `logrotate` to prevent unbounded disk growth.

Install `logrotate` if not already present:

```bash
sudo pacman -S logrotate
```

Create `/etc/logrotate.d/httpd-mediawiki`:

```
/var/log/httpd/mediawiki*.log {
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
>  `logrotate` on Arch is triggered by a systemd timer (`logrotate.timer`), which is enabled by default. Verify with:

```bash
sudo systemctl status logrotate.timer
```