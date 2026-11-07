#!/usr/bin/env python3
"""
pvault - keeps the private Windows disk (sc.vhdx) encrypted inside one container (sc.dat).
Open-source crypto only: scrypt (passphrase) -> X25519 key pair -> AES-256-GCM, chunked + compressed.

  python pvault.py init      first time: choose a passphrase, encrypt the disk, install the auto-lock task
  python pvault.py switch    passphrase -> decrypt -> boot into the private Windows once
  python pvault.py stay      same, but keep booting into it until you run Back inside it
  python pvault.py mount     passphrase -> decrypt + mount the disk so you can see the files
  python pvault.py unmount   dismount + encrypt again
  python pvault.py lock      encrypt now (needs NO passphrase - this is what the auto-lock task runs)
  python pvault.py unlock    decrypt only
  python pvault.py remove    passphrase -> delete the private Windows and everything that belongs to it
  python pvault.py passwd    change the passphrase
  python pvault.py check     show the state and find leftover boot entries
  python pvault.py clean     delete leftover boot entries

Needs:  pip install cryptography      (asks for admin rights by itself)
As .exe: pyinstaller --onefile --uac-admin --name pvault pvault.py   (keep PrivateWindows.ps1 next to pvault.exe)
Why locking needs no passphrase: the container is encrypted to a PUBLIC key, so only opening it needs the passphrase.
"""
import ctypes, getpass, hashlib, json, os, struct, subprocess, sys, zlib
from base64 import b64decode as d64, b64encode as e64

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.hazmat.primitives.kdf.scrypt import Scrypt
from cryptography.hazmat.primitives.serialization import Encoding, NoEncryption, PrivateFormat, PublicFormat

MAGIC = b"PVLT1"
CHUNK = 4 * 1024 * 1024
FROZEN = getattr(sys, "frozen", False)   # True when running as the PyInstaller .exe
HERE = os.path.dirname(sys.executable if FROZEN else os.path.abspath(__file__))
CFG_DIR = os.path.join(os.environ.get("ProgramData", "C:\\ProgramData"), "SysCache")
CFG, KEYS = os.path.join(CFG_DIR, "pc.json"), os.path.join(CFG_DIR, "vault.json")


# ---------- crypto ----------
def scrypt_key(pw, salt):
    return Scrypt(salt=salt, length=32, n=2**17, r=8, p=1).derive(pw.encode())

def kek_for(shared, eph_pub):
    return HKDF(algorithm=hashes.SHA256(), length=32, salt=eph_pub, info=b"pvault-wrap").derive(shared)

def nonce_for(i, last):
    return i.to_bytes(8, "big") + (b"\0\0\0\1" if last else b"\0\0\0\0")

def new_keys(pw):
    priv = X25519PrivateKey.generate()
    salt, nonce = os.urandom(16), os.urandom(12)
    raw = priv.private_bytes(Encoding.Raw, PrivateFormat.Raw, NoEncryption())
    blob = AESGCM(scrypt_key(pw, salt)).encrypt(nonce, raw, MAGIC)
    return {"pub": e64(priv.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)).decode(),
            "key": {"salt": e64(salt).decode(), "nonce": e64(nonce).decode(), "blob": e64(blob).decode()}}

def unwrap_priv(pw, key):
    try:
        raw = AESGCM(scrypt_key(pw, d64(key["salt"]))).decrypt(d64(key["nonce"]), d64(key["blob"]), MAGIC)
    except InvalidTag:
        raise SystemExit("Wrong passphrase.")
    return X25519PrivateKey.from_private_bytes(raw)

def read_rec(fi):
    h = fi.read(4)
    if not h:
        return None
    if len(h) < 4:
        raise SystemExit("Container is corrupt.")
    (n,) = struct.unpack(">I", h)
    ct = fi.read(n)
    if len(ct) != n:
        raise SystemExit("Container is truncated.")
    return ct

def iter_plain(fi, aes):
    i, cur = 0, read_rec(fi)
    while cur is not None:
        nxt = read_rec(fi)
        try:
            yield zlib.decompress(aes.decrypt(nonce_for(i, nxt is None), cur, None))
        except InvalidTag:
            raise SystemExit("Container is corrupt or truncated.")
        cur, i = nxt, i + 1

