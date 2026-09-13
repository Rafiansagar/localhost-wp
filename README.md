# localhost-wp

Release: `v2.1.0`

A self-contained local WordPress development stack for Windows — Nginx · MySQL 8.0 · PHP 8.3 · phpMyAdmin — managed through a GUI control panel.

---

## Requirements

- **Windows 10 or later**
- **PowerShell** (built into Windows, no extra install needed)

---

## Getting Started

### 1. Clone the repository

```
git clone <repo-url> localhost-wp
```

### 2. Launch the control panel

Double-click **`control-panel.bat`** in the project root.

**First run (no binaries yet):**
The control panel detects that the stack has not been set up and shows a **Run Setup** button. Click it — setup will automatically download and configure everything directly inside the GUI activity log.

**Every run after that:**
The control panel opens directly into the normal interface. No setup prompt.

---

## What Setup Does

Setup runs once and handles everything automatically:

- Downloads and installs **Nginx 1.26**, **MySQL 8.0.36**, **PHP 8.3.30 NTS**, **phpMyAdmin 5.2.2**
- Configures `php.ini` (extensions, upload limits)
- Configures MySQL (`my.ini`, initializes data directory)
- Writes Nginx configs (main, phpMyAdmin vhost, WordPress snippet)
- Configures phpMyAdmin

If the binaries already exist, setup skips re-downloading them.

### Optional: manual pre-download

To avoid download time during setup, extract these into their matching directories before running:

| Directory | Package |
|-----------|---------|
| `nginx\` | https://nginx.org/download/nginx-1.26.3.zip |
| `mysql\` | https://cdn.mysql.com/archives/mysql-8.0/mysql-8.0.36-winx64.zip |
| `php\` | https://downloads.php.net/~windows/releases/archives/php-8.3.31-nts-Win32-vs16-x64.zip |
| `phpmyadmin\` | https://files.phpmyadmin.net/phpMyAdmin/5.2.2/phpMyAdmin-5.2.2-all-languages.zip |

---

## Control Panel

All stack and site management is done through the GUI — no terminal needed.

**Stack section**
| Button | What it does |
|--------|-------------|
| Start Stack | Starts MySQL, PHP FastCGI, and Nginx |
| Stop Stack | Backs up all databases, then stops the stack |
| Refresh status | Shows which services are running |

**Sites section**
| Button | What it does |
|--------|-------------|
| + New site | Creates a WordPress site (database + files + Nginx vhost) |
| phpMyAdmin | Opens phpMyAdmin at `http://localhost:8080` |
| Dashboard | Opens the stack dashboard at `http://localhost` |
| Refresh list | Reloads the site list |

Each site card shows its port, server status, database status, wp-config status, and buttons to open the site, WP Admin, back up the database, or delete the site.

The **Open links on** selector at the top right of the Sites section controls whether links use `localhost` or the machine IP (useful for testing from a phone on the same network).

---

## Directory Layout

What is tracked in git:

```
localhost-wp/
├─ scripts/
│  ├─ control-panel.ps1       GUI only
│  ├─ cp-core.ps1             Utilities, status checks, helpers
│  ├─ cp-stack.ps1            Start/Stop/Reload stack logic
│  ├─ cp-sites.ps1            New site, backup, delete logic
│  └─ helper/
│     ├─ setup.ps1            First-time setup (downloads + configures)
│     ├─ ensure-php-runtime.ps1
│     ├─ start-php.ps1
│     ├─ backup-databases.ps1
│     └─ create-nginx-conf.ps1
├─ control-panel.bat          Entry point — launch this
├─ index.html                 Stack dashboard (served at http://localhost)
├─ .gitignore
├─ README.md
└─ VERSION
```

Created by setup (gitignored — not committed):

```
nginx/       mysql/       php/       phpmyadmin/
config/      logs/        sites/
```

---

## Sites and ports

Sites are served over plain HTTP on the next free port from `9001` up (`9000` is PHP FastCGI). Any port already used by a vhost in `config/nginx/`, or currently listening, is skipped; the last assigned port is kept in `config/ports.txt`.

---

## Backups

Database backups run automatically every time the stack is stopped via the GUI. They are also available on demand per site via the **Backup DB** button on each site card.

Backups are stored in `sites/<site-name>/sql/` with a rolling two-file rotation:

```
sites/mysite/sql/
├─ backup-2026-06-15-10-30.sql   ← latest
└─ backup-2026-06-14-22-00.sql   ← previous
```

---

## Dashboard

![Localhost Dashboard](./localhost-dashboard.png)
