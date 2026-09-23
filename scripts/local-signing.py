#!/usr/bin/env python3
"""Explicit, per-user local signing setup; normal builds never create identities."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import secrets
import shutil
import stat
import subprocess
import sys
import tempfile


BUNDLE_ID = "dev.hdh.MenuTidy"
SIGNING_DIR = Path.home() / "Library/Application Support/Menu Tidy/Signing"
KEYCHAIN = SIGNING_DIR / "MenuTidy-Development.keychain-db"
PASSWORD_FILE = SIGNING_DIR / "keychain-password"
MANIFEST = SIGNING_DIR / "identity.json"
CERTIFICATE = SIGNING_DIR / "certificate.der"
CERTIFICATE_NAME = "Menu Tidy Local Development"
SECURITY = "/usr/bin/security"
CODESIGN = "/usr/bin/codesign"
OPENSSL = "/usr/bin/openssl"


class SigningError(Exception):
    pass


def run(arguments, *, input_data=None, label="操作", disclose_output=True):
    result = subprocess.run(arguments, input=input_data, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, check=False)
    if result.returncode:
        # Never include arguments: security's stdin and OpenSSL input can contain secrets.
        details = result.stderr.decode("utf-8", errors="replace").strip()
        suffix = f"\n{details}" if disclose_output and details else ""
        raise SigningError(f"{label}失败（退出码 {result.returncode}）。{suffix}")
    return result.stdout


def security_command(arguments, *, secret=False, label="钥匙串操作"):
    # security's interactive parser supports quoted arguments with backslash escaping.
    # A pipe is not a TTY: no prompt, command echo or history. One command per process
    # preserves its exit code. Keep passwords out of argv, environment and logs.
    if any(any(character in argument for character in "\r\n\0") for argument in arguments):
        raise SigningError("钥匙串参数包含不支持的换行或空字符。")
    line = " ".join('"' + argument.replace("\\", "\\\\").replace('"', '\\"') + '"'
                    for argument in arguments) + "\n"
    if len(line.encode()) >= 4096:
        raise SigningError("钥匙串命令过长。")
    return run([SECURITY, "-q", "-i"], input_data=line.encode(), label=label,
               disclose_output=not secret)


def check_private(path, *, directory=False):
    try:
        info = path.lstat()
    except FileNotFoundError:
        raise SigningError(f"本地签名文件不存在：{path}") from None
    expected = stat.S_ISDIR if directory else stat.S_ISREG
    if not expected(info.st_mode) or info.st_uid != os.getuid():
        raise SigningError(f"本地签名路径必须属于当前用户，且不能是符号链接：{path}")
    if info.st_mode & 0o077:
        raise SigningError(f"本地签名路径权限过宽，应为 {'0700' if directory else '0600'}：{path}")


def check_signing_location():
    # Keep generated credentials in the stated user-local tree, even if a parent
    # directory was replaced with a symlink before setup.
    for path in (SIGNING_DIR, *SIGNING_DIR.parents):
        if path.is_symlink():
            raise SigningError(f"本地签名目录的路径不能经过符号链接：{path}")
        if path == Path.home():
            break


def requirement(fingerprint):
    if not re.fullmatch(r"[0-9A-F]{40}", fingerprint):
        raise SigningError("本地签名证书指纹格式不正确。")
    return f'identifier "{BUNDLE_ID}" and certificate leaf = H"{fingerprint}"'


def load_identity_materials():
    check_signing_location()
    check_private(SIGNING_DIR, directory=True)
    for path in (PASSWORD_FILE, KEYCHAIN, CERTIFICATE):
        check_private(path)
    fingerprint = hashlib.sha1(CERTIFICATE.read_bytes()).hexdigest().upper()
    password = PASSWORD_FILE.read_text().strip()
    if not re.fullmatch(r"[0-9a-f]{64}", password):
        raise SigningError("本地钥匙串密码文件格式不正确。")
    return fingerprint, password


def load_identity():
    fingerprint, password = load_identity_materials()
    check_private(MANIFEST)
    data = json.loads(MANIFEST.read_text())
    if data.get("version") != 1 or data.get("bundleIdentifier") != BUNDLE_ID:
        raise SigningError("本地签名配置版本或应用标识不匹配。")
    if data.get("certificateSHA1") != fingerprint:
        raise SigningError("本地证书与固定指纹不匹配；已停止签名。")
    return fingerprint, password


def write_manifest(fingerprint):
    manifest = {"version": 1, "bundleIdentifier": BUNDLE_ID,
                "certificateSHA1": fingerprint,
                "certificateSHA256": hashlib.sha256(CERTIFICATE.read_bytes()).hexdigest(),
                "certificateName": CERTIFICATE_NAME}
    MANIFEST.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    MANIFEST.chmod(0o600)


def sign_local(app, fingerprint, password):
    security_command(["unlock-keychain", "-p", password, str(KEYCHAIN)], secret=True,
                     label="解锁 Menu Tidy 专属钥匙串")
    try:
        run([CODESIGN, "--force", "--sign", fingerprint, "--keychain", str(KEYCHAIN),
             "--timestamp=none", "--requirements", "=designated => " + requirement(fingerprint),
             str(app)], label="本地证书签名")
        run([CODESIGN, "--verify", "--strict", "--test-requirement",
             "=" + requirement(fingerprint), str(app)], label="固定证书要求验证")
    finally:
        security_command(["lock-keychain", str(KEYCHAIN)], label="重新锁定 Menu Tidy 专属钥匙串")


def smoke_test(scratch, fingerprint, password):
    hashes = []
    for version in ("1", "2"):
        app = scratch / f"SignatureProbe-{version}.app"
        executable_dir = app / "Contents/MacOS"
        executable_dir.mkdir(parents=True, mode=0o700)
        executable = executable_dir / "SignatureProbe"
        # copy2 also copies protected flags from the system executable on macOS.
        shutil.copyfile("/usr/bin/true", executable)
        executable.chmod(0o700)
        with (app / "Contents/Info.plist").open("wb") as stream:
            plistlib.dump({"CFBundleIdentifier": BUNDLE_ID, "CFBundleExecutable": "SignatureProbe",
                          "CFBundlePackageType": "APPL", "CFBundleVersion": version}, stream)
        sign_local(app, fingerprint, password)
        details = subprocess.run([CODESIGN, "--display", "--verbose=4", str(app)],
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
        match = re.search(rb"^CDHash=([0-9a-f]+)$", details.stderr, re.MULTILINE)
        if not match:
            raise SigningError("无法读取签名验证样本的 CDHash。")
        hashes.append(match[1])
    if hashes[0] == hashes[1]:
        raise SigningError("两个验证样本未产生不同的代码哈希，无法验证跨构建身份。")


def initialize(confirmed, resume=False):
    if resume:
        if MANIFEST.exists():
            fingerprint, password = load_identity()
        else:
            fingerprint, password = load_identity_materials()
        with tempfile.TemporaryDirectory(prefix="resume-", dir=SIGNING_DIR) as temp:
            smoke_test(Path(temp), fingerprint, password)
        write_manifest(fingerprint)
        print("已验证现有证书与私钥并完成本地签名配置；未生成或替换任何身份。")
        return
    if not confirmed:
        raise SigningError("初始化会创建仅供本机开发使用的签名身份。请先阅读 docs/LOCAL-SIGNING.md，"
                           "再显式运行 scripts/init-local-signing.sh --create。")
    if MANIFEST.exists():
        fingerprint, password = load_identity()
        with tempfile.TemporaryDirectory(prefix="verify-", dir=SIGNING_DIR) as temp:
            smoke_test(Path(temp), fingerprint, password)
        print("现有本地签名身份有效，已保留；未重新生成证书。")
        return
    check_signing_location()
    SIGNING_DIR.mkdir(mode=0o700, parents=True, exist_ok=True)
    check_private(SIGNING_DIR, directory=True)
    if any(SIGNING_DIR.iterdir()):
        raise SigningError(f"签名目录已有未完成配置；为保留现有密钥，未覆盖任何内容：{SIGNING_DIR}")
    password = secrets.token_hex(32)
    # Exclusive creation prevents two simultaneous initializations overwriting
    # the password for an identity that one of them already started to create.
    with PASSWORD_FILE.open("x") as stream:
        stream.write(password + "\n")
    print("正在创建 Menu Tidy 专属开发钥匙串与签名证书；不会添加任何全局信任。")
    try:
        security_command(["create-keychain", "-p", password, str(KEYCHAIN)], secret=True,
                         label="创建 Menu Tidy 专属钥匙串")
        KEYCHAIN.chmod(0o600)
        with tempfile.TemporaryDirectory(prefix="initialize-", dir=SIGNING_DIR) as temp:
            scratch = Path(temp)
            private_key = scratch / "encrypted-private-key.pem"
            pem_certificate = scratch / "certificate.pem"
            identity = scratch / "identity.p12"
            export_password = scratch / "export-password"
            config = scratch / "openssl.cnf"
            # LibreSSL reuses a password BIO when passin/passout name the same
            # file and reads a second line. Use a distinct 0600 file for export.
            export_password.write_text(password + "\n")
            config.write_text("""[req]
