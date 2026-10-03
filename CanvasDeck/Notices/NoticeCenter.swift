import AppKit
import CanvasCore
import UserNotifications

/// The one queue every card posts to. Toasts on the canvas and,
/// while the window is not in front, macOS notifications show the same
/// notices: resolving or dismissing one removes both.
/// Settings → General → Notifications turns each part and the sound off.
@MainActor
final class NoticeCenter: NSObject {
    private(set) var queue = NoticeQueue()
    var onChange: (() -> Void)?
    /// A click on a notice, the toast's body or a macOS notification.
    var onOpen: ((Notice) -> Void)?
    /// Whether the canvas window is in front, so toasts are seen.
    var isInFront: () -> Bool = { true }

    private var ticker: Timer?
    private var authorization: Bool?

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func post(_ notice: Notice) {
        let replaced = queue.post(notice)
        removeFromMacOS(replaced)
        let inFront = isInFront()
        if inFront {
            if Settings.noticesOnCanvas, Settings.noticeSound { NSSound(named: Self.sound(for: notice.kind))?.play() }
        } else if Settings.noticesInMacOS {
            deliverToMacOS(notice)
        }
        changed()
    }

    func resolve(source: UUID) {
        let gone = queue.resolve(source: source)
        guard !gone.isEmpty else { return }
        removeFromMacOS(gone)
        changed()
    }

    func dismiss(_ id: UUID) {
        guard let gone = queue.dismiss(id) else { return }
        removeFromMacOS([gone])
        changed()
    }

    func hold(_ id: UUID, _ holding: Bool) {
        queue.hold(id, holding, at: Date())
        changed()
    }

    func open(_ id: UUID) {
        guard let notice = queue.notices.first(where: { $0.id == id }) else { return }
        // A card still waiting keeps its notice until it is answered.
        if !notice.sticky { dismiss(id) }
        onOpen?(notice)
    }

    private func changed() {
        let expiring = queue.notices.contains { $0.expiresAt != nil }
        if expiring, ticker == nil {
            let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            ticker = timer
        } else if !expiring {
            ticker?.invalidate()
            ticker = nil
        }
        onChange?()
    }

    private func tick() {
        let gone = queue.expire(at: Date())
        guard !gone.isEmpty else { return }
        removeFromMacOS(gone)
        changed()
    }

    static func sound(for kind: Notice.Kind) -> NSSound.Name {
        switch kind {
        case .waiting: "Glass"
        case .error: "Basso"
        case .done, .info: "Tink"
        }
    }

    // MARK: macOS

    private func deliverToMacOS(_ notice: Notice) {
        let center = UNUserNotificationCenter.current()
        let send = {
            let content = UNMutableNotificationContent()
            content.title = notice.title
            content.body = notice.text
            content.userInfo = ["notice": notice.id.uuidString]
            if Settings.noticeSound { content.sound = .default }
            center.add(UNNotificationRequest(identifier: notice.id.uuidString, content: content, trigger: nil))
        }
        if authorization == true { return send() }
        if authorization == false { return }
        // Asked the first time there is something to show.
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            DispatchQueue.main.async {
                self.authorization = granted
                if granted { send() }
            }
        }
    }

    private func removeFromMacOS(_ notices: [Notice]) {
        guard !notices.isEmpty else { return }
        let ids = notices.map(\.id.uuidString)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
    }
}

extension NoticeCenter: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let id = (response.notification.request.content.userInfo["notice"] as? String).flatMap(UUID.init(uuidString:))
        await MainActor.run {
            NSApp.activate()
            if let id { self.open(id) }
        }
    }

    /// In front, the toast is enough.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        []
    }
}
