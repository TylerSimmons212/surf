import Foundation
import SurfCore

/// Renames a finished download to something worth keeping.
///
/// The impure half of `AIDownloadNaming`, and the mover of the actual file.
/// Runs strictly after the download is complete and provenance-tagged — a
/// rename is cosmetic, and nothing about a download's integrity should ever
/// wait on a model call.
///
/// The extension is never the model's to choose: whatever comes back is a
/// base name, and the file keeps the extension it arrived with. If anything
/// at all goes wrong — model declines, file moved, name collides badly — the
/// download simply keeps its name, which is never wrong, only worse.
@MainActor
enum AIDownloadRenamer {

    /// Renames the item's file if the feature is on and the model has a
    /// better idea. Updates the item in place so the panel follows the file.
    static func renameIfEnabled(_ item: DownloadItem) {
        guard AIPreferences.isEnabled(.downloadRenaming) else { return }
        guard case .finished(let location) = item.state else { return }
        // Before the CLI is even woken up. A name somebody chose on purpose is
        // not an input to this feature — see `isAlreadyWellNamed`.
        guard !AIDownloadNaming.isAlreadyWellNamed(location.lastPathComponent) else {
            debugLog("download: kept \(location.lastPathComponent) — already well named")
            return
        }

        Task {
            await AICLIDetector.shared.ensureScanned()
            guard let (provider, model) = AIPreferences.resolved(.downloadRenaming) else {
                return
            }
            guard let executable =
                AICLIDetector.shared.status(provider).executableURL ?? nil else { return }

            let prompt = AIDownloadNaming.prompt(
                filename: location.lastPathComponent,
                sourceURL: (item.sourceURL ?? item.pageURL)?.absoluteString ?? ""
            )
            guard let raw = await AIOneShot.ask(
                executable: executable, provider: provider, model: model.id, prompt: prompt
            ) else { return }
            guard let newName = AIDownloadNaming.filename(
                from: raw, originalFilename: location.lastPathComponent
            ) else { return }

            // The world may have moved on while the model thought: the user
            // can have moved, deleted, or opened-and-saved the file. Rename
            // only the exact file that finished, where it finished.
            guard FileManager.default.fileExists(atPath: location.path) else { return }
            guard case .finished(let current) = item.state, current == location else { return }

            let destination = uniqueURL(
                in: location.deletingLastPathComponent(), named: newName
            )
            do {
                try FileManager.default.moveItem(at: location, to: destination)
            } catch {
                return
            }

            item.filename = destination.lastPathComponent
            item.destinationURL = destination
            item.state = .finished(destination)
        }
    }

    /// Same collision policy as `DownloadManager`: count up, never overwrite.
    private static func uniqueURL(in directory: URL, named name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = directory.appendingPathComponent(name)
        var counter = 2

        while FileManager.default.fileExists(atPath: candidate.path) {
            let numbered = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            candidate = directory.appendingPathComponent(numbered)
            counter += 1
        }
        return candidate
    }
}
