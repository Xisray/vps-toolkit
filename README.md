<div align="center">
```
██╗   ██╗██████╗ ███████╗    ████████╗ ██████╗  ██████╗ ██╗     ██╗  ██╗██╗████████╗
██║   ██║██╔══██╗██╔════╝    ╚══██╔══╝██╔═══██╗██╔═══██╗██║     ██║ ██╔╝██║╚══██╔══╝
██║   ██║██████╔╝███████╗       ██║   ██║   ██║██║   ██║██║     █████╔╝ ██║   ██║   
╚██╗ ██╔╝██╔═══╝ ╚════██║       ██║   ██║   ██║██║   ██║██║     ██╔═██╗ ██║   ██║   
 ╚████╔╝ ██║     ███████║       ██║   ╚██████╔╝╚██████╔╝███████╗██║  ██╗██║   ██║   
  ╚═══╝  ╚═╝     ╚══════╝       ╚═╝    ╚═════╝  ╚═════╝ ╚══════╝╚═╝  ╚═╝╚═╝   ╚═╝  
```
 
**A collection of hardening & deployment scripts for VPS servers**
 
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
![Shell](https://img.shields.io/badge/Shell-Bash-4EAA25?logo=gnubash&logoColor=white)
![Platform](https://img.shields.io/badge/Platform-Linux-FCC624?logo=linux&logoColor=black)
 
</div>

---
 
## 📦 Scripts
 
### 🔒 `server-security.sh`
 
Hardens your VPS with a single command — configures firewall rules, SSH settings, and core system protections.
 
```bash
bash <(curl -s https://raw.githubusercontent.com/Xisray/vps-toolkit/refs/heads/main/server-security.sh)
```
 
---
 
### ⚡ `xui-pro.sh`
 
Installs and configures X-UI Pro panel with automated SSL certificate issuance.

> Based on the original script by [**@mozaroc**](https://github.com/mozaroc) — thanks for the groundwork! 🙏
 
```bash
bash <(curl -s https://raw.githubusercontent.com/Xisray/vps-toolkit/refs/heads/main/xui-pro.sh)
```
 
---
 
## ⚠️ Requirements
 
- OS: **Ubuntu 22.04 / 24.04** or **Debian 11 / 12**
- Access: **root** or `sudo`
- Ports **80** and **443** must be open and free before running
---
 
## 🚀 Quick Start
 
```bash
# 1. Secure the server first
bash <(curl -s https://raw.githubusercontent.com/Xisray/vps-toolkit/refs/heads/main/server-security.sh)
 
# 2. Then deploy X-UI Pro
bash <(curl -s https://raw.githubusercontent.com/Xisray/vps-toolkit/refs/heads/main/xui-pro.sh)
```
 
---
 
<div align="center">
  <sub>Made with ☕ by <a href="https://github.com/Xisray">Xisray</a></sub>
</div>