def encrypt_file(src, dst, keys, verify=False):
    eph = X25519PrivateKey.generate()
    eph_pub = eph.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
    kek = kek_for(eph.exchange(X25519PublicKey.from_public_bytes(d64(keys["pub"]))), eph_pub)
    fkey, n0 = os.urandom(32), os.urandom(12)
    kj = json.dumps(keys["key"]).encode()   # passphrase-protected private key travels inside the container
    head = MAGIC + struct.pack(">H", len(kj)) + kj + eph_pub + n0 + AESGCM(kek).encrypt(n0, fkey, MAGIC)
    aes, tmp, h = AESGCM(fkey), dst + ".part", hashlib.sha256()
    with open(src, "rb") as fi, open(tmp, "wb") as fo:
        fo.write(head)
        i, cur = 0, fi.read(CHUNK)
        while True:
            nxt = fi.read(CHUNK) if cur else b""
            h.update(cur)
            ct = aes.encrypt(nonce_for(i, not nxt), zlib.compress(cur, 1), None)
            fo.write(struct.pack(">I", len(ct)) + ct)
            if not nxt:
                break
            cur, i = nxt, i + 1
        fo.flush()
        os.fsync(fo.fileno())
    if verify:
        v = hashlib.sha256()
        with open(tmp, "rb") as fi:
            fi.seek(len(head))
            for part in iter_plain(fi, aes):
                v.update(part)
        if v.digest() != h.digest():
            os.remove(tmp)
            raise SystemExit("Verification failed - the unencrypted disk was kept.")
    os.replace(tmp, dst)

def decrypt_file(src, dst, pw):
    tmp = dst + ".part"
    try:
        with open(src, "rb") as fi:
            if fi.read(5) != MAGIC:
                raise SystemExit("Not a pvault container.")
            (kl,) = struct.unpack(">H", fi.read(2))
            key = json.loads(fi.read(kl))
            eph_pub, n0, wrapped = fi.read(32), fi.read(12), fi.read(48)
            priv = unwrap_priv(pw, key)
            kek = kek_for(priv.exchange(X25519PublicKey.from_public_bytes(eph_pub)), eph_pub)
            aes = AESGCM(AESGCM(kek).decrypt(n0, wrapped, MAGIC))
            with open(tmp, "wb") as fo:
                for part in iter_plain(fi, aes):
                    fo.write(part)
                fo.flush()
                os.fsync(fo.fileno())
        os.replace(tmp, dst)
    except BaseException:
        if os.path.exists(tmp):
            os.remove(tmp)
        raise


# ---------- Windows helpers ----------
def sh(*a):
    return subprocess.run(a, capture_output=True, text=True)

def ensure_admin():
    if os.name != "nt" or ctypes.windll.shell32.IsUserAnAdmin():
        return
    args = " ".join('"%s"' % a for a in ([] if FROZEN else [os.path.abspath(sys.argv[0])]) + sys.argv[1:])
    ctypes.windll.shell32.ShellExecuteW(None, "runas", sys.executable, args, None, 1)
    sys.exit(0)

def ensure_access(d):   # folder may be permission-locked by PrivateWindows.ps1
    if os.name == "nt":
        sh("takeown", "/F", d, "/A", "/R", "/D", "Y")
        sh("icacls", d, "/grant", "*S-1-5-32-544:(OI)(CI)F", "/T")

def lock_dir(d):
    if os.name == "nt":
        sh("icacls", d, "/inheritance:r", "/grant:r", "*S-1-5-18:(OI)(CI)F")
        sh("icacls", d, "/remove:g", "*S-1-5-32-544")

def dismount(vhd):
    if os.name == "nt":
        sh("powershell", "-NoProfile", "-Command", f"Dismount-DiskImage -ImagePath '{vhd}' -ErrorAction SilentlyContinue")

def install_task():     # at every startup of the MAIN Windows: encrypt the disk if it was left unencrypted
    sh("schtasks", "/Create", "/TN", "SysCacheMaint", "/SC", "ONSTART", "/RU", "SYSTEM", "/RL", "HIGHEST", "/F",
       "/TR", (f'"{sys.executable}"' if FROZEN else f'"{sys.executable}" "{os.path.abspath(__file__)}"') + " lock")

def paths():
    try:
        with open(CFG, encoding="utf-8-sig") as f:
            vhd = json.load(f)["vhd"]
    except FileNotFoundError:
        raise SystemExit("Run PrivateWindows.ps1 Setup first.")
    d = os.path.dirname(vhd)
    return vhd, os.path.join(d, "sc.dat"), d


# ---------- commands ----------
def cmd_lock(verify=False):
    vhd, dat, d = paths()
    ensure_access(d)
    dismount(vhd)
    if not os.path.exists(vhd):
        print("Already locked.")
        return
    if not os.path.exists(KEYS):
        raise SystemExit("Run init first.")
    with open(KEYS, encoding="utf-8-sig") as f:
        keys = json.load(f)
    print("Encrypting... (can take several minutes)")
    encrypt_file(vhd, dat, keys, verify)
    os.remove(vhd)
    lock_dir(d)
    print("Locked.")

