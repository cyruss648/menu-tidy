#!/usr/bin/env python3
"""Create a dedicated release identity or import it into an ephemeral CI keychain.

No certificate is trusted globally. Passwords travel through files/stdin, never
command arguments or logs. Creating files does not upload them to any service.
"""

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import secrets
import shutil
import subprocess
import sys
import tempfile

SECURITY = "/usr/bin/security"
OPENSSL = "/usr/bin/openssl"
CODESIGN = "/usr/bin/codesign"
BUNDLE_ID = "dev.hdh.MenuTidy"


def run(arguments, *, input_data=None):
    result = subprocess.run(arguments, input=input_data, capture_output=True, check=False)
    if result.returncode:
        # Arguments and subprocess errors can contain passwords or identity data.
        raise RuntimeError(f"{Path(arguments[0]).name} failed ({result.returncode})")
    return result.stdout


def security(arguments):
    if any(any(c in value for c in "\r\n\0") for value in arguments):
        raise ValueError("Invalid keychain argument")
    command = " ".join('"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"' for value in arguments)
    if len(command.encode()) >= 4096:
        raise ValueError("Keychain command is too long")
    return run([SECURITY, "-q", "-i"], input_data=(command + "\n").encode())


def create_identity(destination):
    destination = destination.expanduser().absolute()
    repository = Path(__file__).resolve().parent.parent
    if destination.resolve().is_relative_to(repository):
        raise ValueError("Release credentials must be stored outside the repository")
    if any(parent.is_symlink() for parent in (destination, *destination.parents)):
        raise ValueError("Signing paths must not contain symlinks")
    destination.mkdir(mode=0o700, parents=True, exist_ok=False)
    password_file = destination / "password"
    password_file.write_text(secrets.token_hex(32) + "\n")
    with tempfile.TemporaryDirectory(prefix="create-", dir=destination) as temporary:
        scratch = Path(temporary)
        config = scratch / "openssl.cnf"
        config.write_text("""[req]
distinguished_name = subject
x509_extensions = code_signing
prompt = no
[subject]
CN = Menu Tidy Release Signing
O = Menu Tidy
[code_signing]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
""")
        key = scratch / "encrypted-key.pem"
        pem = scratch / "certificate.pem"
        export_password = scratch / "export-password"
        export_password.write_bytes(password_file.read_bytes())
        run([OPENSSL, "req", "-new", "-x509", "-newkey", "rsa:3072", "-sha256", "-days", "3650",
             "-config", str(config), "-keyout", str(key), "-out", str(pem),
             "-passout", f"file:{password_file}"])
        certificate = destination / "certificate.der"
        run([OPENSSL, "x509", "-in", str(pem), "-outform", "DER", "-out", str(certificate)])
        identity = destination / "identity.p12"
        run([OPENSSL, "pkcs12", "-export", "-name", "Menu Tidy Release Signing", "-inkey", str(key),
             "-in", str(pem), "-out", str(identity), "-passin", f"file:{password_file}",
             "-passout", f"file:{export_password}"])
        (destination / "identity.base64").write_text(base64.b64encode(identity.read_bytes()).decode() + "\n")
        fingerprint = hashlib.sha1(certificate.read_bytes()).hexdigest().upper()
        (destination / "identity.json").write_text(json.dumps({
            "bundleIdentifier": BUNDLE_ID, "certificateSHA1": fingerprint,
            "purpose": "GitHub Actions release signing only", "appleNotarized": False,
        }, indent=2) + "\n")
    print(f"Dedicated release identity created in {destination}")
    print(f"Public certificate SHA1: {fingerprint}")
    print("No files uploaded; existing local development identity unchanged.")


def locations():
    temporary = Path(os.environ["RUNNER_TEMP"]).resolve(strict=True)
    return temporary, temporary / "menu-tidy-signing-state.json"


def install():
    temporary, state_file = locations()
    if state_file.exists():
        raise ValueError("Signing state already exists; clean up before importing again")
    encoded = os.environ.get("MACOS_SIGNING_P12_BASE64", "").strip()
    password = os.environ.get("MACOS_SIGNING_PASSWORD", "").strip()
    if not encoded or not password:
        raise ValueError("Release signing secrets are missing; refusing an ad-hoc release")
    env_file = Path(os.environ["GITHUB_ENV"])
    payload = base64.b64decode(encoded, validate=True)
    scratch = Path(tempfile.mkdtemp(prefix="menu-tidy-signing-", dir=temporary))
    keychain = scratch / "release.keychain-db"
    state_file.write_text(json.dumps({"scratch": str(scratch), "keychain": str(keychain)}))
    identity = scratch / "identity.p12"
    identity.write_bytes(payload)
    keychain_password = secrets.token_hex(32)
    try:
        security(["create-keychain", "-p", keychain_password, str(keychain)])
        security(["set-keychain-settings", "-lut", "3600", str(keychain)])
        security(["unlock-keychain", "-p", keychain_password, str(keychain)])
        security(["import", str(identity), "-k", str(keychain), "-f", "pkcs12", "-P", password,
                  "-x", "-T", CODESIGN])
        security(["set-key-partition-list", "-S", "apple-tool:,apple:", "-s", "-t", "private",
                  "-k", keychain_password, str(keychain)])
        pem = security(["find-certificate", "-a", "-p", str(keychain)])
        if pem.count(b"-----BEGIN CERTIFICATE-----") != 1:
            raise ValueError("Expected one dedicated self-signed release certificate")
        der = run([OPENSSL, "x509", "-outform", "DER"], input_data=pem)
        fingerprint = hashlib.sha1(der).hexdigest().upper()
        requirement = f'identifier "{BUNDLE_ID}" and certificate leaf = H"{fingerprint}"'
        with env_file.open("a") as stream:
            stream.write(f"CODE_SIGN_IDENTITY={fingerprint}\n")
            stream.write(f"CODE_SIGN_KEYCHAIN={keychain}\n")
            stream.write(f"CODE_SIGN_REQUIREMENT={requirement}\n")
        identity.unlink()
        print("Release identity imported into a temporary keychain; fixed signing requirement configured.")
    except BaseException:
        cleanup()
        raise


def cleanup():
    temporary, state_file = locations()
    if not state_file.exists():
        return
    state = json.loads(state_file.read_text())
    scratch = Path(state["scratch"])
    keychain = Path(state["keychain"])
    if (scratch.parent.resolve() != temporary or not scratch.name.startswith("menu-tidy-signing-")
            or scratch.is_symlink() or keychain != scratch / "release.keychain-db"):
        raise ValueError("Refusing to clean up unexpected signing paths")
    if keychain.exists():
        security(["delete-keychain", str(keychain)])
    if scratch.exists():
        shutil.rmtree(scratch)
    state_file.unlink()
    print("Temporary release keychain removed.")


def main():
    os.umask(0o077)
    if sys.platform != "darwin" or os.getuid() == 0:
        raise ValueError("Use a non-root macOS account")
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    create = commands.add_parser("create")
    create.add_argument("--directory", type=Path, default=Path.home() / "Library/Application Support/Menu Tidy/ReleaseSigning")
    commands.add_parser("install")
    commands.add_parser("cleanup")
    args = parser.parse_args()
    if args.command == "create":
        create_identity(args.directory)
    elif args.command == "install":
        install()
    else:
        cleanup()


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError, RuntimeError) as error:
        print(f"Release signing failed: {error}", file=sys.stderr)
        sys.exit(1)
