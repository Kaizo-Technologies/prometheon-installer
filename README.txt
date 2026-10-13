Prometheon Installer
====================

Contents:
  prometheon_wizard.sh   - All-in-one installer, updater, and uninstaller
                           (docker-compose, nginx.conf, and init.sql are
                            embedded inside — ship this one file to the client)

Requirements:
  - Ubuntu 24.04 LTS
  - Minimum 4 GB RAM, 20 GB free disk
  - Ports 80 and 443 available
  - Docker Hub pull token (provided by vendor)

Quick start (on the server):
  curl -fsSL https://raw.githubusercontent.com/Kaizo-Technologies/prometheon-installer/main/prometheon_wizard.sh -o prometheon_wizard.sh
  sudo bash prometheon_wizard.sh install

Defaults: Prometheon 1.6, Asterisk andrius/asterisk:22.11.0 (pinned).
This file is a copy of installer/prometheon_wizard.sh in the prometheon-1 repo;
update both together.

Install:
  sudo bash prometheon_wizard.sh install

Update:
  sudo bash prometheon_wizard.sh update [version]

Uninstall:
  sudo bash prometheon_wizard.sh uninstall

Interactive menu (auto-detects installed status):
  sudo bash prometheon_wizard.sh
