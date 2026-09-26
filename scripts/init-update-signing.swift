#!/usr/bin/env swift
// Create a dedicated Sparkle Ed25519 seed outside the repository. Never print it.
import CryptoKit
import Darwin
import Foundation

enum KeyError: Error { case invalid(String) }

func main() throws {
    guard CommandLine.arguments == [CommandLine.arguments[0], "--create"] else {
        throw KeyError.invalid("Usage: swift scripts/init-update-signing.swift --create")
    }
    guard getuid() != 0 else { throw KeyError.invalid("Run as your normal login user, without sudo") }
    umask(0o077)
    let manager = FileManager.default
    let home = manager.homeDirectoryForCurrentUser
    let folder = home.appendingPathComponent("Library/Application Support/Menu Tidy/Update Signing", isDirectory: true)
    var parent = folder
    while parent.path != home.path {
        if let attributes = try? manager.attributesOfItem(atPath: parent.path),
           attributes[.type] as? FileAttributeType == .typeSymbolicLink {
            throw KeyError.invalid("Signing storage cannot contain symbolic links")
        }
        parent.deleteLastPathComponent()
    }
    try manager.createDirectory(at: folder, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
    let directoryAttributes = try manager.attributesOfItem(atPath: folder.path)
    guard (directoryAttributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
          (directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700 else {
        throw KeyError.invalid("Update signing directory must belong to you and have mode 0700")
    }
    let file = folder.appendingPathComponent("sparkle-ed25519.key")
    let key: Curve25519.Signing.PrivateKey
    if manager.fileExists(atPath: file.path) {
        let attributes = try manager.attributesOfItem(atPath: file.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
              let seed = Data(base64Encoded: try String(contentsOf: file, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)), seed.count == 32 else {
            throw KeyError.invalid("Existing update key is invalid; nothing was replaced")
        }
        key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    } else {
        key = Curve25519.Signing.PrivateKey()
        let bytes = Data((key.rawRepresentation.base64EncodedString() + "\n").utf8)
        try bytes.write(to: file, options: .withoutOverwriting)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    // The 32-byte seed format is supported by Sparkle 2.10.0 sign_update.
    let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
    print("SUPublicEDKey=\(publicKey)")
    print("Private signing key retained locally at: \(file.path)")
    print("Back up this key securely. It was not uploaded or added to the repository.")
}

do { try main() } catch {
    fputs("Update signing setup failed: \(error)\n", stderr)
    exit(1)
}