def cmd_unlock():
    vhd, dat, d = paths()
    ensure_access(d)
    if os.path.exists(vhd):
        return
    if not os.path.exists(dat):
        raise SystemExit("Nothing to unlock.")
    print("Decrypting... (can take several minutes)")
    decrypt_file(dat, vhd, getpass.getpass("Passphrase: "))

def cmd_init():
    vhd, dat, d = paths()
    ensure_access(d)
    if os.path.exists(KEYS):
        raise SystemExit("Already initialised.")
    pw = getpass.getpass("Choose a passphrase (min 8 characters): ")
    if len(pw) < 8 or pw != getpass.getpass("Repeat it: "):
        raise SystemExit("Too short, or they don't match.")
    with open(KEYS, "w") as f:
        json.dump(new_keys(pw), f)
    install_task()
    if os.path.exists(vhd):
        cmd_lock(verify=True)
    print("Done. If you forget the passphrase the data is gone for good.")

def run_ps(mode, unlocked=False):
    ps1 = os.path.join(HERE, "PrivateWindows.ps1")
    return subprocess.run(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", ps1, mode] + (["-Unlocked"] if unlocked else [])).returncode

def cmd_run(mode):
    enc = os.path.exists(KEYS)   # not initialised yet = plain mode: PrivateWindows.ps1 asks its own password
    if enc:
        cmd_unlock()
    rc = run_ps(mode, enc)
    if enc and rc != 42 and mode != "Mount":   # 42 = restarting (disk must stay readable for boot); Mount = user is browsing it
        cmd_lock()

def rewrap_keys(keys, old_pw, new_pw):
    priv = unwrap_priv(old_pw, keys["key"])
    salt, nonce = os.urandom(16), os.urandom(12)
    raw = priv.private_bytes(Encoding.Raw, PrivateFormat.Raw, NoEncryption())
    blob = AESGCM(scrypt_key(new_pw, salt)).encrypt(nonce, raw, MAGIC)
    return {"pub": keys["pub"], "key": {"salt": e64(salt).decode(), "nonce": e64(nonce).decode(), "blob": e64(blob).decode()}}

def patch_header(dat, keyblob):   # the wrapped key has a fixed size, so it can be replaced in place
    kj = json.dumps(keyblob).encode()
    with open(dat, "r+b") as f:
        if f.read(5) != MAGIC:
            raise SystemExit("Not a pvault container.")
        (n,) = struct.unpack(">H", f.read(2))
        if n != len(kj):
            raise SystemExit("Unexpected header size - passphrase NOT changed.")
        f.seek(7)
        f.write(kj)

def cmd_passwd():
    if not os.path.exists(KEYS):
        raise SystemExit("Run init first.")
    with open(KEYS, encoding="utf-8-sig") as f:
        keys = json.load(f)
    old = getpass.getpass("Current passphrase: ")
    unwrap_priv(old, keys["key"])
    new = getpass.getpass("New passphrase (min 8 characters): ")
    if len(new) < 8 or new != getpass.getpass("Repeat it: "):
        raise SystemExit("Too short, or they don't match.")
    fresh = rewrap_keys(keys, old, new)
    vhd, dat, d = paths()
    ensure_access(d)
    if os.path.exists(dat):
        patch_header(dat, fresh["key"])
    with open(KEYS, "w") as f:
        json.dump(fresh, f)
    if not os.path.exists(vhd):
        lock_dir(d)
    print("Passphrase changed.")

def cmd_remove():
    enc = os.path.exists(KEYS)
    if enc:
        with open(KEYS, encoding="utf-8-sig") as f:
            keys = json.load(f)
        unwrap_priv(getpass.getpass("Passphrase: "), keys["key"])   # exits on a wrong passphrase
    run_ps("Remove", enc)

def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    cmd = sys.argv[1].lower()
    ensure_admin()
    try:
        if cmd == "init":
            cmd_init()
        elif cmd in ("switch", "stay", "mount"):
            cmd_run(cmd.capitalize())
        elif cmd == "remove":
            cmd_remove()
        elif cmd == "passwd":
            cmd_passwd()
        elif cmd in ("check", "clean"):
            run_ps(cmd.capitalize())
        elif cmd == "unmount" and not os.path.exists(KEYS):
            cmd_run("Unmount")
        elif cmd in ("lock", "unmount"):
            cmd_lock("--verify" in sys.argv)
        elif cmd == "unlock":
            cmd_unlock()
        else:
            raise SystemExit(__doc__)
    except SystemExit as e:
        if isinstance(e.code, str):
            print(e.code)
    finally:
        if sys.stdin and sys.stdin.isatty():
            input("Press Enter to close")


if __name__ == "__main__":
    main()
