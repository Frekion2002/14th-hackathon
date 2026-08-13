//
//  CollogApp.swift
//  Collog
//
//  Created by 심재현 on 8/13/26.
//

import SwiftUI
import UIKit

// PushKit 토큰은 앱 실행 초기에 등록해야 백그라운드 수신이 안정적이다.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        VoipCallCenter.shared.start()
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        VoipCallCenter.shared.setRemoteNotificationToken(deviceToken)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        VoipCallCenter.shared.log("APNs 등록 실패: \(error.localizedDescription)")
    }
}

@main
struct CollogApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
