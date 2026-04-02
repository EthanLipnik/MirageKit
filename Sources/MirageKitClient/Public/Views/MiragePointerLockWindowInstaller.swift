//
//  MiragePointerLockWindowInstaller.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/1/26.
//

#if os(iOS)
import SwiftUI
import UIKit

private final class MiragePointerLockRootController: UIViewController {
    private let contentController: UIViewController

    var pointerLockRequested: Bool = false {
        didSet {
            guard pointerLockRequested != oldValue else { return }
            setNeedsUpdateOfPrefersPointerLocked()
        }
    }

    init(contentController: UIViewController) {
        self.contentController = contentController
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var prefersPointerLocked: Bool {
        pointerLockRequested
    }

    override var childForStatusBarStyle: UIViewController? {
        contentController
    }

    override var childForStatusBarHidden: UIViewController? {
        contentController
    }

    override var childForHomeIndicatorAutoHidden: UIViewController? {
        contentController
    }

    override var childForScreenEdgesDeferringSystemGestures: UIViewController? {
        contentController
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(contentController)
        contentController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(contentController.view)
        NSLayoutConstraint.activate([
            contentController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentController.view.topAnchor.constraint(equalTo: view.topAnchor),
            contentController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        contentController.didMove(toParent: self)
    }
}

private final class MiragePointerLockWindowInstallerController: UIViewController {
    var pointerLockRequested: Bool = false {
        didSet {
            applyPointerLockRootIfNeeded()
        }
    }

    override func loadView() {
        view = UIView(frame: .zero)
        view.isHidden = true
        view.isUserInteractionEnabled = false
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        applyPointerLockRootIfNeeded()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        applyPointerLockRootIfNeeded()
    }

    private func applyPointerLockRootIfNeeded() {
        guard let window = view.window else { return }

        if let rootController = window.rootViewController as? MiragePointerLockRootController {
            rootController.pointerLockRequested = pointerLockRequested
            return
        }

        guard let existingRootController = window.rootViewController else { return }
        guard existingRootController !== self else { return }

        let wrappedRootController = MiragePointerLockRootController(contentController: existingRootController)
        window.rootViewController = wrappedRootController
        wrappedRootController.pointerLockRequested = pointerLockRequested
    }
}

private struct MiragePointerLockWindowInstallerRepresentable: UIViewControllerRepresentable {
    let pointerLockRequested: Bool

    func makeUIViewController(context: Context) -> MiragePointerLockWindowInstallerController {
        let controller = MiragePointerLockWindowInstallerController()
        controller.pointerLockRequested = pointerLockRequested
        return controller
    }

    func updateUIViewController(
        _ uiViewController: MiragePointerLockWindowInstallerController,
        context: Context
    ) {
        uiViewController.pointerLockRequested = pointerLockRequested
    }
}

public struct MiragePointerLockWindowInstaller: View {
    let pointerLockRequested: Bool

    public init(pointerLockRequested: Bool) {
        self.pointerLockRequested = pointerLockRequested
    }

    public var body: some View {
        MiragePointerLockWindowInstallerRepresentable(pointerLockRequested: pointerLockRequested)
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
    }
}
#endif
