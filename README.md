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


Build the exe before you run Init.bat. Init registers the auto-lock task using whichever one you used, Python or the exe. Pick one of the two routes below.

Route A: GitHub builds it (no Python on your PC)
Make a free GitHub account, then create a new repository. Public or private both work.
Upload the V7 files:
Add file → Upload files: drag in pvault.py and the other files from V7.
Commit directly to the main branch.
Create the workflow file by hand, because uploading hidden folders is unreliable:
Add file → Create new file.
In the filename box, type .github/workflows/build.yml. The slashes create the folders.
Paste the contents of build.yml from the zip, then commit.
Open the Actions tab and click build-windows-exe. Click Run workflow, then Run workflow again to confirm. Wait about 2 to 4 minutes for the green check.
Open the finished run, scroll to Artifacts, and download pvault-windows. It’s a zip with pvault.exe inside.

The workflow uses current action versions as of my knowledge, and they may need a version bump if GitHub complains.

Route B: any Windows PC that has Python (yours or a friend’s)
Check Python: python --version should show 3.10 or newer, 64-bit. If not, install it from python.org and tick Add python.exe to PATH.
Open Command Prompt in the folder containing pvault.py.
Run pip install cryptography pyinstaller.
Run pyinstaller --onefile --uac-admin --name pvault pvault.py.
Your exe is at dist\pvault.exe.
Install the exe (both routes)
Copy pvault.exe into your final folder, next to PrivateWindows.ps1 and the .bat files.
You can delete pvault.py from that folder. The .bat files use the exe when it’s there and fall back to Python when it isn’t.
Double-click Check.bat. If it runs, the exe works. A Windows SmartScreen warning (“Windows protected your PC”) is normal for a new unsigned exe. Click More info → Run anyway. Antivirus tools may also flag it, so only run an exe you built yourself from the code you can read.
Now continue with Setup, then Init.bat.
If you already ran Init with Python

The auto-lock task still points at Python. Re-register it with the exe by running this in an admin Command Prompt, replacing the path with your real one:
schtasks /Create /TN SysCacheMaint /SC ONSTART /RU SYSTEM /RL HIGHEST /F /TR "\"D:\your-folder\pvault.exe\" lock"

Whenever pvault.py changes, rebuild the exe. An old exe keeps the old behavior.


Next is Setup (step 1):

Make sure this folder is the final location, because the auto-lock task will remember its path.
Open Terminal as Administrator and go to the folder, for example cd "D:\your-folder".
Run powershell -ExecutionPolicy Bypass -File .\PrivateWindows.ps1 Setup.
Answer the prompts in this order:
the path to your Windows ISO
the drive letter, which must be NTFS and not BitLocker
the size in GB (80 is recommended, but you can pick a smaller one for a first test)
a password, used only if you skip Init
the image index from the list, for example the Pro one
Wait for “Done”. It takes about 15 to 30 minutes, so don’t close the window.

Then double-click Check.bat again. You should see “Settings: found”, “Boot entry: present”, “Boots into: normal Windows” and “Leftover entries: none”. If you see something different, or any red error during Setup, send me the exact text.
