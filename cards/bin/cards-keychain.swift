#!/usr/bin/env swift
import Foundation
import Security

let service = "com.pattybot.cards.1password-service-account"
let account = NSUserName()

func trustedAccess() -> SecAccess {
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
    var trusted: SecTrustedApplication?
    let trustedStatus = SecTrustedApplicationCreateFromPath(executable, &trusted)
    guard trustedStatus == errSecSuccess, let trusted = trusted else {
        fail("could not create trusted-application ACL", trustedStatus)
    }
    var access: SecAccess?
    let accessStatus = SecAccessCreate(
        "Cards automation — 1Password service account" as CFString,
        [trusted] as CFArray,
        &access
    )
    guard accessStatus == errSecSuccess, let access = access else {
        fail("could not create Keychain ACL", accessStatus)
    }
    return access
}

func fail(_ message: String, _ status: OSStatus? = nil) -> Never {
    if let status = status,
       let text = SecCopyErrorMessageString(status, nil) as String? {
        FileHandle.standardError.write(Data("cards-keychain: \(message): \(text)\n".utf8))
    } else {
        FileHandle.standardError.write(Data("cards-keychain: \(message)\n".utf8))
    }
    exit(1)
}

// A launchd/GUI-launched CLI can have a different default search list.
// Pin both queries and writes to the Login Keychain the provisioner unlocks.
var loginKeychain: SecKeychain?
let keychainPath = NSHomeDirectory() + "/Library/Keychains/login.keychain-db"
let openStatus = SecKeychainOpen(keychainPath, &loginKeychain)
guard openStatus == errSecSuccess, let loginKeychain = loginKeychain else {
    fail("could not open Login Keychain", openStatus)
}

let base: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: service,
    kSecAttrAccount as String: account,
]

func queryFor(_ item: [String: Any]) -> [String: Any] {
    var query = item
    query[kSecMatchSearchList as String] = [loginKeychain]
    return query
}

func readSecret(_ item: [String: Any]) -> Data {
    var query = queryFor(item)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess, let data = result as? Data else {
        fail("secret not available", status)
    }
    return data
}

func storeSecret(_ secret: Data, _ item: [String: Any]) {
    let query = queryFor(item)
    let found = SecItemCopyMatching(query as CFDictionary, nil)
    let attributes: [String: Any] = [
        kSecValueData as String: secret,
        kSecAttrLabel as String: "Cards automation — 1Password service account",
        kSecAttrDescription as String: "Read-only access to the AI agents vault",
        kSecAttrAccess as String: trustedAccess(),
    ]
    let status: OSStatus
    if found == errSecSuccess {
        status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    } else if found == errSecItemNotFound {
        var add = item.merging(attributes) { _, new in new }
        add[kSecUseKeychain as String] = loginKeychain
        status = SecItemAdd(add as CFDictionary, nil)
    } else {
        fail("could not inspect Login Keychain", found)
    }
    guard status == errSecSuccess else { fail("could not store secret", status) }
    guard readSecret(item) == secret else { fail("Keychain read-back did not match") }
}

guard CommandLine.arguments.count == 2 else {
    fail("usage: cards-keychain set|get|delete|preflight")
}

switch CommandLine.arguments[1] {
case "set":
    let secret = FileHandle.standardInput.readDataToEndOfFile()
    guard !secret.isEmpty else { fail("refusing to store an empty secret") }
    storeSecret(secret, base)

case "get":
    FileHandle.standardOutput.write(readSecret(base))

case "preflight":
    // Exercise add/update/read/delete with non-secret data before issuing a token.
    var probe = base
    probe[kSecAttrService as String] = service + ".probe." + UUID().uuidString
    storeSecret(Data("cards-keychain-probe".utf8), probe)
    storeSecret(Data("cards-keychain-probe-updated".utf8), probe)
    let deleted = SecItemDelete(queryFor(probe) as CFDictionary)
    guard deleted == errSecSuccess else { fail("could not remove probe item", deleted) }
    let found = SecItemCopyMatching(queryFor(base) as CFDictionary, nil)
    if found == errSecSuccess {
        // Keep the old token intact while checking that it can be replaced.
        storeSecret(readSecret(base), base)
    } else if found != errSecItemNotFound {
        fail("could not inspect existing token", found)
    }
    print("Login Keychain storage and read-back verified.")

case "delete":
    let status = SecItemDelete(queryFor(base) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
        fail("could not delete secret", status)
    }

default:
    fail("usage: cards-keychain set|get|delete|preflight")
}