distinguished_name = subject
x509_extensions = code_signing
prompt = no
[subject]
CN = Menu Tidy Local Development
O = Menu Tidy Local Development
[code_signing]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
""")
            # Private key is encrypted even in the temporary 0700 directory.
            # Only the password-file path, never its contents, reaches OpenSSL argv.
            run([OPENSSL, "req", "-new", "-x509", "-newkey", "rsa:3072", "-sha256",
                 "-days", "3650", "-config", str(config), "-keyout", str(private_key),
                 "-out", str(pem_certificate), "-passout", f"file:{PASSWORD_FILE}"],
                label="生成本地开发证书", disclose_output=False)
            run([OPENSSL, "x509", "-in", str(pem_certificate), "-outform", "DER",
                 "-out", str(CERTIFICATE)], label="导出公开证书")
            run([OPENSSL, "pkcs12", "-export", "-name", CERTIFICATE_NAME,
                 "-inkey", str(private_key), "-in", str(pem_certificate), "-out", str(identity),
                 "-passin", f"file:{PASSWORD_FILE}", "-passout", f"file:{export_password}"],
                label="封装临时加密签名身份", disclose_output=False)
            for path in (private_key, pem_certificate, identity, config, CERTIFICATE):
                path.chmod(0o600)
            security_command(["import", str(identity), "-k", str(KEYCHAIN), "-f", "pkcs12",
                              "-P", password, "-x", "-T", CODESIGN], secret=True,
                             label="导入不可导出的专属签名私钥")
            # Applied only to signing private keys in the brand-new dedicated keychain.
            # apple: is required by the macOS security(1) manual for codesign access.
            security_command(["set-key-partition-list", "-S", "apple-tool:,apple:", "-s",
                              "-t", "private", "-k", password, str(KEYCHAIN)], secret=True,
                             label="配置系统代码签名工具的专属密钥访问")
            fingerprint = hashlib.sha1(CERTIFICATE.read_bytes()).hexdigest().upper()
            smoke_test(scratch, fingerprint, password)
            write_manifest(fingerprint)
        print(f"本地签名身份已准备好：{SIGNING_DIR}")
        print("两份不同代码哈希的样本均通过同一固定证书要求。"
              "此检查不代表辅助功能已授权；首次切换签名后仍需重新添加应用授权。")
    except BaseException:
        # Do not delete a keychain automatically: it may already hold the only key copy.
        print(f"初始化未完成，现有身份材料保留在 {SIGNING_DIR}；请勿重复生成或公开这些文件。",
              file=sys.stderr)
        raise
    finally:
        if KEYCHAIN.exists():
            security_command(["lock-keychain", str(KEYCHAIN)], label="锁定 Menu Tidy 专属钥匙串")


def sign(app):
    with (app / "Contents/Info.plist").open("rb") as stream:
        if plistlib.load(stream).get("CFBundleIdentifier") != BUNDLE_ID:
            raise SigningError("待签名应用的 bundle identifier 不匹配。")
    identity = os.environ.get("CODE_SIGN_IDENTITY")
    keychain = os.environ.get("CODE_SIGN_KEYCHAIN")
    if identity is not None:
        if not identity.strip():
            raise SigningError("CODE_SIGN_IDENTITY 不能为空。")
        arguments = [CODESIGN, "--force", "--sign", identity, "--timestamp=none"]
        if keychain:
            arguments += ["--keychain", keychain]
        explicit_requirement = os.environ.get("CODE_SIGN_REQUIREMENT")
        if explicit_requirement:
            if identity == "-":
                raise SigningError("临时签名不能指定固定证书要求。")
            arguments += ["--requirements", "=designated => " + explicit_requirement]
        if identity == "-":
            warn_ad_hoc()
        run(arguments + [str(app)], label="显式指定的身份签名")
        print("已使用显式 CODE_SIGN_IDENTITY；签名失败时不会退回临时签名。")
    elif keychain is not None:
        raise SigningError("CODE_SIGN_KEYCHAIN 必须与 CODE_SIGN_IDENTITY 一起指定。")
    elif MANIFEST.exists():
        fingerprint, password = load_identity()
        sign_local(app, fingerprint, password)
        print("已使用本机固定证书开发签名；后续构建保持同一签名身份。")
    elif SIGNING_DIR.exists() and any(SIGNING_DIR.iterdir()):
        raise SigningError("本地签名初始化未完成，已停止构建签名；请参见 docs/LOCAL-SIGNING.md。")
    else:
        warn_ad_hoc()
        run([CODESIGN, "--force", "--sign", "-", str(app)], label="临时开发签名")


def warn_ad_hoc():
    print("警告：当前采用 ad hoc 临时签名；修改代码后，macOS 可能把辅助功能授权视为旧版本授权。\n"
          "可显式运行 scripts/init-local-signing.sh --create 建立本机固定开发身份，"
          "或设置 CODE_SIGN_IDENTITY。构建不会自动创建证书。", file=sys.stderr)


def main():
    os.umask(0o077)
    if sys.platform != "darwin" or os.getuid() == 0:
        raise SigningError("请以当前 macOS 登录用户执行，不要使用 sudo。")
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    init_parser = commands.add_parser("init", help="显式创建或验证本机固定开发签名身份")
    init_action = init_parser.add_mutually_exclusive_group()
    init_action.add_argument("--create", action="store_true")
    init_action.add_argument("--resume", action="store_true",
                             help="仅验证并接续已导入证书和私钥的未完成配置")
    sign_parser = commands.add_parser("sign", help="按环境变量、本机身份、临时签名顺序签名")
    sign_parser.add_argument("app", type=Path)
    args = parser.parse_args()
    if args.command == "init":
        initialize(args.create, args.resume)
    else:
        sign(args.app)


if __name__ == "__main__":
    try:
        main()
    except (SigningError, OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"签名失败：{error}", file=sys.stderr)
        sys.exit(1)
