import ExpoModulesCore
import BackgroundTasks
import UIKit

// 在正确的生命周期点注册 BGAppRefreshTask handler。
// BGTaskScheduler.shared.register(...) 必须在 applicationDidFinishLaunching
// 返回之前调用——不能从 JS 侧或 OnCreate 里延迟调用。
// ExpoAppDelegateSubscriber 保证了这一点。
public class ExpoOneBoxAppDelegateSubscriber: ExpoAppDelegateSubscriber {

    public func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        BackgroundConfigRefresh.registerHandler()
        return true
    }
}
