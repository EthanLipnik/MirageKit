//
//  MiragePointerLockWindowInstaller.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/1/26.
//

#if os(iOS)
import GameController
import SwiftUI
import UIKit

private final class MiragePointerLockRootController: UIViewController {
    private let contentController: UIViewController
    nonisolated(unsafe) private var mouseConnectObserver: NSObjectProtocol?
    nonisolated(unsafe) private var mouseDisconnectObserver: NSObjectProtocol?
    nonisolated(unsafe) private var pollTimer: Timer?

    var pointerLockRequested: Bool = false {
        didSet {
            guard pointerLockRequested != oldValue else { return }
            updatePointerLockEvaluation()
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

    private var hasUsableMouseInput: Bool {
        GCMouse.mice().contains { $0.mouseInput != nil }
    }

    override var prefersPointerLocked: Bool {
        pointerLockRequested && hasUsableMouseInput
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

        mouseConnectObserver = NotificationCenter.default.addObserver(
            forName: .GCMouseDidConnect,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updatePointerLockEvaluation()
        }
        mouseDisconnectObserver = NotificationCenter.default.addObserver(
            forName: .GCMouseDidDisconnect,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updatePointerLockEvaluation()
        }
    }

    deinit {
        pollTimer?.invalidate()
        if let mouseConnectObserver {
            NotificationCenter.default.removeObserver(mouseConnectObserver)
        }
        if let mouseDisconnectObserver {
            NotificationCenter.default.removeObserver(mouseDisconnectObserver)
        }
    }

    private func updatePointerLockEvaluation() {
        setNeedsUpdateOfPrefersPointerLocked()

        // Pointer lock state changes can lag behind preference updates during
        // scene/root-controller transitions, and GameController mouse-input
        // readiness can transiently disappear even while a Magic Keyboard
        // remains attached. Keep a lightweight poll active while lock is
        // requested so the scene can both acquire lock once deltas are ready
        // and automatically release it if usable mouse input disappears.
        if shouldKeepPointerLockPolling {
            startPollIfNeeded()
        } else {
            stopPoll()
        }
    }

    private var shouldKeepPointerLockPolling: Bool {
        pointerLockRequested || (view.window?.windowScene?.pointerLockState?.isLocked ?? false)
    }

    private func startPollIfNeeded() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            self.setNeedsUpdateOfPrefersPointerLocked()
            if !self.shouldKeepPointerLockPolling {
                timer.invalidate()
                self.pollTimer = nil
            }
        }
    }

    private func stopPoll() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}

private final class MiragePointerLockWindowInstallerController: UIViewController {
    private weak var installedRootController: MiragePointerLockRootController?

    var pointerLockRequested: Bool = false {
        didSet {
            applyPointerLockRootIfNeeded()
        }
    }

    deinit {
        clearPointerLockIfNeeded()
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

    func clearPointerLockIfNeeded() {
        installedRootController?.pointerLockRequested = false
    }

    private func applyPointerLockRootIfNeeded() {
        guard let window = view.window else { return }

        if let rootController = window.rootViewController as? MiragePointerLockRootController {
            installedRootController = rootController
            rootController.pointerLockRequested = pointerLockRequested
            return
        }

        guard let existingRootController = window.rootViewController else { return }
        guard existingRootController !== self else { return }

        let wrappedRootController = MiragePointerLockRootController(contentController: existingRootController)
        window.rootViewController = wrappedRootController
        installedRootController = wrappedRootController
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

    static func dismantleUIViewController(
        _ uiViewController: MiragePointerLockWindowInstallerController,
        coordinator: ()
    ) {
        uiViewController.clearPointerLockIfNeeded()
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
