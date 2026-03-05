# n8nite: Opinionated n8n stack on wheels

![License: MIT](https://img.shields.io/badge/License-MIT-green.svg) ![Shell: Bash](https://img.shields.io/badge/Shell-Bash-89e051) ![Stack: Docker Compose](https://img.shields.io/badge/Stack-Docker%20Compose-2496ED) ![Status: Opinionated](https://img.shields.io/badge/Status-Opinionated-orange)

<p align="center">
  <img src="art/n8nite-banner-1280x640.png" alt="n8nite banner" width="900">
</p>

> Pronounced: **nanite** (like the nanomachines, just another fancy name).
> Opinionated n8n stack, ready to roll 🚀: **n8n + PostgreSQL + Redis + worker + Docker Compose + Nginx + Certbot (optional HTTPS)**.

## Table of Contents

1. [TL;DR](#tldr)
2. [Overview](#overview)
3. [Project Status](#project-status)
4. [Repository Layout](#repository-layout)
5. [Prerequisites](#prerequisites)
6. [Install](#install)
7. [Quick Start](#quick-start)
8. [CLI Usage (`n8nite`)](#cli-usage-n8nite)
9. [Environment Configuration](#environment-configuration)
10. [Nginx Workflows](#nginx-workflows)
11. [Testing](#testing)
12. [Troubleshooting](#troubleshooting)
13. [License](#license)
14. [References](#references)

## TL;DR

```bash
# 1) Install 📦
curl -fsSL https://raw.githubusercontent.com/ARMBouhali/n8nite/main/install.sh | bash

# 2) Create env 🧩
n8nite env init prod

# 3) Check host dependencies (auto profile based on .env) 🔎
n8nite deps check

# 4) Generate secure encryption key 🔐
n8nite env keygen --write --force

# 5) Edit .env values, then validate ✅
n8nite env check

# 6) Start stack ▶️
n8nite up

# 7) Generate and deploy nginx config (deploy needs sudo) 🌐
n8nite nginx generate -m https -s automation.example.com
sudo n8nite nginx deploy -c n8n-automation -u 127.0.0.1:5678 -m admin@example.com

# 8) Verify logs 📜
n8nite logs n8n
n8nite logs n8n-worker
```

## Overview

This repository provides a single entrypoint, `n8nite`, to operate a production-style n8n deployment:

- ✅ validates `.env`
- 🐳 runs Docker Compose lifecycle commands
- ⚙️ runs n8n in queue mode (`n8n` + `n8n-worker` + `redis`)
- 🌐 generates Nginx reverse-proxy configs (HTTP/HTTPS)
- 🔐 deploys Nginx configs and optional Let's Encrypt certs
- 🧪 runs a requirements + functional test suite

The goal is to keep all operational tasks in one consistent CLI.

## Project Status

This is an opinionated deployment script/tooling set for a personal n8n deployment.

It was generated step by step with Codex to solve a specific setup workflow.

Project expectations:

- ⚠️ no maintenance commitment
- ⚠️ no guarantee of issue support
- ⚠️ no guarantee of PR review/merge

You are still welcome to fork, adapt, and contribute if useful for your own setup.

## Repository Layout

```text
.
├── n8nite                       # Main CLI
├── install.sh                   # curl|bash installer
├── check-env.sh                 # Env validator
├── check-deps.sh                # Host dependency checker
├── docker-compose.yml
├── .env.example                 # Production-style template
├── .env.local.example           # Local HTTP template
├── nginx/
│   ├── generate-nginx-conf.sh
│   ├── install-nginx-and-deploy.sh
│   └── templates/
│       ├── n8n-http.conf.tmpl
│       └── n8n-https.conf.tmpl
├── postgresql/
│   └── init-data.sh
└── tests/
    └── test-n8nite.sh
```

## Prerequisites

Minimum:

- 🐳 Docker
- 🧩 Docker Compose plugin (`docker compose`)
- 👤 user in `docker` group (or run Docker with sudo)

For Nginx deployment commands:

- 🌐 Nginx
- 🔤 `envsubst` (gettext/gettext-base)
- 🔐 Certbot (only for HTTPS certificate issuance)

You can check your system with:

```bash
./n8nite deps check
./n8nite test -r
```

Dependency profiles:

- `core`: docker + compose + group + daemon
- `nginx-http`: `core` + `nginx` + `envsubst` + `sudo` + `systemctl`
- `nginx-https`: `nginx-http` + `certbot`
- `auto`: picks `nginx-http` or `nginx-https` from `.env` `N8N_PROTOCOL` (falls back to `core` if `.env` is missing)

## Install

Install like `nvm` style via curl:

```bash
curl -fsSL https://raw.githubusercontent.com/ARMBouhali/n8nite/main/install.sh | bash
```

Default install locations:

- 📁 repo: `~/.n8n-sh`
- 🔗 command symlink: `~/.local/bin/n8nite`
- 🧷 PATH persistence: writes managed PATH blocks to `~/.bashrc` and `~/.zshrc`

Optional installer overrides:

- `N8N_SH_REPO` (custom git repo URL)
- `N8N_SH_REF` (branch/tag, default `main`)
- `N8N_SH_DIR` (install path)
- `N8N_SH_BIN_DIR` (bin path)
- `N8N_SH_BIN_NAME` (command name, default `n8nite`)
- `N8N_SH_PERSIST_RC` (`1`/`0`, enable/disable rc PATH persistence; default `1`)

Example with a custom command name:

```bash
curl -fsSL https://raw.githubusercontent.com/ARMBouhali/n8nite/main/install.sh \
  | N8N_SH_BIN_NAME=nanite bash
```

Disable rc persistence when needed:

```bash
curl -fsSL https://raw.githubusercontent.com/ARMBouhali/n8nite/main/install.sh \
  | N8N_SH_PERSIST_RC=0 bash
```

## Quick Start

### 1) Initialize an env file

Production-style template:

```bash
cp .env.example .env
```

Or generate via CLI:

```bash
./n8nite env init prod
```

Local HTTP profile:

```bash
./n8nite env init local --force
```

### 2) Validate configuration

```bash
./n8nite env check
```

Skip compose validation if Docker is not yet available:

```bash
./n8nite env check -n
```

### 3) Start services

```bash
./n8nite up
```

### 4) Check status/logs

```bash
./n8nite ps
./n8nite logs n8n
```

## CLI Usage (`n8nite`)

Show help:

```bash
./n8nite --help
```

Common commands:

```bash
./n8nite deps check
./n8nite deps check --profile nginx-https
./n8nite env check
./n8nite env keygen --write --force
./n8nite up
./n8nite down -v
./n8nite restart n8n
./n8nite doctor
```

Interactive mode:

```bash
./n8nite interactive
# or
./n8nite i
```

Useful short options:

- `-e` for `--env-file`
- `-t` for `env init --target`
- `-r` for test requirements-only
- `-f` for test functional-only

## Environment Configuration

Use one of these as the source template:

- `.env.example` for production/reverse-proxy
- `.env.local.example` for local HTTP

Required values are grouped at the top of each file.
Optional n8n tuning variables are documented at the end of each file with comments.
`N8N_ENCRYPTION_KEY` is required in this stack because main + worker must share credential encryption.
You can generate one securely with `./n8nite env keygen --write --force`.

Primary n8n env documentation:

- https://docs.n8n.io/hosting/configuration/environment-variables/

## Nginx Workflows

### Generate config only

```bash
# HTTP
./n8nite nginx generate -m http -s automation.example.com

# HTTPS
./n8nite nginx generate \
  -m https \
  -s automation.example.com \
  -c /etc/letsencrypt/live/automation.example.com/fullchain.pem \
  -k /etc/letsencrypt/live/automation.example.com/privkey.pem
```

Generated files are written to `./nginx/generated/` by default.

### Install + deploy Nginx config

```bash
./n8nite -e ./.env nginx deploy \
  -c n8n-automation \
  -u 127.0.0.1:5678 \
  -m admin@example.com
```

The deploy flow is fail-fast (`set -euo pipefail`) and includes:

1. ✅ env validation
2. 📦 dependency install (nginx/gettext, certbot for HTTPS)
3. 🔐 certificate check/creation for HTTPS
4. 📝 config generation + review prompt
5. 💾 existing nginx conf backup (timestamped) if target exists
6. 🧪 nginx validation + restart

## Testing

Run all tests:

```bash
./n8nite test
```

Functional tests only:

```bash
./n8nite test -f
```

Requirements audit only:

```bash
./n8nite test -r
```

Safety model for functional tests:

- 🧪 tests use temporary directories for env files, nginx site paths, and HOME
- 🛡️ privileged/deploy commands are mocked (`sudo`, `apt-get`, `systemctl`, `nginx`) in test scope
- 🚫 tests do not deploy to real nginx locations and do not modify your real shell rc files

### Currently Covered

- CLI help and unknown-command handling
- env init/check flow (including missing-required-variable failure)
- env validation matrix (`check-env.sh` protocol mismatch, host mismatch, placeholder failure)
- encryption key generation (`env keygen`), including `--write` force guard behavior
- dependency command wiring + profile execution matrix (`deps check` auto/core/nginx-https behavior)
- installer presence/syntax/help + rc persistence behavior in isolated HOME
- nginx config generation
- nginx deploy flow in sandboxed temp dirs (no real `/etc/nginx` writes)
- interactive mode immediate-exit flow
- compose queue service declarations (`redis`, `n8n-worker`)
- docker compose delegation for `config` and `up`

### Skipped / Not Covered Yet

- real privileged nginx deploy execution against host services (`sudo/systemctl` effects on actual machine)
- HTTPS certificate issuance path in deploy (`certbot certonly` against a real domain)
- interactive mode deep menu paths beyond immediate exit
- rendered `docker compose config --services` assertion via real docker compose runtime

## Troubleshooting

- `.env` errors ⚙️:
  - run `./n8nite env check` and fix reported variables
- Docker permission errors 🐳:
  - verify `docker` group membership or use sudo
  - run `./n8nite test -r` for suggested fixes
- Nginx deployment issues 🌐:
  - run `./n8nite nginx generate ...` first to isolate templating issues
  - validate your domain DNS before certificate creation
- Runtime visibility 📜:
  - `./n8nite logs n8n`
  - `./n8nite logs n8n-worker`
  - `./n8nite logs redis`
  - `./n8nite logs postgres`

## License

This repository is licensed under the MIT License for unrestricted usage 📄.
See [LICENSE](./LICENSE).

## References

- n8n Docker Compose setup:
  - https://docs.n8n.io/hosting/installation/server-setups/docker-compose/
- n8n environment variables:
  - https://docs.n8n.io/hosting/configuration/environment-variables/
- Docker install:
  - https://docs.docker.com/engine/install/
- Docker post-install (non-root usage):
  - https://docs.docker.com/engine/install/linux-postinstall/
- Docker Compose install:
  - https://docs.docker.com/compose/install/linux/
