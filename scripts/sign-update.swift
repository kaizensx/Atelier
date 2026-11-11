// Signs (or verifies) an update archive with Atelier's Ed25519 release key.
// usage: sign-update <archive.zip> <private-key-file>          -> prints the base64 signature
//        sign-update --verify <archive.zip> <signature-file> <base64 public key>
import CryptoKit
import Foundation

let a = CommandLine.arguments
func fail(_ m: String) -> Never { FileHandle.standardError.write(Data((m + "\n").utf8)); exit(1) }

if a.count == 5, a[1] == "--verify" {
    guard let zip = FileManager.default.contents(atPath: a[2]),
          let sigText = try? String(contentsOfFile: a[3], encoding: .utf8),
          let sig = Data(base64Encoded: sigText.trimmingCharacters(in: .whitespacesAndNewlines)),
          let pub = Data(base64Encoded: a[4]),
          let key = try? Curve25519.Signing.PublicKey(rawRepresentation: pub) else { fail("unreadable input") }
    if key.isValidSignature(sig, for: zip) { print("signature OK") } else { fail("signature MISMATCH") }
    exit(0)
}
guard a.count == 3, let zip = FileManager.default.contents(atPath: a[1]),
      let keyText = try? String(contentsOfFile: a[2], encoding: .utf8),
      let raw = Data(base64Encoded: keyText.trimmingCharacters(in: .whitespacesAndNewlines)),
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else { fail("usage: sign-update <zip> <key>") }
print(try! key.signature(for: zip).base64EncodedString())
