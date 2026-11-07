<#
 Private Windows - a second, separate Windows in a .vhdx file (native boot: no VM, no account).
 The boot entry is NOT in the boot menu. "Switch" asks a password, boots it once, and the
 next normal restart returns to your main Windows.

 Run as admin:
   powershell -ExecutionPolicy Bypass -File .\PrivateWindows.ps1 Setup    (once)
   powershell -ExecutionPolicy Bypass -File .\PrivateWindows.ps1 Switch   (every time)
   powershell -ExecutionPolicy Bypass -File .\PrivateWindows.ps1 Remove   (deletes everything)
   powershell -ExecutionPolicy Bypass -File .\PrivateWindows.ps1 Check    (shows the state, finds leftovers)
   powershell -ExecutionPolicy Bypass -File .\PrivateWindows.ps1 Clean    (deletes leftover boot entries)
#>
param([ValidateSet('Setup','Switch','Stay','Back','Mount','Unmount','Remove','Check','Clean')][string]$Mode = 'Switch', [switch]$Elevated, [switch]$Unlocked)   # -Unlocked: pvault.py already checked the passphrase
# Stay   = from main Windows: every boot goes to the private Windows until you run Back
# Back   = from inside the private Windows: boot into the main Windows again
$ErrorActionPreference = 'Stop'
$rc = 0   # exit code 42 = PC is restarting into the private Windows

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    if ($Elevated) {
        Write-Host 'Could not get admin rights. Open Terminal as Administrator and run the script again.' -ForegroundColor Red
        Read-Host 'Press Enter to close' | Out-Null
        exit
    }
    Start-Process powershell -Verb RunAs -ArgumentList "-ExecutionPolicy Bypass -File `"$PSCommandPath`" $Mode -Elevated"
    exit
}

$BootName = 'Windows Servicing'                       # what the hidden boot entry is called
$CfgDir   = Join-Path $env:ProgramData 'SysCache'
$CfgFile  = Join-Path $CfgDir 'pc.json'

function Run { & $args[0] @($args[1..($args.Count - 1)]) | Out-Host; if ($LASTEXITCODE -ne 0) { throw "$($args[0]) failed (exit $LASTEXITCODE)" } }
function Plain($s) { [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)) }
function Get-Pw([string]$pw, [byte[]]$salt) {
    [Convert]::ToBase64String([Security.Cryptography.Rfc2898DeriveBytes]::new($pw, $salt, 200000, [Security.Cryptography.HashAlgorithmName]::SHA256).GetBytes(32))
}
function Test-Pw($c) {
    if ($Unlocked) { return $true }
    $pw = Plain (Read-Host 'Password' -AsSecureString)
    if ((Get-Pw $pw ([Convert]::FromBase64String($c.salt))) -eq $c.hash) { return $true }
    Start-Sleep 2
    return $false
}
function Quiet { & $args[0] @($args[1..($args.Count - 1)]) | Out-Null; if ($LASTEXITCODE -ne 0) { throw "$($args[0]) failed (exit $LASTEXITCODE)" } }
function Unlock-Vhd($vhd) {   # give Administrators access to the folder again
    $dir = Split-Path $vhd
    Quiet takeown /F $dir /A /R /D Y
    Quiet icacls $dir /grant '*S-1-5-32-544:(OI)(CI)F' /T
}
function Lock-Vhd($vhd) {     # only SYSTEM (and the boot loader) can touch the folder
    $dir = Split-Path $vhd
    Quiet icacls $dir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F'
    Quiet icacls $dir /remove:g '*S-1-5-32-544'
}
function Open-Gate($c) {      # unlocks if locked; returns $true when the caller should re-lock afterwards
    $locked = (Exists ([IO.Path]::GetPathRoot($c.vhd))) -and -not (Exists $c.vhd)
    if ($locked) { Unlock-Vhd $c.vhd }
    return $locked
}
function Exists($p) { try { [bool](Test-Path -LiteralPath $p -ErrorAction SilentlyContinue) } catch { $false } }
function Row($k, $v) { Write-Host ('{0,-18}{1}' -f $k, $v) }
function Get-MainEntry {      # your normal Windows boot entry (on a real partition, not a VHD, not recovery)
    $main = foreach ($b in ((bcdedit /enum osloader /v | Out-String) -split '(?m)^-{5,}\s*$')) {
        $id   = [regex]::Match($b, '(?m)^identifier\s+(\{[0-9a-fA-F\-]{36}\})').Groups[1].Value
        $dev  = [regex]::Match($b, '(?m)^device\s+(.+?)\s*$').Groups[1].Value
        $desc = [regex]::Match($b, '(?m)^description\s+(.+?)\s*$').Groups[1].Value
        if ($id -and $dev -like 'partition=*' -and $desc -notmatch 'Recovery') { $id }
    }
    return @($main)[0]
}
function Reset-Boot {         # make your normal Windows the default again
    $main = Get-MainEntry
    if (-not $main) { throw 'Could not find your main Windows boot entry.' }
    Run bcdedit /default $main
    Run bcdedit /displayorder $main
}
function Clear-Leftovers([string]$keep) {   # delete boot entries that point into sc.vhdx (the private Windows' own recovery entries)
    $cur = [regex]::Match((bcdedit /enum '{current}' /v | Out-String), '(?m)^identifier\s+(\{[0-9a-fA-F\-]{36}\})').Groups[1].Value
    foreach ($b in ((bcdedit /enum all /v | Out-String) -split '(?m)^-{5,}\s*$')) {
        if ($b -match 'SysCache\\sc\.vhdx') {
            $id = [regex]::Match($b, '(?m)^identifier\s+(\{[0-9a-fA-F\-]{36}\})').Groups[1].Value
            if ($id -and $id -ne $keep -and $id -ne $cur) { bcdedit /delete $id /cleanup | Out-Null; Write-Host "Removed leftover boot entry $id" }
        }
    }
}

try {
    if ($Mode -eq 'Setup') {
        if (Test-Path $CfgFile) { throw 'Already set up. Run Remove first.' }
        $iso   = (Read-Host 'Path to a Windows 10/11 ISO').Trim('"')
        $drive = (Read-Host 'Drive letter to store it on (NTFS, not BitLocker), e.g. D').Trim().TrimEnd(':').ToUpper()
        $gb    = [int](Read-Host 'Size in GB (fixed, taken immediately; 80 recommended)')
        $pw1   = Plain (Read-Host 'Choose a password (used in plain mode; with pvault encryption you choose a passphrase later in Init)' -AsSecureString)

        $vol = Get-Volume -DriveLetter $drive
        if ($vol.FileSystem -ne 'NTFS') { throw "$drive`: must be NTFS." }
        if ($vol.SizeRemaining -lt ($gb + 5) * 1GB) { throw "Not enough free space on $drive`:." }
        try { $bl = (manage-bde -status "${drive}:" | Out-String) } catch { $bl = '' }
        if ($bl -match 'Fully Encrypted|Encryption in Progress|Protection On') {
            throw "$drive`: is BitLocker-encrypted. A native-boot VHDX cannot live on it. Use another drive/partition."
        }

        New-Item -ItemType Directory $CfgDir -Force | Out-Null
        Run bcdedit /export (Join-Path $CfgDir "bcd-$(Get-Date -Format yyyyMMdd-HHmmss).bak")   # your safety net

        $dir = "${drive}:\SysCache"
        New-Item -ItemType Directory $dir -Force | Out-Null
        attrib +h +s $dir
        $vhd = "$dir\sc.vhdx"

        Mount-DiskImage -ImagePath $iso | Out-Null
        $isoDrive = (Get-DiskImage -ImagePath $iso | Get-Volume).DriveLetter
        $wim = "${isoDrive}:\sources\install.wim"
        if (-not (Test-Path $wim)) { $wim = "${isoDrive}:\sources\install.esd" }
        Get-WindowsImage -ImagePath $wim | Format-Table ImageIndex, ImageName -AutoSize | Out-Host
        $idx = [int](Read-Host 'Image index to install (e.g. the Pro one)')

        $letter = 90..68 | ForEach-Object { [char]$_ } | Where-Object { -not (Test-Path "${_}:\") } | Select-Object -First 1
        $script = @"
create vdisk file="$vhd" maximum=$($gb * 1024) type=fixed
select vdisk file="$vhd"
attach vdisk
create partition primary
format quick fs=ntfs label="System"
assign letter=$letter
"@
        $f = (New-TemporaryFile).FullName
        Set-Content $f $script -Encoding ASCII
        Write-Host 'Creating the virtual disk (can take several minutes)...'
        Run diskpart /s $f

        Write-Host 'Installing Windows into it (can take 10+ minutes)...'
        Run dism /Apply-Image "/ImageFile:$wim" "/Index:$idx" "/ApplyDir:${letter}:\"

        Set-Content $f "select vdisk file=`"$vhd`"`ndetach vdisk" -Encoding ASCII
        Run diskpart /s $f
        Dismount-DiskImage -ImagePath $iso | Out-Null

        $out = bcdedit /copy '{current}' /d $BootName | Out-String
        if ($out -match '\{[0-9a-fA-F\-]{36}\}') { $guid = $Matches[0] } else { throw "Could not create the boot entry: $out" }
        $v = "vhd=[${drive}:]\SysCache\sc.vhdx"
        Run bcdedit /set $guid device $v
        Run bcdedit /set $guid osdevice $v
        Run bcdedit /set $guid detecthal on
        Run bcdedit /displayorder $guid /remove          # hides it from the boot menu

        $salt = [byte[]]::new(16)
        [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($salt)
        @{ guid = $guid; vhd = "${drive}:\SysCache\sc.vhdx"; salt = [Convert]::ToBase64String($salt); hash = (Get-Pw $pw1 $salt) } |
            ConvertTo-Json | Set-Content $CfgFile
        attrib +h +s $CfgDir
        Lock-Vhd $vhd
        Write-Host "`nDone. The private disk is locked. Run Switch to try it. First boot takes several minutes (Windows first-time setup)."
    }
    elseif ($Mode -eq 'Switch') {
        if (Test-Path $CfgFile) {
            $c  = Get-Content $CfgFile -Raw | ConvertFrom-Json
            if (Test-Pw $c) {
                Clear-Leftovers $c.guid
                $was = Open-Gate $c
                if (-not (Exists $c.vhd)) { throw 'The drive holding the private Windows is not connected.' }
                $go = (Read-Host 'This restarts your PC right now. Save your work first. Type Y to continue') -eq 'Y'
                try { if ($go) { Run bcdedit /bootsequence $c.guid } } finally { if ($was) { Lock-Vhd $c.vhd } }
                if ($go) { $rc = 42; Restart-Computer -Force }
            } else { Start-Sleep 2 }
        }
    }
    elseif ($Mode -eq 'Stay') {
        if (Test-Path $CfgFile) {
            $c = Get-Content $CfgFile -Raw | ConvertFrom-Json
            if (Test-Pw $c) {
                Clear-Leftovers $c.guid
                $was = Open-Gate $c
                if (-not (Exists $c.vhd)) { throw 'The drive holding the private Windows is not connected.' }
                $cur = [regex]::Match((bcdedit /enum '{current}' /v | Out-String), 'identifier\s+(\{[0-9a-fA-F\-]{36}\})').Groups[1].Value
                if ($cur -eq $c.guid) { throw 'You are already inside the private Windows. Use Back to return.' }

                # put the "Back" tools inside the private Windows
                Mount-DiskImage -ImagePath $c.vhd | Out-Null
                try {
                    $pv = Get-DiskImage -ImagePath $c.vhd | Get-Disk | Get-Partition | Get-Volume | Where-Object DriveLetter | Select-Object -First 1
                    if (-not $pv) { throw 'Could not open the private disk.' }
                    $root  = "$($pv.DriveLetter):"
                    $tools = "$root\ProgramData\SysCache"
                    $desk  = "$root\Users\Public\Desktop"
                    New-Item -ItemType Directory $tools, $desk -Force | Out-Null
                    Copy-Item $PSCommandPath "$tools\PrivateWindows.ps1" -Force
                    Set-Content "$desk\Back to main Windows.bat" '@echo off', 'powershell -ExecutionPolicy Bypass -File "%ProgramData%\SysCache\PrivateWindows.ps1" Back' -Encoding ASCII
                } finally { Dismount-DiskImage -ImagePath $c.vhd | Out-Null }

                $go = (Read-Host 'From now on EVERY boot goes to the private Windows until you run Back. Save your work first. Type Y to restart now') -eq 'Y'
                try { if ($go) { Run bcdedit /default $c.guid; Run bcdedit /displayorder $c.guid } } finally { if ($was) { Lock-Vhd $c.vhd } }
                if ($go) { $rc = 42; Restart-Computer -Force }
            }
        }
    }
    elseif ($Mode -eq 'Back') {
        Reset-Boot
        if ((Read-Host 'Main Windows is the default again. Type Y to restart now') -eq 'Y') { Restart-Computer -Force }
    }
    elseif ($Mode -eq 'Mount') {
        if (Test-Path $CfgFile) {
            $c = Get-Content $CfgFile -Raw | ConvertFrom-Json
            if (Test-Pw $c) {
                Clear-Leftovers $c.guid
                Open-Gate $c | Out-Null
                if (-not (Exists $c.vhd)) { throw 'The drive holding the private Windows is not connected.' }
                Mount-DiskImage -ImagePath $c.vhd | Out-Null
                $pv = Get-DiskImage -ImagePath $c.vhd | Get-Disk | Get-Partition | Get-Volume | Where-Object DriveLetter | Select-Object -First 1
                if ($pv) { Write-Host "Mounted as $($pv.DriveLetter): - run Unmount when you are done."; explorer "$($pv.DriveLetter):\" }
            }
        }
    }
    elseif ($Mode -eq 'Unmount') {
        if (Test-Path $CfgFile) {
            $c = Get-Content $CfgFile -Raw | ConvertFrom-Json
            try { Dismount-DiskImage -ImagePath $c.vhd | Out-Null } catch { }
            Lock-Vhd $c.vhd
            Write-Host 'Private disk is unmounted and locked.'
        }
    }
    elseif ($Mode -eq 'Remove') {
        $c = if (Test-Path $CfgFile) { Get-Content $CfgFile -Raw | ConvertFrom-Json }
        if ($c -and -not (Test-Pw $c)) { throw 'Wrong password.' }
        $cur = [regex]::Match((bcdedit /enum '{current}' /v | Out-String), '(?m)^identifier\s+(\{[0-9a-fA-F\-]{36}\})').Groups[1].Value
        if ($c -and $cur -eq $c.guid) { throw 'You are inside the private Windows. Run Back first, then Remove from your normal Windows.' }
        if ((Read-Host 'Type YES to delete the private Windows and ALL its data') -eq 'YES') {
            if ($c) {
                $dir = Split-Path $c.vhd
                try { Unlock-Vhd $c.vhd } catch { Write-Host "Note: could not reset permissions ($_)" }
                try { Dismount-DiskImage -ImagePath $c.vhd -ErrorAction Stop | Out-Null } catch { }   # release the file if it is still attached
                # if "Stay" is on, make your normal Windows the default again BEFORE deleting anything
                if ((bcdedit /enum '{bootmgr}' /v | Out-String) -match "(?m)^default\s+$([regex]::Escape($c.guid))") { Reset-Boot }
                bcdedit /delete $c.guid /cleanup | Out-Null
            }
            Clear-Leftovers ''
            cmd /c 'schtasks /Delete /TN SysCacheMaint /F >nul 2>&1'
            if ($c) {
                attrib -h -s $dir
                try { Remove-Item $dir -Recurse -Force } catch {
                    throw "Could not delete $dir ($_). Make sure you are in your normal Windows (not the private one), restart the PC and run Remove again before mounting anything."
                }
                Remove-Item $CfgDir -Recurse -Force
                Write-Host 'Removed.'
            } else {
                Write-Host 'No settings found - only leftover boot entries and the auto-lock task were cleaned. If a SysCache folder is left on a drive, delete it by hand.'
            }
        }
    }
    elseif ($Mode -eq 'Check') {
        $c   = if (Test-Path $CfgFile) { Get-Content $CfgFile -Raw | ConvertFrom-Json }
        $all = bcdedit /enum all /v | Out-String
        $bm  = bcdedit /enum '{bootmgr}' /v | Out-String
        Row 'Settings' $(if ($c) { 'found' } else { 'missing (not set up, or already removed)' })
        Row 'Encryption' $(if (Test-Path (Join-Path $CfgDir 'vault.json')) { 'pvault initialised' } else { 'not initialised (plain mode)' })
        if ($c) {
            $root = [IO.Path]::GetPathRoot($c.vhd)
            Row 'Drive' $(if (Exists $root) { "$root connected" } else { "$root NOT connected" })
            Row 'Disk file' $(if (Exists $c.vhd) { 'plain .vhdx visible (unlocked / not encrypted)' } else { 'not visible (locked or encrypted - normal)' })
            Row 'Boot entry' $(if ($all -match [regex]::Escape($c.guid)) { 'present' } else { 'MISSING' })
            Row 'Boots into' $(if ($bm -match "(?m)^default\s+$([regex]::Escape($c.guid))") { 'PRIVATE Windows (Stay is ON - run Back inside it)' } else { 'normal Windows' })
        }
        $left = foreach ($b in ($all -split '(?m)^-{5,}\s*$')) {
            if ($b -match 'SysCache\\sc\.vhdx') {
                $id = [regex]::Match($b, '(?m)^identifier\s+(\{[0-9a-fA-F\-]{36}\})').Groups[1].Value
                if ($id -and (-not $c -or $id -ne $c.guid)) { $id }
            }
        }
        Row 'Leftover entries' $(if ($left) { "$(@($left).Count) found - run Clean to delete" } else { 'none' })
        cmd /c 'schtasks /Query /TN SysCacheMaint >nul 2>&1'
        Row 'Auto-lock task' $(if ($LASTEXITCODE -eq 0) { 'installed' } else { 'not installed' })
    }
    elseif ($Mode -eq 'Clean') {
        $c = if (Test-Path $CfgFile) { Get-Content $CfgFile -Raw | ConvertFrom-Json }
        Clear-Leftovers $(if ($c) { $c.guid } else { '' })
        Write-Host 'Done. Run Check to see the result.'
    }
}
catch { Write-Host "ERROR: $_" -ForegroundColor Red }
finally { Read-Host 'Press Enter to close' | Out-Null }
exit $rc
