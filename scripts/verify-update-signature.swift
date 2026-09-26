#!/usr/bin/swift
// Public-key verification is independent of sign_update's private-key/keychain lookup.
import CryptoKit
import Foundation

func fail() -> Never {
    FileHandle.standardError.write(Data("Update signature verification failed.\n".utf8))
    exit(1)
}

guard CommandLine.arguments.count == 4 else { fail() }
do {
    let infoData = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
    guard let info = try PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any],
          let encodedKey = info["SUPublicEDKey"] as? String,
          let keyData = Data(base64Encoded: encodedKey), keyData.count == 32,
          let signature = Data(base64Encoded: CommandLine.arguments[3]), signature.count == 64 else { fail() }
    let payload = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]), options: .mappedIfSafe)
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
    guard key.isValidSignature(signature, for: payload) else { fail() }
} catch { fail() }
