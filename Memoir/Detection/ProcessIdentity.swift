import AppKit
import Darwin

/// Resolves a running process (often a helper) to the app the user knows.
enum ProcessIdentity {
    static func microphoneUser(pid: pid_t, bundleID: String?) -> MicrophoneUser {
        let responsible = responsiblePID(for: pid)
        let parent = parentPID(of: pid)
        let responsibleApp = responsible.flatMap { NSRunningApplication(processIdentifier: $0) }
        let enclosingBundleID = executablePath(of: pid)
            .flatMap(MeetingApps.outermostAppBundle(inExecutablePath:))
            .flatMap { Bundle(path: $0)?.bundleIdentifier }

        let candidates: [String?] = [
            bundleID,
            responsibleApp?.bundleIdentifier,
            enclosingBundleID,
            parent.flatMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier },
        ]
        if let app = MeetingApps.resolve(candidates) {
            return MicrophoneUser(
                bundleID: app.bundleID,
                name: app.name,
                category: app.category == .meeting ? .meeting : .browser
            )
        }
        let owner = responsibleApp ?? NSRunningApplication(processIdentifier: pid)
        let ownerID = owner?.bundleIdentifier ?? enclosingBundleID ?? bundleID ?? "pid.\(pid)"
        return MicrophoneUser(bundleID: ownerID, name: owner?.localizedName ?? ownerID, category: .other)
    }

    // Not in the public headers, but exported by libsystem and stable for years. It is the
    // only reliable way to attribute XPC services such as Safari's shared WebKit GPU process,
    // whose parent is launchd and whose bundle says nothing about the app it serves.
    private typealias ResponsibleFunction = @convention(c) (pid_t) -> pid_t
    private static let responsibleFunction: ResponsibleFunction? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")
        else { return nil }
        return unsafeBitCast(symbol, to: ResponsibleFunction.self)
    }()

    private static func responsiblePID(for pid: pid_t) -> pid_t? {
        guard let responsibleFunction else { return nil }
        let result = responsibleFunction(pid)
        return result > 0 && result != pid ? result : nil
    }

    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        let parent = pid_t(info.pbi_ppid)
        return parent > 1 ? parent : nil
    }

    private static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
