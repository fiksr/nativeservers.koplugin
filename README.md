# 🚀 Native Servers for KOReader

[![KOReader](https://img.shields.io/badge/KOReader-2024%2B-blue.svg)](https://github.com/koreader/koreader)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![High Speed](https://img.shields.io/badge/Speed-15--25%20MB%2Fs-success.svg)]()
[![Storefront Compatible](https://img.shields.io/badge/Storefront-Compatible-purple.svg)](https://omer-faruq.github.io/koreader-plugin-index/)

**Native Servers** turns your KOReader device into a high-speed file transfer workstation. Run native compiled **Dropbear SSH/SFTP**, high-performance **WebDAV**, and **HTTP file servers** with line-speed wireless transfers (15–25 MB/s).

---

## ✨ Features

- ⚡ **Line-Speed Transfers (15–25 MB/s)**: Transfer gigabytes of manga, PDFs, and EPUBs over Wi-Fi at native hardware speeds without USB cables.
- 🔐 **Native Dropbear SSH & SFTP Server**:
  - One-tap start/stop on port 2222.
  - Full SFTP support for Cyberduck, WinSCP, FileZilla, and terminal ssh/scp.
  - Password and public key authentication support.
- 📁 **High-Speed WebDAV & HTTP Web Browser**:
  - Connect via Windows Explorer, macOS Finder, Linux, or mobile file managers (CX File Explorer, Solid Explorer).
  - Modern web dashboard for drag-and-drop file uploads, folder creation, and downloads directly from your phone or PC browser.
- 🌐 **Instant Network Discovery**: Displays your device\'s live Wi-Fi IP, active ports, and connection status in one glance.
- 🔋 **Battery-Safe**: Shuts down all listener sockets and daemons cleanly when toggled off or when Wi-Fi disconnects.

---

## 📸 How It Works

1. **Start Servers**: In KOReader, go to the top menu ➔ **Tools** ➔ **Native File Servers**.
2. **Toggle Services**:
   - Tap **Start WebDAV / HTTP Server** (Default port 8080).
   - Tap **Start Native Dropbear SSH / SFTP** (Port 2222).
3. **Connect from Your PC or Phone**:
   - **SFTP (Cyberduck / WinSCP)**: Connect to sftp://<device-ip>:2222
   - **WebDAV**: Connect network drive to http://<device-ip>:8080/
   - **Web Browser**: Visit http://<device-ip>:8080/ in any browser to upload books.

---

## 🚀 Installation

### Via Storefront / AppStore
1. In KOReader, go to **Tools** ➔ **App Store** (or **Storefront**).
2. Search for **Native Servers** and tap **Install**.
3. Restart KOReader.

### Manual Installation
1. Download 
ativeservers.koplugin.zip from Releases.
2. Extract to:
   - **Kindle**: /mnt/us/koreader/plugins/nativeservers.koplugin/
   - **Kobo**: .kobo/koreader/plugins/nativeservers.koplugin/
3. Restart KOReader.

---

## 📄 License

MIT License. Designed with speed for the KOReader community.
