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

        var description: String {
            switch self {
            case .notInBundle: "La mise à jour ne marche que pour l'app installée, pas un build de dev."
            case .translocated: "Déplacer Monibar dans le dossier Applications, puis réessayer."
            case .notWritable: "Monibar ne peut pas écrire dans son dossier d'installation."
            case .download(let status): "Le téléchargement a échoué (HTTP \(status.map(String.init) ?? "?"))."
            case .staging: "L'installation n'a pas pu être préparée."
            case .spawn: "L'installation n'a pas pu démarrer."
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
            return "Le téléchargement a échoué."
        }
    }

    /// The signing team of the running app, as `codesign -dv` prints it:
    /// "not set" for an ad hoc build.
    private static func runningTeamID() -> String {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let team = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
        else { return "not set" }
        return team
    }

    private static func install(dmgURL: URL) async throws {
        // A dev binary has no bundle to replace. A bundle launched from
        // the DMG or Downloads runs from a read-only translocated copy.
        let bundlePath = Bundle.main.bundlePath
        guard bundlePath.hasSuffix(".app"), Bundle.main.bundleIdentifier != nil else { throw Failure.notInBundle }
        guard !bundlePath.contains("/AppTranslocation/") else { throw Failure.translocated }
        let parent = (bundlePath as NSString).deletingLastPathComponent
        guard FileManager.default.isWritableFile(atPath: parent) else { throw Failure.notWritable }

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
            bundleID: Bundle.main.bundleIdentifier ?? "", teamID: runningTeamID()
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
