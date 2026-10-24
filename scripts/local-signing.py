#!/usr/bin/env python3
"""Create/reuse a private, local-only signing identity for MonitorLight.

This does not use the user's Apple distribution key, install a root trust,
change TCC, or add a keychain to the user's search list.
"""
import os
from pathlib import Path
import re
import secrets
import subprocess
import tempfile

directory = Path.home() / "Library/Application Support/MonitorLight/Signing"
directory.mkdir(parents=True, exist_ok=True, mode=0o700)
os.chmod(directory, 0o700)
password_file = directory / "keychain-password"
keychain = directory / "MonitorLight.keychain-db"
identity = "MonitorLight Local Development"


def run(*args):
    result = subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        # Never print command arguments, which may include the local password.
        raise RuntimeError(f"{Path(args[0]).name} failed: {result.stderr.strip()}")
    return result.stdout


if not keychain.exists():
    if not password_file.exists():
        fd = os.open(password_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as stream:
            stream.write(secrets.token_urlsafe(36))
    password = password_file.read_text()
    search_list = re.findall(r'"([^"]+)"', run("security", "list-keychains", "-d", "user"))
    try:
        run("security", "create-keychain", "-p", password, str(keychain))
    finally:
        run("security", "list-keychains", "-d", "user", "-s", *search_list)

try:
    run("security", "find-certificate", "-c", identity, str(keychain))
    needs_identity = False
except RuntimeError:
    needs_identity = True

if needs_identity:
    password = password_file.read_text()
    with tempfile.TemporaryDirectory(dir=directory) as temporary:
        temporary = Path(temporary)
        config = temporary / "certificate.cnf"
        config.write_text("""[req]
distinguished_name = dn
x509_extensions = extensions
prompt = no
[dn]
CN = MonitorLight Local Development
[extensions]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
""")
        key, certificate, p12 = [temporary / name for name in ("key.pem", "certificate.pem", "identity.p12")]
        run("openssl", "req", "-new", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "3650",
            "-config", str(config), "-keyout", str(key), "-out", str(certificate))
        run("openssl", "pkcs12", "-export", "-inkey", str(key), "-in", str(certificate),
            "-out", str(p12), "-name", identity, "-certpbe", "PBE-SHA1-3DES", "-keypbe", "PBE-SHA1-3DES", "-macalg", "sha1", "-passout", "file:" + str(password_file))
        run("security", "unlock-keychain", "-p", password, str(keychain))
        run("security", "import", str(p12), "-k", str(keychain), "-P", password, "-T", "/usr/bin/codesign")
        run("security", "set-key-partition-list", "-S", "apple-tool:,apple:", "-s", "-k", password, str(keychain))

run("security", "unlock-keychain", "-p", password_file.read_text(), str(keychain))
print(keychain)
