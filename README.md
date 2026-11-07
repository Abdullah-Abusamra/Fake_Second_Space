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
