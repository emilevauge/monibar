import Foundation

/// The helper script that installs a downloaded update. The running app
/// cannot replace its own bundle, so it starts this script detached and
/// quits. The script waits for the app to exit, mounts the DMG, checks that
/// the new app satisfies the running app's designated requirement (same
/// bundle id, signed with the same certificate), swaps the bundle with a
/// backup to roll back to, strips the quarantine flag and relaunches the
/// app. Whatever fails, the installed app is put back and relaunched.
enum SelfUpdateScript {
    /// POSIX single-quote escaping: wrap in '...', close, escape and reopen
    /// around embedded quotes.
    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// `requirement`: the running app's designated requirement, as
    /// `codesign -d -r-` prints it. The new app must satisfy it.
    static func make(
        bundlePath: String,
        dmgPath: String,
        workDir: String,
        pid: Int32,
        requirement: String,
        appName: String = "Monibar.app"
    ) -> String {
        let mount = (workDir as NSString).appendingPathComponent("mount")
        let log = (workDir as NSString).appendingPathComponent("install.log")
        let backup = bundlePath + ".monibar-update-backup"
        return """
        #!/bin/zsh
        set -u
        exec >\(quote(log)) 2>&1

        BUNDLE=\(quote(bundlePath))
        BACKUP=\(quote(backup))
        MOUNT=\(quote(mount))
        DMG=\(quote(dmgPath))
        WORK=\(quote(workDir))
        NEW="$MOUNT/"\(quote(appName))

        # Puts the installed app back if it was moved aside, relaunches it
        # and stops: Monibar has quit already and must not stay gone.
        fail() {
            echo "Update failed: $1" >&2
            hdiutil detach "$MOUNT" -quiet 2>/dev/null
            if [ ! -d "$BUNDLE" ] && [ -d "$BACKUP" ]; then mv "$BACKUP" "$BUNDLE"; fi
            open "$BUNDLE"
            exit 1
        }

        # Wait for the app (pid \(pid)) to exit, up to 10 s, then stop it:
        # opening the bundle while it runs would only bring the old one forward.
        for _ in {1..100}; do
            kill -0 \(pid) 2>/dev/null || break
            sleep 0.1
        done
        if kill -0 \(pid) 2>/dev/null; then
            kill \(pid); sleep 1
            kill -9 \(pid) 2>/dev/null
        fi

        mkdir -p "$MOUNT" || fail "no mount point"
        hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT" "$DMG" || fail "cannot mount the DMG"

        # Never replace the installed app with something that is not Monibar
        # signed with the same certificate: the quarantine flag is removed
        # below, so Gatekeeper would not check it.
        [ -x "$NEW/Contents/MacOS/Monibar" ] || fail "no \(appName) in the DMG"
        codesign --verify --deep --strict -R=\(quote(requirement)) "$NEW" || fail "signature does not match the installed app"

        # Move the old bundle aside and copy the new one in; `fail` puts the
        # old one back if the copy fails, so the app is never missing.
        rm -rf "$BACKUP"
        mv "$BUNDLE" "$BACKUP" || fail "cannot move the installed app"
        if ! cp -R "$NEW" "$BUNDLE"; then
            rm -rf "$BUNDLE"
            fail "copy failed"
        fi
        rm -rf "$BACKUP"

        # Some nested files are read-only and make xattr complain; the flag
        # on the bundle itself is what Gatekeeper checks.
        xattr -dr com.apple.quarantine "$BUNDLE" 2>/dev/null
        hdiutil detach "$MOUNT" -quiet
        open "$BUNDLE"
        rm -rf "$WORK"
        """
    }
}
