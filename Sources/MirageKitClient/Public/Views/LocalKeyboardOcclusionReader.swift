//
//  LocalKeyboardOcclusionReader.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/9/26.
//

#if os(iOS)
import SwiftUI
import UIKit

struct LocalKeyboardOcclusionReader: UIViewRepresentable {
    let minimumOcclusionHeight: CGFloat
    let onOcclusionChanged: @MainActor (CGFloat) -> Void

    func makeUIView(context _: Context) -> LocalKeyboardOcclusionReaderView {
        let view = LocalKeyboardOcclusionReaderView()
        view.minimumOcclusionHeight = minimumOcclusionHeight
        view.onOcclusionChanged = onOcclusionChanged
        return view
    }

    func updateUIView(_ uiView: LocalKeyboardOcclusionReaderView, context _: Context) {
        uiView.minimumOcclusionHeight = minimumOcclusionHeight
        uiView.onOcclusionChanged = onOcclusionChanged
        uiView.publishOcclusionIfNeeded()
    }
}

@MainActor
final class LocalKeyboardOcclusionReaderView: UIView {
    var minimumOcclusionHeight: CGFloat = 120 {
        didSet {
            guard minimumOcclusionHeight != oldValue else { return }
            publishOcclusionIfNeeded()
        }
    }

    var onOcclusionChanged: (@MainActor (CGFloat) -> Void)?

    private let keyboardFrameView = UIView()
    private var lastPublishedOcclusionHeight: CGFloat?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        keyboardFrameView.isHidden = true
        keyboardFrameView.isUserInteractionEnabled = false
        keyboardFrameView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(keyboardFrameView)

        keyboardLayoutGuide.followsUndockedKeyboard = true
        NSLayoutConstraint.activate([
            keyboardFrameView.leadingAnchor.constraint(equalTo: keyboardLayoutGuide.leadingAnchor),
            keyboardFrameView.trailingAnchor.constraint(equalTo: keyboardLayoutGuide.trailingAnchor),
            keyboardFrameView.topAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor),
            keyboardFrameView.bottomAnchor.constraint(equalTo: keyboardLayoutGuide.bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        publishOcclusionIfNeeded()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        publishOcclusionIfNeeded()
    }

    func publishOcclusionIfNeeded() {
        guard window != nil,
              bounds.width > 0,
              bounds.height > 0 else {
            publishOcclusionHeight(0)
            return
        }

        let occlusionHeight = localKeyboardOcclusionHeight(
            keyboardFrame: keyboardFrameView.frame,
            occlusionBounds: bounds,
            minimumOcclusionHeight: minimumOcclusionHeight
        )
        publishOcclusionHeight(occlusionHeight)
    }

    private func publishOcclusionHeight(_ occlusionHeight: CGFloat) {
        let normalizedOcclusionHeight = max(0, occlusionHeight)
        if let lastPublishedOcclusionHeight,
           abs(lastPublishedOcclusionHeight - normalizedOcclusionHeight) < 0.5 {
            return
        }
        lastPublishedOcclusionHeight = normalizedOcclusionHeight
        onOcclusionChanged?(normalizedOcclusionHeight)
    }
}
#endif
