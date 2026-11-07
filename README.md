# Private Windows

A second, separate Windows that lives in one `.vhdx` file on your own PC. It boots natively - no VM, no extra Windows account.
Its boot entry is hidden from the boot menu, and the disk can be kept encrypted at rest with open-source crypto (no BitLocker).

## Files (keep them all in ONE folder)
| File | What it is |
|---|---|
| `PrivateWindows.ps1` | Creates the private Windows and controls booting |
| `pvault.py` / `pvault.exe` | Encrypts/decrypts the disk (AES-256-GCM, X25519, scrypt). The exe needs no Python |
| `Init.bat` `Switch.bat` `Stay.bat` `Mount.bat` `Unmount.bat` `Remove.bat` `Check.bat` `Clean.bat` `Passwd.bat` | Double-click launchers (use `pvault.exe` if present, otherwise Python) |

## First time
1. Admin PowerShell: `powershell -ExecutionPolicy Bypass -File .\PrivateWindows.ps1 Setup` (needs a Windows ISO, free space, an NTFS drive that is not BitLocker-encrypted)
2. `Init.bat` - choose a passphrase; the disk is encrypted and an auto-lock task is installed
3. Python only: `pip install cryptography`. No Python: build the exe (`pyinstaller --onefile --uac-admin --name pvault pvault.py`, or the GitHub workflow in `.github/workflows/build.yml`)

## Daily use
- **Switch** - passphrase, decrypt, boot into the private Windows once. Restart = back to normal.
- **Stay** - keep booting into it until you run "Back to main Windows" (a file on its desktop). Do not unplug the drive meanwhile.
- **Mount / Unmount** - browse the private disk's files from normal Windows / encrypt again.
- **Check** - shows the state and finds leftover boot entries. **Clean** (`Clean.bat`) deletes them (done automatically on Switch/Stay/Mount).
- **Passwd** - change the passphrase. **Remove** - deletes everything, restores normal boot first if Stay was on, removes the auto-lock task.

## Know the limits
- While you are inside the private Windows the disk is **not** encrypted (the boot manager cannot read an encrypted VHDX). It is re-encrypted automatically at the next normal startup.
- Deleted files are not wiped; leftovers can remain on the drive until overwritten (SSD/HDD).
- A forgotten passphrase cannot be recovered. `sc.dat` already contains the passphrase-protected key - back it up.
- Anyone with admin rights on your normal Windows can still see that a boot entry/file exists. This hides it from casual users; it is not protection against a determined technical person.
- Not tested on every Windows build. Keep the BCD backup the script saves in `C:\ProgramData\SysCache` until you trust the setup.

## Emergency: folder locked or leftover state (admin Command Prompt, use your drive letter)
    takeown /F D:\SysCache /A /R /D Y
    icacls D:\SysCache /grant *S-1-5-32-544:(OI)(CI)F /T


# Private Windows — Setup Guide

## 1. Create it

**File:** `PrivateWindows.ps1` (the only step without a `.bat`)

Open Terminal as Administrator, go to the folder, and run:

```
powershell -ExecutionPolicy Bypass -File .\PrivateWindows.ps1 Setup
```

Answer the prompts:

- ISO path
- Drive letter
- Size (80 GB is recommended)
- A password (only used if you skip step 3, so choose one you'll remember)
- The image index

Wait until it prints **"Done"** (15 to 30 minutes).

---

## 2. Check it

**File:** `Check.bat`

You should see:

- "Settings: found"
- "Boot entry: present"
- "Boots into: normal Windows"
- "Leftover entries: none"

---

## 3. Encrypt it

**File:** `Init.bat`

Choose a passphrase twice. It encrypts the disk, verifies it, and installs the auto-lock task.

> **Write the passphrase down, because it can't be recovered.**

---

## 4. Enter it

**File:** `Switch.bat`

Enter your passphrase and it decrypts the disk (a few minutes). Save your work, type `Y`, and the PC restarts straight into the private Windows.

> The first time, it runs Windows first-time setup.

---

## 5. Leave it

**No file needed.**

Restart normally (Start, then Restart). Your normal Windows starts, and the auto-lock task re-encrypts the disk in the background.

After a few minutes, `Check.bat` should say **"Disk file: not visible (locked or encrypted - normal)"**.

---

## 6. Optional: stay in it

**File:** `Stay.bat`

It works like Switch, but every boot goes into the private Windows.

To return, double-click **"Back to main Windows.bat"** on the private Windows' desktop, then type `Y`.

> **Don't unplug the drive while Stay is on.**

---

## 7. Browse its files

**Files:** `Mount.bat`, then `Unmount.bat`

- `Mount.bat` asks your passphrase, mounts the disk and opens it. Windows may ask permission to open some folders, so click **Continue**.
- `Unmount.bat` closes it and encrypts it again.

---

## 8. Maintenance

**Files:** `Check.bat`, `Clean.bat`, `Passwd.bat`

| File | What it does |
| --- | --- |
| `Check.bat` | Shows the state. |
| `Clean.bat` | Deletes leftover boot entries. |
| `Passwd.bat` | Changes the passphrase. |

---

## 9. Delete everything

**File:** `Remove.bat`

Run it from your **normal Windows, not the private one**. Enter your passphrase and type `YES`, then restart the PC.

Afterwards, `Check.bat` should say **"Settings: missing"**.

---

## Rules

- **Never delete `sc.vhdx` or `sc.dat` by hand.** Use `Remove.bat`.
- **Don't mix files from different versions.**
