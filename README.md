# Local WordPress Stack

Release: `v1.0.1`

This project sets up a local WordPress development stack on Windows with PHP, Nginx, MySQL, phpMyAdmin, and SSL support.

## Requirement

- Git/Gitbash must be installed on your PC for SSL setup.
- The initializer uses `openssl.exe` to generate the local SSL certificate.
- In this project, OpenSSL is expected from **Git for Windows** if a system OpenSSL install is not available.

## Root Directory Tree Will Create Automatically

```text
localhost-wp
├─ backup
├─ config
├─ logs
├─ mysql
├─ nginx
├─ php
├─ phpmyadmin
├─ scripts
├─ sites
└─ ssl
```

## Run

Run/Double click init.bat from the project root:

- `init.bat`

The initializer prints the current setup release from the top-level `VERSION` file.

During setup, the initializer will automatically download the required packages if the corresponding directories are missing.

## Optional Manual Downloads

If you want to avoid download time during setup, download and extract these packages manually, then place them into the matching project directories before running the initializer:

- `nginx`:
  https://nginx.org/download/nginx-1.26.3.zip
- `mysql`:
  https://cdn.mysql.com/archives/mysql-8.0/mysql-8.0.36-winx64.zip
- `php`:
  https://downloads.php.net/~windows/releases/php-8.3.30-nts-Win32-vs16-x86.zip
- `phpmyadmin`:
  https://files.phpmyadmin.net/phpMyAdmin/5.2.2/phpMyAdmin-5.2.2-all-languages.zip

If those extracted directories already exist in root dir as `nginx`, `php`, `mysql`, and `phpmyadmin`, the initializer will use them instead of downloading again.

## SSL Note

The setup generates:

- `ssl/rootCA.pem`
- `ssl/rootCA.key`
- `ssl/cert.pem`
- `ssl/key.pem`

The installer creates a local root CA, trusts it for the current Windows user, then signs the server certificate for `localhost`, `127.0.0.1`, and the active machine IP.

PHP is also configured to trust that local CA through `curl.cainfo` and `openssl.cafile`, so `wp_remote_get()` can verify HTTPS calls to the local sites.

If Git/Gitbash is not installed, SSL certificate generation may fail because `openssl.exe` cannot be found.

## Backup

A database backup runs automatically each time the server is stopped via `stop.bat`.

Backups are stored in `backup/<site-name>/` and a rolling rotation of two files is maintained:

| File | Description |
|------|-------------|
| `db-date-time.sql` | Latest backup |
| `db-date-time.sql` | Previous backup, replaced on the next stop |

## Quick Glimpse  
Dashboard: https:localhost

![Localhost Dashboard](./localhost-dashboard.png)
