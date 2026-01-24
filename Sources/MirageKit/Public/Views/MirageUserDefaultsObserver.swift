//
//  MirageUserDefaultsObserver.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/23/26.
//

import Foundation

final class MirageUserDefaultsObserver {
    private var observer: NSObjectProtocol?

    func start(onChange: @escaping () -> Void) {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            onChange()
        }
    }

    func stop() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
    }

    deinit {
        stop()
    }
}
