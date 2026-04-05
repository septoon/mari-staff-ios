//
//  mari_staff_iosApp.swift
//  mari-staff-ios
//
//  Created by Тигран Дарчинян on 05.04.2026.
//

import SwiftUI

@main
struct MariStaffApp: App {
    @StateObject private var configuration: AppConfigurationStore

    init() {
        _configuration = StateObject(wrappedValue: AppConfigurationStore())
    }

    var body: some Scene {
        WindowGroup {
            ContentView(configuration: configuration)
        }
    }
}
