# Wi-Fi Aware Auto-Login & Auto-Lock for Ubuntu (MacBook-friendly)

Make Ubuntu **auto-login only on trusted Wi-Fi** SSIDs, and **auto-lock when you leave** them (with a debounce so quick switches don’t lock you out). Includes helper commands to add/remove trusted SSIDs on the fly.

---

## ✨ What it does

- **Conditional auto-login (GDM/Ubuntu):**  
  - On boot, if you’re on a **trusted SSID**, GDM auto-logs into your user.  
  - Otherwise, you stay at the **login screen**.

- **Auto-lock on disconnect (debounced):**  
  - If you leave a trusted SSID, we **wait N seconds** (default 7).  
  - If you reconnect to a trusted SSID within that window → **no lock**.  
  - If not → **lock session**.

- **Simple helpers:**  
  - `trustssid` → trust your **current** Wi-Fi SSID  
  - `listtrusted` → list trusted SSIDs  
  - `untrustssid "SSID"` → remove one

---

## 🧠 How it works (high-level)

```
           Boot
             │
     [systemd unit runs]
             │   reads /etc/trusted-ssids.conf
             ▼   waits up to 30s for Wi-Fi
       toggle-gdm-autologin.sh
        ├── On trusted SSID → set GDM AutomaticLoginEnable=true
        └── Else            → set GDM AutomaticLoginEnable=false
             │
             ▼
     GDM greeter decides auto-login or not

Network changes (connect/disconnect)
             │
 NetworkManager dispatcher hook
             ▼
       ssid-lock-guard.sh
        ├── If trusted → do nothing
        └── If not trusted → wait N sec → recheck
                ├── now trusted → do nothing
                └── still untrusted → lock sessions
```

---

## ✅ Requirements

- Ubuntu/Debian with GDM (default Ubuntu Desktop)
- `network-manager` and `crudini` (installed by the script)
- Saved Wi-Fi profiles (the installer can mark them “available to all users” so greeter can connect pre-login)

---

## 🚀 Install

### Interactive (recommended)
```bash
curl -fsSL https://raw.githubusercontent.com/<you>/<repo>/main/install.sh | sudo bash
```

The wizard will ask:
- **Y** to Install / **N** to Cancel / **U** to Uninstall  
- Use **current user** (detected) or enter another username  
- Trust **current SSID** (detected) and/or add others  
- Set **debounce** seconds (default 7)

### Non-interactive (advanced)
```bash
curl -fsSL https://raw.githubusercontent.com/<you>/<repo>/main/install.sh \
| sudo bash -s -- --install --user cam --ssids "HomeWiFi,OfficeWiFi" --debounce 7
```

> You can re-run the installer any time to change settings.

---

## 🧩 Files the installer creates

- **Config**
  - `/etc/trusted-ssids.conf` — one SSID per line (case-sensitive)
  - `/etc/gdm3/custom.conf` — GDM auto-login toggled at boot

- **Scripts**
  - `/usr/local/sbin/toggle-gdm-autologin.sh` — runs **before GDM** starts
  - `/usr/local/bin/ssid-lock-guard.sh` — locks on untrusted SSID (debounced)
  - `/usr/local/bin/trustssid` — add current SSID
  - `/usr/local/bin/listtrusted` — list SSIDs
  - `/usr/local/bin/untrustssid` — remove SSID

- **System hooks**
  - `systemd` unit: `/etc/systemd/system/conditional-gdm-autologin.service`
  - NetworkManager dispatcher: `/etc/NetworkManager/dispatcher.d/90-ssid-lock-guard`

- **Logs**
  - `/var/log/conditional-gdm.log` — boot-time toggle logs
  - `/var/log/ssid-lock-guard.log` — lock guard logs

---

## 🔧 Usage

### Add current Wi-Fi to trusted
```bash
trustssid
```

### List all trusted SSIDs
```bash
listtrusted
```

### Remove a trusted SSID
```bash
untrustssid "SSID Name"
```

