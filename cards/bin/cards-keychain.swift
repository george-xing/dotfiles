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

let base: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: service,
    kSecAttrAccount as String: account,
]

guard CommandLine.arguments.count == 2 else {
    fail("usage: cards-keychain set|get|delete")
}

switch CommandLine.arguments[1] {
case "set":
    let secret = FileHandle.standardInput.readDataToEndOfFile()
    guard !secret.isEmpty else { fail("refusing to store an empty secret") }
    let found = SecItemCopyMatching(base as CFDictionary, nil)
    let status: OSStatus
    if found == errSecSuccess {
        status = SecItemUpdate(base as CFDictionary,
                               [kSecValueData as String: secret] as CFDictionary)
    } else if found == errSecItemNotFound {
        var add = base
        add[kSecValueData as String] = secret
        add[kSecAttrLabel as String] = "Cards automation — 1Password service account"
        add[kSecAttrDescription as String] = "Read-only access to the Pattybot vault"
        add[kSecAttrAccess as String] = trustedAccess()
        status = SecItemAdd(add as CFDictionary, nil)
    } else {
        fail("could not inspect Keychain", found)
    }
    guard status == errSecSuccess else { fail("could not store secret", status) }

case "get":
    var query = base
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess, let data = result as? Data else {
        fail("secret not available", status)
    }
    FileHandle.standardOutput.write(data)

case "delete":
    let status = SecItemDelete(base as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
        fail("could not delete secret", status)
    }

default:
    fail("usage: cards-keychain set|get|delete")
}
