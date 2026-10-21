import Foundation

/// The helper script that installs a downloaded update. The running app
/// cannot replace its own bundle, so it starts this script detached and
/// quits. The script waits for the app to exit, mounts the DMG, swaps the
/// bundle with a backup to roll back to, strips the quarantine flag and
/// relaunches the app.
enum SelfUpdateScript {
    /// POSIX single-quote escaping: wrap in '...', close, escape and reopen
    /// around embedded quotes.
    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func make(
        bundlePath: String,
        dmgPath: String,
        workDir: String,
        pid: Int32,
        appName: String = "Monibar.app"
    ) -> String {
        let mount = (workDir as NSString).appendingPathComponent("mount")
        let log = (workDir as NSString).appendingPathComponent("install.log")
        let backup = bundlePath + ".monibar-update-backup"
        return """
        #!/bin/zsh
        set -eu
        exec >\(quote(log)) 2>&1

        BUNDLE=\(quote(bundlePath))
        BACKUP=\(quote(backup))
        MOUNT=\(quote(mount))
        DMG=\(quote(dmgPath))
        WORK=\(quote(workDir))
        NEW="$MOUNT/"\(quote(appName))

        # Wait for the app (pid \(pid)) to exit, up to 10 s.
        for _ in {1..100}; do
            kill -0 \(pid) 2>/dev/null || break
            sleep 0.1
        done

        mkdir -p "$MOUNT"
        hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT" "$DMG"

        # Never remove the installed app for a DMG without a valid app inside.
        if [ ! -x "$NEW/Contents/MacOS/Monibar" ]; then
            hdiutil detach "$MOUNT" || true
            echo "Bad DMG: no \(appName) inside" >&2
            exit 1
        fi

        # Move the old bundle aside, copy the new one in, and put the old
        # one back if the copy fails, so the app is never missing.
        rm -rf "$BACKUP"
        mv "$BUNDLE" "$BACKUP"
        if cp -R "$NEW" "$BUNDLE"; then
            rm -rf "$BACKUP"
        else
            rm -rf "$BUNDLE"
            mv "$BACKUP" "$BUNDLE"
            hdiutil detach "$MOUNT" || true
            echo "Copy failed, rolled back" >&2
            open "$BUNDLE"
            exit 1
        fi

        # Some nested files are read-only and make xattr complain; the flag
        # on the bundle itself is what Gatekeeper checks.
        xattr -dr com.apple.quarantine "$BUNDLE" 2>/dev/null || true
        hdiutil detach "$MOUNT" || true
        open "$BUNDLE"
        rm -rf "$WORK"
        """
    }
}
