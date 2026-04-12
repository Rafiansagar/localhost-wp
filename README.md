# Local WordPress Stack

This project sets up a local WordPress development stack on Windows with PHP, Nginx, MySQL, phpMyAdmin, and SSL support.

## Requirement

- Git must be installed on your PC for SSL setup.
- The initializer uses `openssl.exe` to generate the local SSL certificate.
- In this project, OpenSSL is expected from **Git for Windows** if a system OpenSSL install is not available.

## Run

Use either of these files from the project root:

- `init.bat`
- `init.ps1`

## SSL Note

The setup generates:

- `ssl/cert.pem`
- `ssl/key.pem`

If Git is not installed, SSL certificate generation may fail because `openssl.exe` cannot be found.
