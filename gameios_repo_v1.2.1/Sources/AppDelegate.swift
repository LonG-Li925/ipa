//
//  AppDelegate.swift
//

import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // 游戏全程保持屏幕常亮
        application.isIdleTimerDisabled = true

        let window = UIWindow(frame: UIScreen.main.bounds)
        window.backgroundColor = .black
        window.rootViewController = GameViewController()
        window.makeKeyAndVisible()
        self.window = window
        return true
    }

    func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
        print("[app] memory warning")
    }
}
