import CryptoKit
import Foundation

final class EnclosureReader: NSObject, XMLParserDelegate {
    var enclosures: [[String: String]] = []
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        if elementName == "enclosure" { enclosures.append(attributeDict) }
    }
}

let args = CommandLine.arguments
let archive = URL(fileURLWithPath: args[1])
let parser = XMLParser(contentsOf: URL(fileURLWithPath: args[2]))!
let reader = EnclosureReader()
parser.delegate = reader
precondition(parser.parse(), "Invalid feed")
let enclosure = reader.enclosures.first { URL(string: $0["url"] ?? "")?.lastPathComponent == archive.lastPathComponent }!
let bytes = try Data(contentsOf: archive)
precondition(Int(enclosure["length"] ?? "") == bytes.count, "Length mismatch")
let key = try Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: args[3])!)
let signature = Data(base64Encoded: enclosure["sparkle:edSignature"]!)!
precondition(key.isValidSignature(signature, for: bytes), "Invalid archive signature")
print("Verified archive length and EdDSA signature against public key")
