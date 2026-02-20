import SwiftUI
import AppKit
#if canImport(WebRTC)
import WebRTC
#endif

struct VideoSurfaceView: View {
    @EnvironmentObject var webRTCManager: WebRTCManager
    @EnvironmentObject var inputManager: InputManager

    let onReconnect: () -> Void

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black

#if canImport(WebRTC)
                if let videoView = webRTCManager.videoView {
                    VideoViewRepresentable(
                        videoView: videoView,
                        onMouseMove: { pointInView in
                            inputManager.handleVideoMouseMove(
                                pointInView: pointInView,
                                viewSize: geometry.size,
                                videoSize: currentVideoSize()
                            )
                        },
                        onMouseButton: { button, isDown, pointInView in
                            inputManager.handleVideoMouseButton(
                                button: button,
                                isDown: isDown,
                                pointInView: pointInView,
                                viewSize: geometry.size,
                                videoSize: currentVideoSize()
                            )
                        },
                        onScrollWheel: { deltaX, deltaY in
                            inputManager.handleVideoMouseScroll(deltaX: deltaX, deltaY: deltaY)
                        }
                    )
                        .frame(width: geometry.size.width, height: geometry.size.height)
                } else {
                    Text("No Video Stream")
                        .foregroundColor(.white)
                }
#else
                Text("WebRTC not installed")
                    .foregroundColor(.white)
#endif

                if webRTCManager.isConnecting || webRTCManager.isStreamStalled || (webRTCManager.hasEverConnectedToStream && !webRTCManager.isConnected) {
                    VStack(spacing: 10) {
                        Text(webRTCManager.isConnecting ? "Connecting…" : "Connection Lost")
                            .font(.headline)

                        if let reason = webRTCManager.lastDisconnectReason, !reason.isEmpty {
                            Text(reason)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }

                        Button("Reconnect") {
                            onReconnect()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(webRTCManager.isConnecting)
                    }
                    .padding(14)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                }
            }
        }
    }

    private func currentVideoSize() -> CGSize? {
        guard let size = webRTCManager.videoSize, size.width > 0, size.height > 0 else {
            return nil
        }
        return size
    }
}

#if canImport(WebRTC)
struct VideoViewRepresentable: NSViewRepresentable {
    let videoView: RTCMTLNSVideoView
    let onMouseMove: (CGPoint) -> Void
    let onMouseButton: (MouseButton, Bool, CGPoint) -> Void
    let onScrollWheel: (CGFloat, CGFloat) -> Void

    func makeNSView(context: Context) -> TrackingContainerView {
        let container = TrackingContainerView()
        container.onMouseMove = onMouseMove
        container.onMouseButton = onMouseButton
        container.onScrollWheel = onScrollWheel
        container.embedVideoViewIfNeeded(videoView)
        return container
    }

    func updateNSView(_ nsView: TrackingContainerView, context: Context) {
        nsView.onMouseMove = onMouseMove
        nsView.onMouseButton = onMouseButton
        nsView.onScrollWheel = onScrollWheel
        nsView.embedVideoViewIfNeeded(videoView)
    }
}

final class TrackingContainerView: NSView {
    var onMouseMove: ((CGPoint) -> Void)?
    var onMouseButton: ((MouseButton, Bool, CGPoint) -> Void)?
    var onScrollWheel: ((CGFloat, CGFloat) -> Void)?

    private var trackingAreaRef: NSTrackingArea?
    private var lastMoveTimestamp: TimeInterval = 0

    private weak var embeddedVideoView: RTCMTLNSVideoView?
    private var embeddedConstraints: [NSLayoutConstraint] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        self
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }

        let options: NSTrackingArea.Options = [
            .activeInKeyWindow,
            .inVisibleRect,
            .mouseMoved,
        ]
        let area = NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingAreaRef = area
    }

    func embedVideoViewIfNeeded(_ videoView: RTCMTLNSVideoView) {
        guard embeddedVideoView !== videoView else { return }

        if !embeddedConstraints.isEmpty {
            NSLayoutConstraint.deactivate(embeddedConstraints)
            embeddedConstraints.removeAll()
        }

        embeddedVideoView?.removeFromSuperview()
        embeddedVideoView = videoView

        videoView.removeFromSuperview()
        addSubview(videoView)

        videoView.translatesAutoresizingMaskIntoConstraints = false
        embeddedConstraints = [
            videoView.leadingAnchor.constraint(equalTo: leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: trailingAnchor),
            videoView.topAnchor.constraint(equalTo: topAnchor),
            videoView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ]
        NSLayoutConstraint.activate(embeddedConstraints)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)

        let minInterval = 1.0 / 120.0
        let ts = event.timestamp
        if ts - lastMoveTimestamp < minInterval {
            return
        }
        lastMoveTimestamp = ts

        let p = convert(event.locationInWindow, from: nil)
        let flipped = CGPoint(x: p.x, y: bounds.height - p.y)
        onMouseMove?(flipped)
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        let p = convert(event.locationInWindow, from: nil)
        let flipped = CGPoint(x: p.x, y: bounds.height - p.y)
        onMouseButton?(.left, true, flipped)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        let p = convert(event.locationInWindow, from: nil)
        let flipped = CGPoint(x: p.x, y: bounds.height - p.y)
        onMouseButton?(.left, false, flipped)
    }

    override func rightMouseDown(with event: NSEvent) {
        super.rightMouseDown(with: event)
        let p = convert(event.locationInWindow, from: nil)
        let flipped = CGPoint(x: p.x, y: bounds.height - p.y)
        onMouseButton?(.right, true, flipped)
    }

    override func rightMouseUp(with event: NSEvent) {
        super.rightMouseUp(with: event)
        let p = convert(event.locationInWindow, from: nil)
        let flipped = CGPoint(x: p.x, y: bounds.height - p.y)
        onMouseButton?(.right, false, flipped)
    }

    override func otherMouseDown(with event: NSEvent) {
        super.otherMouseDown(with: event)
        guard event.buttonNumber == 2 else { return }
        let p = convert(event.locationInWindow, from: nil)
        let flipped = CGPoint(x: p.x, y: bounds.height - p.y)
        onMouseButton?(.middle, true, flipped)
    }

    override func otherMouseUp(with event: NSEvent) {
        super.otherMouseUp(with: event)
        guard event.buttonNumber == 2 else { return }
        let p = convert(event.locationInWindow, from: nil)
        let flipped = CGPoint(x: p.x, y: bounds.height - p.y)
        onMouseButton?(.middle, false, flipped)
    }

    override func mouseDragged(with event: NSEvent) {
        super.mouseDragged(with: event)
        let p = convert(event.locationInWindow, from: nil)
        let flipped = CGPoint(x: p.x, y: bounds.height - p.y)
        onMouseMove?(flipped)
    }

    override func rightMouseDragged(with event: NSEvent) {
        super.rightMouseDragged(with: event)
        let p = convert(event.locationInWindow, from: nil)
        let flipped = CGPoint(x: p.x, y: bounds.height - p.y)
        onMouseMove?(flipped)
    }

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        onScrollWheel?(event.scrollingDeltaX, event.scrollingDeltaY)
    }
}
#endif
