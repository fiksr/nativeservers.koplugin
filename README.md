# 🚀 Native Servers for KOReader

[![KOReader](https://img.shields.io/badge/KOReader-2024%2B-blue.svg)](https://github.com/koreader/koreader)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![High Speed](https://img.shields.io/badge/Speed-15--25%20MB%2Fs-success.svg)]()
[![Storefront Compatible](https://img.shields.io/badge/Storefront-Compatible-purple.svg)](https://omer-faruq.github.io/koreader-plugin-index/)

**Native Servers** turns your KOReader device into a high-speed file transfer workstation. Run native compiled **Dropbear SSH/SFTP**, high-performance **WebDAV**, and an **HTTP Web Browser file manager** with line-speed wireless transfers (15–25 MB/s).

---

## ✨ Features

- ⚡ **Line-Speed Wireless Transfers (15–25 MB/s)**: Transfer gigabytes of manga, PDFs, and EPUBs over Wi-Fi at native hardware speeds without USB cables.
- 📁 **High-Speed WebDAV & HTTP Web Browser (Zero Setup)**:
  - **Works out of the box** with zero extra binaries or dependencies!
  - Drag-and-drop file upload web dashboard directly in your PC or phone browser (`http://<kindle-ip>:8080`).
  - Map network drives in Windows Explorer, macOS Finder, or mobile file managers (CX File Explorer, Solid Explorer).
- 🔐 **Native Dropbear SSH & SFTP Server**:
  - One-tap start/stop on port `2222`.
  - Full SFTP file management for Cyberduck, WinSCP, FileZilla, and terminal `ssh`/`scp`.
  - Automatically manages iptables firewall punch-through and displays your live IP and connection details.
- 🔋 **Battery-Safe**: Shuts down all listeners cleanly when toggled off or when Wi-Fi disconnects.

---

## 🚀 Installation & Setup

### Step 1: Install the Plugin in KOReader

#### Option A: Via App Store / Storefront
1. In KOReader, go to **Tools** ➔ **App Store** (or **Storefront**).
2. Search for **Native Servers** and tap **Install**.
3. Restart KOReader.

#### Option B: Manual Installation
1. Download `nativeservers.koplugin.zip` from [Releases](https://github.com/fiksr/nativeservers.koplugin/releases).
2. Extract the folder to:
   - **Kindle**: `/mnt/us/koreader/plugins/nativeservers.koplugin/`
   - **Kobo**: `.kobo/koreader/plugins/nativeservers.koplugin/`
3. Restart KOReader.

---

### Step 2: Dropbear SSH / SFTP Setup (Kindle Prerequisites)

> [!NOTE]
> **WebDAV and the HTTP Web Browser upload dashboard require NO extra tools** — they work immediately out of the box!
> 
> For **SSH and SFTP (port 2222)**, your jailbroken Kindle needs the native **Dropbear** binary installed on the device.

If you don't already have Dropbear installed on your Kindle, choose one of these quick 1-minute methods:

#### Method A: Via KPM (Recommended for Modern Jailbreaks — LanguageBreak / WinterBreak / Adbreak)
1. In your Kindle terminal or KUAL, run:
   ```sh
   kpm add-repo https://nealing.net/manifest.json
   kpm install dropbear-ssh
   ```
2. *(Or copy `dropbear-ssh.sh` to your Kindle root and run it once via KUAL)*.
3. Native Servers will automatically detect Dropbear and manage starting/stopping it on port 2222!

#### Method B: Via USBNetwork (MobileRead)
* If you have the MobileRead **USBNetwork** or **`usbnetlite`** package installed, Native Servers automatically detects and controls `/mnt/us/usbnet/bin/dropbear` or `/mnt/us/usbnetlite/bin/dropbear`.

#### Method C: Standalone Dropbear Binary
* Simply copy any compiled ARM `dropbear` binary to `/mnt/us/koreader/dropbear`.

---

## 📸 How to Use

1. In KOReader, open the top menu ➔ **Tools** ➔ **More tools** ➔ **Native File Servers**.
2. **Toggle Services**:
   - Tap **Start WebDAV / HTTP Server** (Default port `8080`).
   - Tap **Start Native Dropbear SSH / SFTP** (Default port `2222`).
3. **Connect from PC or Mobile**:
   - **Web Browser**: Open `http://<your-device-ip>:8080/` in any browser to drag-and-drop books.
   - **WebDAV**: Connect network drive to `http://<your-device-ip>:8080/`.
   - **SFTP (Cyberduck / WinSCP / FileZilla)**: Connect to `sftp://<your-device-ip>:2222` (Username: `root`).

---

## 📄 License

MIT License. Designed with speed for the KOReader community.
