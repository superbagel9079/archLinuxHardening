# Zabbix Server Deployment on Arch Linux (Apache/PHP-FPM/MariaDB)

---

## Part I - System Preparation & Installation

We begin by installing the core components. Arch Linux splits the Zabbix stack into the server, the frontend, and the agent.

```bash
# Update the system first
sudo pacman -Syu

# Install Zabbix components, Database, Web Server, and PHP tools
sudo pacman -S zabbix-server zabbix-frontend-php zabbix-agent apache mariadb php php-fpm php-gd fping
```

## Part II - Database Configuration (MariaDB)

Zabbix requires a robust database backend. We will initialize MariaDB and inject the Zabbix schema.

### A - Initialization and Securing

Initialize the data directory and secure the installation.

```bash
sudo mariadb-install-db --user=mysql --basedir=/usr --datadir=/var/lib/mysql
sudo systemctl enable --now mariadb

# Run the security script. Answer 'Y' to all prompts after setting a root password.
sudo mariadb-secure-installation
```

### B - Production Tuning & Character Set

Create a specific configuration file to enforce UTF8MB4 and optimize InnoDB.

**File:** `/etc/my.cnf.d/zabbix.cnf`

```ini
[mysqld]
# Character Set for Zabbix
character-set-server = utf8mb4
collation-server = utf8mb4_bin

# Production Tuning (Adjust buffer pool to 60-70% of available RAM)
innodb_buffer_pool_size = 5G
innodb_log_file_size = 128M
innodb_file_per_table = 1

# Connection Limits
max_connections = 100
```

Restart MariaDB to apply changes:

```bash
systemctl restart mariadb
```

### C - Database Creation

Log in to MariaDB (`mariadb -u root -p`) and execute:

```sql
CREATE DATABASE zabbix CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;
CREATE USER 'zabbix'@'localhost' IDENTIFIED BY 'YOUR_SECURE_PASSWORD';
GRANT ALL PRIVILEGES ON zabbix.* TO 'zabbix'@'localhost';
FLUSH PRIVILEGES;
EXIT;
```

### D - Schema Import

Import the initial schema and data provided by the Zabbix package.

```bash
sudo mariadb -u zabbix -p -D zabbix < /usr/share/zabbix-server/mysql/schema.sql
sudo mariadb -u zabbix -p -D zabbix < /usr/share/zabbix-server/mysql/images.sql
sudo mariadb -u zabbix -p -D zabbix < /usr/share/zabbix-server/mysql/data.sql
```

## Part III - Zabbix Server Configuration

We must link the server daemon to the database we just created.

Edit `/etc/zabbix/zabbix_server.conf`:

```ini
DBName=zabbix
DBUser=zabbix
DBPassword=YOUR_SECURE_PASSWORD

# Optimization: Disable default guest user check if not needed
# AllowRoot=0
# User=zabbix

# Clean logs
LogFile=/var/log/zabbix/zabbix_server.log
LogFileSize=0
```

Start the Zabbix server process:

```bash
sudo systemctl enable --now zabbix-server
```

## Part IV - PHP & PHP-FPM Configuration

Zabbix requires specific PHP extensions and settings.

### A - PHP Settings

Edit `/etc/php/php.ini`. ensure the following lines are uncommented (remove `;`) and values adjusted:

```ini
# Extensions required by Zabbix
extension=bcmath
extension=gd
extension=gettext
extension=mysqli
extension=sockets
extension=mbstring
# Optional: required for LDAP authentication
# extension=ldap

# Resource limits (Zabbix recommendations)
post_max_size = 16M
max_execution_time = 300
max_input_time = 300
memory_limit = 128M

# Timezone (Imperative for graph correlation)
date.timezone = "UTC" 
# Change "UTC" to your actual timezone
```

### B - PH-FPM Socket

Ensure PHP-FPM is listening on a socket (default in Arch). **File:** `/etc/php/php-fpm.d/www.conf`

```ini
listen = /run/php-fpm/php-fpm.sock
listen.owner = http
listen.group = http
listen.mode = 0660
```

### C - Start PHP-FPM

```bash
sudo systemctl enable --now php-fpm
```

## Part V - Apache Configuration (Reverse Proxy Aware)

We will configure Apache to use PHP-FPM and handle the `X-Forwarded-For` headers correctly.

### A - Enable Modules

Edit `/etc/httpd/conf/httpd.conf` and uncomment these lines:

```apache
LoadModule proxy_module modules/mod_proxy.so
LoadModule proxy_fcgi_module modules/mod_proxy_fcgi.so
LoadModule remoteip_module modules/mod_remoteip.so
LoadModule rewrite_module modules/mod_rewrite.so
```

### B - Create Virtual Host

Create a dedicated configuration file: `/etc/httpd/conf/extra/zabbix.conf`.

>[!WARNING] 
>Replace `10.X.X.X` in `RemoteIPInternalProxy` with the **actual IP address** of your Reverse Proxy server. If you do not do this, Apache will log the proxy's IP instead of the real client IP.

```apache
<VirtualHost *:80>
    ServerName monitoring.a4i.com
    DocumentRoot "/usr/share/webapps/zabbix"

    # Reverse Proxy Configuration
    RemoteIPHeader X-Forwarded-For
    # TRUSTED_PROXY_IP is the IP of the proxy connecting to this server
    RemoteIPInternalProxy 10.X.X.X

    <Directory "/usr/share/webapps/zabbix">
        Options FollowSymLinks
        AllowOverride None
        Require all granted
    </Directory>

    # PHP-FPM Configuration via Proxy
    <FilesMatch \.php$>
        SetHandler "proxy:unix:/run/php-fpm/php-fpm.sock|fcgi://localhost/"
    </FilesMatch>
    
    # Deny access to sensitive Zabbix configuration files
    <Directory "/usr/share/webapps/zabbix/conf">
        Require all denied
    </Directory>
    <Directory "/usr/share/webapps/zabbix/app">
        Require all denied
    </Directory>

    # Logging (Optional: Log the real client IP)
    ErrorLog "/var/log/httpd/monitoring.a4i.com_error.log"
    CustomLog "/var/log/httpd/monitoring.a4i.com_access.log" common
</VirtualHost>
```

Finally, include this file in your main config. Add this to the bottom of `/etc/httpd/conf/httpd.conf`:

```apache
Include conf/extra/zabbix.conf
```

Restart Apache:

```bash
sudo systemctl enable --now httpd
```

## Part VI - Finalization

**Check Apache Logs:** Tail the logs while accessing the site to verify `mod_remoteip` is working. You should see your actual client IP, not the proxy IP.

```bash
tail -f /var/log/httpd/monitoring.a4i.com_access.log
```

**Frontend Setup:** Navigate to `https://monitoring.a4i.com` (via your reverse proxy). Follow the web installer steps.

- **DB Type:** MySQL
- **Host:** localhost
- **Port:** 3306
- **Database:** zabbix
- **User:** zabbix

> [!WARNING] 
> Since this is behind a reverse proxy, ensure your proxy handles **TLS/SSL termination**. Do not expose this Apache instance directly to the public internet on port 80 without encryption managed by the proxy or firewall rules.

>[!NOTE] 
>During the setup, Zabbix will attempt to create a configuration file. Since `/usr/share/webapps/zabbix/conf/` is not writable by the `http` user by default (good security), you may need to download the generated `zabbix.conf.php` file and upload it manually to the server, placing it in `/usr/share/webapps/zabbix/conf/`.