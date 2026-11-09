import Foundation
import CryptoKit

// Public-key verification only: no private signing material is accepted here.
guard CommandLine.arguments.count == 4,
      let keyData = Data(base64Encoded: CommandLine.arguments[1]),
      let signature = Data(base64Encoded: CommandLine.arguments[2]) else {
    fatalError("usage: verify-update-signature.swift <public-key> <signature> <archive>")
}
let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
let archive = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]), options: .mappedIfSafe)
guard key.isValidSignature(signature, for: archive) else {
    fputs("Update signature does not match the public key embedded in the app\n", stderr)
    exit(1)
}
print("Update signature verified against the app public key")
