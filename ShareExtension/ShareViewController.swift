import UIKit
import Social
import UniformTypeIdentifiers

final class ShareViewController: SLComposeServiceViewController {
    private var postTask: Task<Void, Never>?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "存入墨砚"
        placeholder = "下次打开墨砚后，保存到当前笔记库的「收件箱」"
    }
    override func isContentValid() -> Bool { (contentText ?? "").utf8.count <= 8 * 1024 * 1024 }
    override func didSelectCancel() {
        postTask?.cancel()
        postTask = nil
        super.didSelectCancel()
    }
    override func didSelectPost() {
        let entered = contentText ?? ""
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        navigationItem.rightBarButtonItem?.isEnabled = false
        postTask?.cancel()
        postTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                var parts = entered.isEmpty ? [] : [entered]
                for provider in providers {
                    try Task.checkCancellation()
                    let isFileURL = provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                    let isWebURL = !isFileURL && provider.hasItemConformingToTypeIdentifier(UTType.url.identifier)
                    let isPlainText = provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
                    let type: String?
                    if isWebURL { type = UTType.url.identifier }
                    else if isPlainText { type = UTType.plainText.identifier }
                    else { type = nil }
                    guard let type else { continue }
                    let value: String = try await withCheckedThrowingContinuation { continuation in
                        provider.loadItem(forTypeIdentifier: type, options: nil) { item, error in
                            if let error { continuation.resume(throwing: error); return }
                            if let url = item as? URL {
                                if ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                                    continuation.resume(returning: url.absoluteString)
                                } else {
                                    continuation.resume(returning: "")
                                }
                            } else if let string = item as? String { continuation.resume(returning: string) }
                            else if let data = item as? Data, data.count <= 8 * 1024 * 1024, let string = String(data: data, encoding: .utf8) { continuation.resume(returning: string) }
                            else { continuation.resume(returning: "") }
                        }
                    }
                    if !value.isEmpty && !parts.contains(value) { parts.append(value) }
                }
                try Task.checkCancellation()
                let text = parts.joined(separator: "\n\n")
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ShareError.empty }
                guard text.utf8.count <= 8 * 1024 * 1024 else { throw ShareError.tooLarge }
                guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.inkstone.mobile") else { throw ShareError.unavailable }
                try await Task.detached(priority: .userInitiated) {
                    let inbox = root.appendingPathComponent("Inbox")
                    try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
                    let data = try JSONEncoder().encode(["text": text])
                    try data.write(to: inbox.appendingPathComponent(UUID().uuidString + ".json"), options: .atomic)
                }.value
                try Task.checkCancellation()
                extensionContext?.completeRequest(returningItems: nil)
            } catch is CancellationError {
                return
            } catch {
                navigationItem.rightBarButtonItem?.isEnabled = true
                let alert = UIAlertController(title: "未能保存", message: error.localizedDescription, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "继续编辑", style: .cancel))
                present(alert, animated: true)
            }
        }
    }
}
private enum ShareError: LocalizedError {
    case empty, tooLarge, unavailable
    var errorDescription: String? {
        switch self {
        case .empty: return "请选择文字或网页链接。"
        case .tooLarge: return "分享内容超过 8 MB，请缩短后重试。"
        case .unavailable: return "共享收件箱不可用，请检查应用的 App Groups 签名配置。"
        }
    }
}
