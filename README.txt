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

Install:
  sudo bash prometheon_wizard.sh install

Update:
  sudo bash prometheon_wizard.sh update [version]

Uninstall:
  sudo bash prometheon_wizard.sh uninstall

Interactive menu (auto-detects installed status):
  sudo bash prometheon_wizard.sh
