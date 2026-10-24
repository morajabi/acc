import Foundation
import Security
import Testing
@testable import AccCore

/// Stands in for `/usr/bin/security`, recording its arguments and standard input.
private struct FakeSecurityTool {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("acc-security-" + UUID().uuidString)
    init(reply: String = "", exit: Int32 = 0, hang: Bool = false) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(reply.utf8).write(to: root.appendingPathComponent("reply"))
        let script = root.appendingPathComponent("security")
        try """
        #!/bin/sh
        printf '%s\\n' "$@" > '\(root.path)/args'
        cat > '\(root.path)/stdin'
        \(hang ? "exec sleep 30" : "")
        cat '\(root.path)/reply'
        exit \(exit)
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    }
    func keychain(interactive: Bool = true, unlocked: Bool = true) -> SecurityToolKeychain {
        SecurityToolKeychain(allowInteraction: interactive, executable: root.appendingPathComponent("security"),
            passiveTimeout: 0.2, isUnlocked: { unlocked })
    }
    var arguments: [String]? {
        (try? String(contentsOf: root.appendingPathComponent("args"), encoding: .utf8))?.split(separator: "\n").map(String.init)
    }
    var input: String { (try? String(contentsOf: root.appendingPathComponent("stdin"), encoding: .utf8)) ?? "" }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private let service = "Claude Code-credentials"

@Test func securityToolKeepsSmallSecretsOnStandardInput() throws {
    let tool = try FakeSecurityTool(); defer { tool.cleanup() }
    try tool.keychain().write(Data(#"{"a":1}"#.utf8), service: service, account: "mo")
    #expect(tool.arguments == ["-i"])
    #expect(tool.input == "add-generic-password -U -a \"mo\" -s \"Claude Code-credentials\" -X \"7b2261223a317d\"\n")
}

@Test func securityToolPassesOversizedSecretsAsArguments() throws {
    let tool = try FakeSecurityTool(); defer { tool.cleanup() }
    try tool.keychain().write(Data(repeating: 0x78, count: 2000), service: service, account: "mo")
    #expect(tool.arguments == ["add-generic-password", "-U", "-a", "mo", "-s", service, "-X", String(repeating: "78", count: 2000)])
    #expect(tool.input.isEmpty)
}

@Test func securityToolReadsPrintableAndHexPasswords() throws {
    let printable = try FakeSecurityTool(reply: "{\"a\":1}\n"); defer { printable.cleanup() }
    #expect(try printable.keychain().read(service: service, account: "mo") == Data(#"{"a":1}"#.utf8))
    #expect(printable.arguments == ["find-generic-password", "-a", "mo", "-s", service, "-w"])
    let hex = try FakeSecurityTool(reply: "7b2261223a0a317d\n"); defer { hex.cleanup() }
    #expect(try hex.keychain().read(service: service, account: "mo") == Data("{\"a\":\n1}".utf8))
}

@Test func securityToolTreatsMissingItemsAsAbsent() throws {
    let tool = try FakeSecurityTool(exit: 44); defer { tool.cleanup() }
    #expect(try tool.keychain().read(service: service, account: "mo") == nil)
    try tool.keychain().delete(service: service, account: "mo")
    #expect(tool.arguments == ["delete-generic-password", "-a", "mo", "-s", service])
}

@Test func securityToolReportsFailuresAsKeychainErrors() throws {
    for (exit, status) in [(36, errSecInteractionNotAllowed), (128, errSecUserCanceled), (1, 1)] as [(Int32, OSStatus)] {
        let tool = try FakeSecurityTool(exit: exit); defer { tool.cleanup() }
        #expect(throws: AccError.keychain(status)) { try tool.keychain().write(Data("x".utf8), service: service, account: "mo") }
    }
}

@Test func passiveSecurityToolNeverWaitsOnADialog() throws {
    let waiting = try FakeSecurityTool(hang: true); defer { waiting.cleanup() }
    let start = Date()
    #expect(throws: AccError.keychain(errSecInteractionNotAllowed)) {
        _ = try waiting.keychain(interactive: false).read(service: service, account: "mo")
    }
    #expect(Date().timeIntervalSince(start) < 5)
    let locked = try FakeSecurityTool(); defer { locked.cleanup() }
    #expect(throws: AccError.keychain(errSecInteractionNotAllowed)) {
        _ = try locked.keychain(interactive: false, unlocked: false).read(service: service, account: "mo")
    }
    #expect(locked.arguments == nil)
}
