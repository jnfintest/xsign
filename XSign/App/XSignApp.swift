import SwiftUI
import BackgroundTasks
import UserNotifications

@main
struct XSignApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .preferredColorScheme(model.settings.appearance.colorScheme)
                .tint(Theme.accent)
                .onOpenURL { model.handle(url: $0) }
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:
                Task { await model.refreshAll() }
            case .background:
                UpdateScheduler.schedule()
            default:
                break
            }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UpdateScheduler.register()
        UpdateNotifier.registerCategories()
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard
            let idString = response.notification.request.content.userInfo["itemID"] as? String,
            let id = UUID(uuidString: idString)
        else { return }
        let wantsUpdate = response.actionIdentifier == UpdateNotifier.updateActionID
        await MainActor.run {
            let model = AppModel.shared
            model.selectedTab = .home
            if wantsUpdate, let pending = model.pendingUpdates.first(where: { $0.item.id == id }) {
                model.update(pending)
            }
        }
    }
}

/// Periodic background check (iOS decides the exact timing).
enum UpdateScheduler {
    static let taskID = "com.jnfintest.xsign.refresh"

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskID, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { return }
            schedule()
            let work = Task { @MainActor in
                let fresh = await AppModel.shared.refreshAll()
                await UpdateNotifier.notify(about: fresh)
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = { work.cancel() }
        }
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: taskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 2 * 60 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}
