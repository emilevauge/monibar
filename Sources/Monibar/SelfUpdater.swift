import AppKit


/// Installs an update from its DMG, adapted from Calbar. The app cannot
/// replace its own bundle while it runs, so it downloads the DMG, writes
/// the helper script of `SelfUpdateScript` next to it, starts the script
/// detached and quits. The script swaps the bundle, keeping a backup until
/// the copy succeeded, removes the quarantine flag and relaunches Monibar.
@MainActor
enum SelfUpdater {
    enum Failure: Error, CustomStringConvertible {
        case notInBundle
        case translocated
        case notWritable
        case download(Int?)
        case staging
        case spawn
        case unsigned

        var description: String {
            switch self {
            case .notInBundle: String(localized: "Updates only work for the installed app, not a dev build.")
            case .translocated: String(localized: "Move Monibar to the Applications folder, then try again.")
            case .notWritable: String(localized: "Monibar cannot write to its install folder.")
            case .download(let status): String(localized: "The download failed (HTTP \(status.map(String.init) ?? "?")).")
            case .staging: String(localized: "The install could not be prepared.")
            case .spawn: String(localized: "The install could not start.")
            case .unsigned: String(localized: "This copy of Monibar is not signed, so the update could not be verified.")
            }
        }
    }

    /// Returns a message when the update could not start. On success Monibar
    /// quits and the helper takes over, so there is nothing to return.
    @discardableResult
    static func run(dmgURL: URL) async -> String? {
        do {
            try await install(dmgURL: dmgURL)
            return nil
        } catch let failure as Failure {
            NSLog("Monibar: update failed: %@", failure.description)
            return failure.description
        } catch {
            NSLog("Monibar: update failed: %@", "\(error)")
            return String(localized: "The download failed.")
        }
    }

    /// The running app's designated requirement: its bundle id and the
    /// certificate it is signed with. Nil for an unsigned or ad hoc build,
    /// which then cannot update itself.
    static func designatedRequirement() -> String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var requirement: SecRequirement?
        var text: CFString?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess, let requirement,
              SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text
        else { return nil }
        let string = text as String
        // Ad hoc signatures only pin their own hash: no update could match.
        return string.contains("cdhash") ? nil : string
    }

    private static func install(dmgURL: URL) async throws {
        // A dev binary has no bundle to replace. A bundle launched from
        // the DMG or Downloads runs from a read-only translocated copy.
        let bundlePath = Bundle.main.bundlePath
        guard bundlePath.hasSuffix(".app"), Bundle.main.bundleIdentifier != nil else { throw Failure.notInBundle }
        guard !bundlePath.contains("/AppTranslocation/") else { throw Failure.translocated }
        let parent = (bundlePath as NSString).deletingLastPathComponent
        guard FileManager.default.isWritableFile(atPath: parent) else { throw Failure.notWritable }
        guard let requirement = designatedRequirement() else { throw Failure.unsigned }

        let workDir = (NSTemporaryDirectory() as NSString).appendingPathComponent("monibar-update-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(atPath: workDir, withIntermediateDirectories: true)
        } catch {
            throw Failure.staging
        }

        let dmgPath = (workDir as NSString).appendingPathComponent(UpdateChecker.assetName)
        let (downloaded, response) = try await URLSession.shared.download(from: dmgURL)
        let status = (response as? HTTPURLResponse)?.statusCode
        guard status == 200 else { throw Failure.download(status) }
        do {
            try FileManager.default.moveItem(at: downloaded, to: URL(fileURLWithPath: dmgPath))
        } catch {
            throw Failure.staging
        }

        let scriptPath = (workDir as NSString).appendingPathComponent("install.sh")
        let script = SelfUpdateScript.make(
            bundlePath: bundlePath, dmgPath: dmgPath, workDir: workDir,
            pid: ProcessInfo.processInfo.processIdentifier,
            requirement: requirement
        )
        do {
            try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        } catch {
            throw Failure.staging
        }
        guard chmod(scriptPath, 0o755) == 0 else { throw Failure.staging }

        // Detached: the child is reparented to launchd when Monibar quits.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [scriptPath]
        process.standardInput = nil
        process.standardOutput = nil
        process.standardError = nil
        do {
            try process.run()
        } catch {
            throw Failure.spawn
        }
        NSLog("Monibar: update helper started, quitting")
        NSApp.terminate(nil)
    }
}
