import Foundation
import Security

/// Who signed an executable, via the Security framework (no shelling out).
struct SignatureInfo: Hashable {
    enum Trust: Int, Comparable {
        case invalid = 0, unknown, unsigned, adhoc, developerID, appStore, apple
        static func < (a: Trust, b: Trust) -> Bool { a.rawValue < b.rawValue }
    }
    var trust: Trust
    var teamID: String?
    var identifier: String?

    var label: String {
        switch trust {
        case .apple: "Apple"
        case .appStore: "Mac App Store" + (teamID.map { " (\($0))" } ?? "")
        case .developerID: "Developer ID" + (teamID.map { " (\($0))" } ?? "")
        case .adhoc: "Ad-hoc signed (no identity)"
        case .unsigned: "Unsigned"
        case .unknown: "Not verifiable (no read access)"
        case .invalid: "Signature broken or tampered"
        }
    }

    var isTrustedVendor: Bool { trust >= .developerID }
    /// Signed by nobody identifiable (excludes files we simply couldn't read).
    var isAnonymous: Bool { trust == .unsigned || trust == .adhoc }
}

enum CodeSigning {
    private static var cache: [String: SignatureInfo] = [:]
    private static let lock = NSLock()

    private static let appleReq = req("anchor apple")
    private static let devIDReq = req("anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists")
    private static let storeReq = req("anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.9] exists")

    private static func req(_ s: String) -> SecRequirement? {
        var r: SecRequirement?
        SecRequirementCreateWithString(s as CFString, [], &r)
        return r
    }

    static func check(_ path: String) -> SignatureInfo {
        lock.lock()
        if let c = cache[path] { lock.unlock(); return c }
        lock.unlock()
        let info = evaluate(path)
        lock.lock(); cache[path] = info; lock.unlock()
        return info
    }

    private static func evaluate(_ path: String) -> SignatureInfo {
        if !FileManager.default.isReadableFile(atPath: path) && !FS.isDir(URL(fileURLWithPath: path)) { return SignatureInfo(trust: .unknown) }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code else {
            return SignatureInfo(trust: .unsigned)
        }
        let fast = SecCSFlags(rawValue: 1 << 2)   // kSecCSDoNotValidateResources: verify the executable, skip bundle resources
        let base = SecStaticCodeCheckValidity(code, fast, nil)
        var dict: CFDictionary?
        SecCodeCopySigningInformation(code, SecCSFlags(rawValue: 1 << 1), &dict)   // kSecCSSigningInformation
        let d = (dict as? [String: Any]) ?? [:]
        let team = d[kSecCodeInfoTeamIdentifier as String] as? String
        let ident = d[kSecCodeInfoIdentifier as String] as? String
        let flags = (d[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        if base == errSecCSUnsigned { return SignatureInfo(trust: .unsigned) }
        if base != errSecSuccess { return SignatureInfo(trust: .invalid, teamID: team, identifier: ident) }
        if flags & 0x2 != 0 { return SignatureInfo(trust: .adhoc, teamID: nil, identifier: ident) }   // kSecCodeSignatureAdhoc
        if let r = appleReq, SecStaticCodeCheckValidity(code, fast, r) == errSecSuccess { return SignatureInfo(trust: .apple, teamID: team, identifier: ident) }
        if let r = storeReq, SecStaticCodeCheckValidity(code, fast, r) == errSecSuccess { return SignatureInfo(trust: .appStore, teamID: team, identifier: ident) }
        if let r = devIDReq, SecStaticCodeCheckValidity(code, fast, r) == errSecSuccess { return SignatureInfo(trust: .developerID, teamID: team, identifier: ident) }
        return SignatureInfo(trust: .adhoc, teamID: team, identifier: ident)
    }

    /// Path of the executable for a running process.
    static func path(of pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : nil
    }

    /// For a binary inside an app bundle, the bundle itself (its signature covers the whole app).
    static func bundle(containing path: String) -> String? {
        guard let r = path.range(of: ".app/Contents/") else { return nil }
        return String(path[..<r.lowerBound]) + ".app"
    }
}
