import ExpoModulesCore
import BackgroundTasks
import UIKit

// Registers the BGAppRefreshTask handler at the correct lifecycle point.
// BGTaskScheduler.shared.register(...) MUST be called before
// applicationDidFinishLaunching returns — it cannot be called lazily from
// the JS side or from OnCreate. ExpoAppDelegateSubscriber guarantees this.
public class ExpoOneBoxAppDelegateSubscriber: ExpoAppDelegateSubscriber {

    public func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        BackgroundConfigRefresh.registerHandler()
        return true
    }
}
