// sparkle_tools.swift — Lentis
//
// EdDSA (Ed25519) key generation + DMG signing for Sparkle auto-updates.
// Uses Apple CryptoKit (Curve25519.Signing == RFC 8032 Ed25519), which is
// interoperable with Sparkle's libsodium Ed25519 verification — no external
// dependency, no pip, runs on the macOS runner / any Mac with `swift`.
//
// Usage:
//   swift scripts/sparkle_tools.swift generate
//     -> prints the PUBLIC key (base64, goes into Info.plist as SUPublicEDKey
//        via the LENTIS_SPARKLE_PUBLIC_KEY env var) and the PRIVATE key (base64
//        32-byte seed; store as the GitHub secret SPARKLE_PRIVATE_KEY). Run ONCE.
//
//   SPARKLE_PRIVATE_KEY=<base64> swift scripts/sparkle_tools.swift sign <file>
//     -> prints the base64 Ed25519 signature of <file>'s bytes (the
//        sparkle:edSignature value for the appcast enclosure). Used by the
//        Release workflow.
//
//   SPARKLE_PRIVATE_KEY=<base64> swift scripts/sparkle_tools.swift public-key
//     -> prints the base64 PUBLIC key derived from the private key. The Release
//        workflow uses this to verify LENTIS_SPARKLE_PUBLIC_KEY matches the
//        private key before publishing an appcast (catches a copy/paste from the
//        wrong keypair, which would strand installs on a release that can't
//        verify future updates).
//
// Licensed under the MIT License. See LICENSE for details.

import CryptoKit
import Foundation

enum Mode: String {
    case generate, sign, publicKey = "public-key"
}

func b64(_ data: Data) -> String { data.base64EncodedString() }

func runGenerate() {
    let priv = Curve25519.Signing.PrivateKey()
    let pub = priv.publicKey.rawRepresentation
    let seed = priv.rawRepresentation
    print("PUBLIC  (LENTIS_SPARKLE_PUBLIC_KEY env / Info.plist SUPublicEDKey):")
    print("  " + b64(pub))
    print("PRIVATE (GitHub secret SPARKLE_PRIVATE_KEY) — keep secret:")
    print("  " + b64(seed))
    print("")
    print("Add the PUBLIC key to scripts/package_app.sh via LENTIS_SPARKLE_PUBLIC_KEY")
    print("(or the Release workflow env), and add the PRIVATE key as a GitHub repo")
    print("secret named SPARKLE_PRIVATE_KEY.")
}

func runSign(path: String) throws {
    let env = ProcessInfo.processInfo.environment
    guard let seedB64 = env["SPARKLE_PRIVATE_KEY"], !seedB64.isEmpty,
          let seed = Data(base64Encoded: seedB64) else {
        FileHandle.standardError.write("error: SPARKLE_PRIVATE_KEY env (base64 32-byte seed) is required\n".data(using: .utf8)!)
        exit(64)
    }
    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let sig = try key.signature(for: data)
    print(b64(sig))
}

func runPublicKey() throws {
    let env = ProcessInfo.processInfo.environment
    guard let seedB64 = env["SPARKLE_PRIVATE_KEY"], !seedB64.isEmpty,
          let seed = Data(base64Encoded: seedB64) else {
        FileHandle.standardError.write("error: SPARKLE_PRIVATE_KEY env (base64 32-byte seed) is required\n".data(using: .utf8)!)
        exit(64)
    }
    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    print(b64(key.publicKey.rawRepresentation))
}

let argv = CommandLine.arguments
guard argv.count >= 2, let mode = Mode(rawValue: argv[1]) else {
    FileHandle.standardError.write("usage: sparkle_tools.swift [generate|sign <file>|public-key]\n".data(using: .utf8)!)
    exit(64)
}
switch mode {
case .generate:
    runGenerate()
case .sign:
    guard argv.count >= 3 else {
        FileHandle.standardError.write("usage: sparkle_tools.swift sign <file>\n".data(using: .utf8)!)
        exit(64)
    }
    try runSign(path: argv[2])
case .publicKey:
    try runPublicKey()
}