### Edit the list manually
```bash
sudo nano /etc/trusted-ssids.conf
# one SSID per line, no quotes
```

### Change debounce time (default 7 seconds)
Edit the script header:
```bash
sudo nano /usr/local/bin/ssid-lock-guard.sh
# DEBOUNCE_SECONDS=7  ← change this
```
(or re-run the installer and set a new value)

---

## 🔍 Verifying it works

- **At boot on a trusted SSID:** machine should **auto-login** to your user.
- **At boot offline / other SSID:** machine should **stay at the GDM login screen**.
- **While logged in on trusted SSID:** disconnect/switch Wi-Fi → waits **N seconds** →  
  - if reconnected to trusted within N → **no lock**  
  - if not → **locks**

Check logs:
```bash
sudo journalctl -u conditional-gdm-autologin.service -b --no-pager
sudo tail -n 100 /var/log/conditional-gdm.log
sudo tail -n 100 /var/log/ssid-lock-guard.log
```

---

## 🧰 Troubleshooting

- **“It doesn’t auto-login even on trusted Wi-Fi”**
  - Ensure the Wi-Fi profile is **available to all users** so greeter can connect pre-login:  
    ```bash
    nmcli connection modify "YourSSID" connection.permissions "" connection.autoconnect yes
    nmcli radio wifi on
    ```
  - Give the boot script more time (change 30s wait loop in `toggle-gdm-autologin.sh`).

- **Service ordering**
  - The unit must run **Before** `gdm3.service`:
    ```bash
    systemctl cat conditional-gdm-autologin.service
    ```

- **Check config syntax**
  - `/etc/gdm3/custom.conf` must be simple and valid:
    ```ini
    [daemon]
    AutomaticLoginEnable=false
    AutomaticLogin=youruser
    ```

- **Helpers not found**
  - Ensure `/usr/local/bin` is in `PATH`:
    ```bash
    echo $PATH
    # add to ~/.bashrc if missing:
    echo 'export PATH="/usr/local/bin:$PATH"' >> ~/.bashrc && source ~/.bashrc
    ```

---

## 🗑️ Uninstall

Interactive:
```bash
curl -fsSL https://raw.githubusercontent.com/<you>/<repo>/main/install.sh | sudo bash
# choose U to uninstall
```

Non-interactive:
```bash
curl -fsSL https://raw.githubusercontent.com/<you>/<repo>/main/install.sh | sudo bash -s -- --uninstall
```

What it removes:
- systemd unit, dispatcher hook, scripts, logs  
- keeps `/etc/trusted-ssids.conf` (your data) — remove manually if desired

---

## 🔐 Security notes

- Auto-login is **only** enabled on SSIDs you’ve explicitly trusted.  
- When you leave a trusted SSID, sessions **auto-lock** (after debounce).  
- Anyone on a trusted SSID who can physically access your machine at boot could get auto-login; use disk encryption and lock on suspend as additional layers.

---

## ❓FAQ

**Q: Can I trust Ethernet at home too?**  
A: Yes — you can extend `toggle-gdm-autologin.sh` and `ssid-lock-guard.sh` to treat your home LAN (e.g., default gateway MAC or subnet) as trusted. Open an issue or PR and we’ll add an example.

**Q: GNOME vs other desktops?**  
A: This targets GNOME/GDM. Other DMs (SDDM/LightDM) need different toggle logic.

**Q: Will this break system updates?**  
A: No. It writes standard files and systemd units. Re-running the installer updates them cleanly.

---

## 🧾 One-liner recap

Interactive:
```bash
curl -fsSL https://raw.githubusercontent.com/<you>/<repo>/main/install.sh | sudo bash
```

Non-interactive:
```bash
curl -fsSL https://raw.githubusercontent.com/<you>/<repo>/main/install.sh \| sudo bash -s -- --install --user cam --ssids "HomeWiFi,OfficeWiFi" --debounce 7
```

Uninstall:
```bash
curl -fsSL https://raw.githubusercontent.com/<you>/<repo>/main/install.sh | sudo bash -s -- --uninstall
```
