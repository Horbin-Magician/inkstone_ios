import UIKit
import Social
import UniformTypeIdentifiers

final class ShareViewController: SLComposeServiceViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "存入墨砚"
        placeholder = "下次打开墨砚后，保存到当前笔记库的「收件箱」"
    }
    override func isContentValid() -> Bool { (contentText ?? "").utf8.count < 8 * 1024 * 1024 }
    override func didSelectPost() {
        let entered = contentText ?? ""
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        navigationItem.rightBarButtonItem?.isEnabled = false
        Task { @MainActor in
            do {
                var parts = entered.isEmpty ? [] : [entered]
                for provider in providers {
                    let type = provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) ? UTType.url.identifier : UTType.plainText.identifier
                    guard provider.hasItemConformingToTypeIdentifier(type) else { continue }
                    let value: String = try await withCheckedThrowingContinuation { continuation in
                        provider.loadItem(forTypeIdentifier: type, options: nil) { item, error in
                            if let error { continuation.resume(throwing: error); return }
                            if let url = item as? URL { continuation.resume(returning: url.absoluteString) }
                            else if let string = item as? String { continuation.resume(returning: string) }
                            else if let data = item as? Data, let string = String(data: data, encoding: .utf8) { continuation.resume(returning: string) }
                            else { continuation.resume(returning: "") }
                        }
                    }
                    if !value.isEmpty && !parts.contains(value) { parts.append(value) }
                }
                let text = parts.joined(separator: "\n\n")
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ShareError.empty }
                guard text.utf8.count <= 8 * 1024 * 1024 else { throw ShareError.tooLarge }
                guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.inkstone.mobile") else { throw ShareError.unavailable }
                let inbox = root.appendingPathComponent("Inbox")
                try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
                let data = try JSONEncoder().encode(["text": text])
                try data.write(to: inbox.appendingPathComponent(UUID().uuidString + ".json"), options: .atomic)
                extensionContext?.completeRequest(returningItems: nil)
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
