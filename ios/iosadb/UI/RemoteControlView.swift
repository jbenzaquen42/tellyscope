import SwiftUI
import UIKit
import OSLog

struct RemoteControlView: View {
    private let orientationLogger = Logger(
        subsystem: "com.tvadb.ios",
        category: "LiveScreenOrientation"
    )
    private enum GestureDirection {
        case up
        case down
        case left
        case right
    }

    @EnvironmentObject private var model: AppModel
    @AppStorage(TVADBPreferences.remoteControlOrderKey)
    private var remoteControlOrderRawValue =
        TVADBPreferences.defaultRemoteControlOrderRawValue
    @State private var controlMode =
        TVADBPreferences.remoteControlOrder.first ?? .gestures
    @State private var liveScreenControlMode =
        TVADBPreferences.liveScreenControlMode
    @State private var liveScreenOrientationRawValue =
        LiveScreenOrientationPreference.automatic.rawValue
    @State private var feedbackToken = 0
    @State private var activeGestureDirection: GestureDirection?
    @State private var televisionSize = CGSize(width: 1920, height: 1080)
    @State private var mousePosition = CGPoint(x: 960, y: 540)
    @State private var lastMouseTranslation = CGSize.zero
    @State private var lastMouseDispatch = Date.distantPast
    @State private var gesturePadIsActive = false
    @State private var liveScreenZoom: CGFloat = 1
    @State private var liveScreenOffset = CGSize.zero
    @State private var liveScreenTouchStart: CGPoint?
    @State private var liveScreenLastPanLocation: CGPoint?
    @State private var liveScreenLongDragStart: CGPoint?
    @State private var liveScreenLongDragLastLocation: CGPoint?
    @State private var isLiveScreenFullScreen = false
    @State private var fullScreenControlsExpanded = false
    @State private var isRemoteKeyboardPresented = false
    @State private var remoteKeyboardText = ""
    @State private var isSendingRemoteText = false
    @State private var orientationBeforeFullScreen: UIInterfaceOrientation?
    @State private var orientationTransitionTask: Task<Void, Never>?
    @State private var androidScreenRotation: Int?
    @State private var screenCoordinateSyncTask: Task<Void, Never>?
    @FocusState private var remoteKeyboardIsFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 14) {
                    deviceStatus
                    if model.isScreenRecording {
                        recordingStatus
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    Group {
                        modePicker

                        Group {
                            switch controlMode {
                            case .gestures:
                                gesturePad
                                    .transition(.scale(scale: 0.96).combined(with: .opacity))
                            case .screen:
                                liveScreenPanel
                                    .transition(.scale(scale: 0.96).combined(with: .opacity))
                            case .mouse:
                                mousePad
                                    .transition(.scale(scale: 0.96).combined(with: .opacity))
                            case .buttons:
                                directionPad
                                    .transition(.scale(scale: 0.96).combined(with: .opacity))
                            }
                        }
                        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: controlMode)

                        controlSection("text.navigation", subtitle: "text.common_tv_controls") {
                            LazyVGrid(columns: controlColumns, spacing: 12) {
                                remoteCard("arrow.uturn.backward", "text.back", 4)
                                remoteCard("house.fill", "text.home", 3)
                                remoteCard("rectangle.stack.fill", "text.recent", 187)
                            }
                        }

                        controlSection("text.volume_shortcuts", subtitle: "text.tap_a_control_to_operate_the_tv") {
                            LazyVGrid(columns: controlColumns, spacing: 12) {
                                remoteCard("speaker.minus.fill", "text.volume_894c630e", 25)
                                remoteCard("speaker.slash.fill", "text.mute", 164)
                                remoteCard("speaker.plus.fill", "text.volume", 24)
                                remoteCard("line.3.horizontal", "text.menu", 82)
                                remoteCard("power", "text.power", 26, tint: .red)
                            }
                        }
                    }
                    .allowsHitTesting(!model.isScreenRecording || model.isScreenRecordingReady)
                    .opacity(
                        model.isScreenRecording && !model.isScreenRecordingReady
                            ? 0.58
                            : 1
                    )
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 88)
            }
            .scrollDisabled(gesturePadIsActive)
            .navigationTitle("text.tv_remote")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                TVADBDisconnectToolbarItem()
            }
            .background(Color(.systemGroupedBackground))
            .sensoryFeedback(.impact(weight: .light), trigger: feedbackToken)
            .animation(
                .spring(response: 0.34, dampingFraction: 0.84),
                value: model.isScreenRecordingReady
            )
            .task(id: mouseConfigurationID) {
                let configurationID = mouseConfigurationID
                gesturePadIsActive = false
                switch controlMode {
                case .screen:
                    model.ensureMousePreview()
                    televisionSize =
                        await model.prepareTouchscreenControl()
                    guard !Task.isCancelled,
                          configurationID == mouseConfigurationID else {
                        return
                    }
                    if liveScreenControlMode == .mouse {
                        resetMousePosition()
                    }
                    androidScreenRotation =
                        await model.televisionScreenRotation()
                case .mouse:
                    screenCoordinateSyncTask?.cancel()
                    releaseInterfaceOrientationLock()
                    model.stopMousePreview()
                    await prepareMouse()
                case .gestures, .buttons:
                    screenCoordinateSyncTask?.cancel()
                    releaseInterfaceOrientationLock()
                    await model.stopMouseControl()
                }
                guard !Task.isCancelled,
                      configurationID == mouseConfigurationID else {
                    return
                }
            }
            .onDisappear {
                gesturePadIsActive = false
                guard !isLiveScreenFullScreen else { return }
                screenCoordinateSyncTask?.cancel()
                releaseInterfaceOrientationLock()
                Task {
                    await model.stopMouseControl()
                }
            }
        }
        .fullScreenCover(isPresented: $isLiveScreenFullScreen) {
            fullScreenLiveScreen
        }
        .onChange(of: isLiveScreenFullScreen) { _, isPresented in
            handleFullScreenPresentationChange(isPresented)
        }
        .onChange(of: currentLiveScreenSourceSize) { oldSize, newSize in
            handleLiveScreenSourceSizeChange(
                from: oldSize,
                to: newSize
            )
        }
    }

    private var recordingStatus: some View {
        TVADBPanel {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.red.opacity(0.12))
                        .frame(width: 38, height: 38)
                    if model.isScreenRecordingReady {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 10, height: 10)
                            .shadow(color: .red.opacity(0.45), radius: 6)
                    } else {
                        ProgressView()
                            .tint(TVADBTheme.accent)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(
                        LocalizedStringKey(
                            model.isScreenRecordingReady
                                ? "text.screen_recording_in_progress"
                                : "text.preparing_screen_recording"
                        )
                    )
                    .font(.subheadline.weight(.semibold))
                    Text(
                        LocalizedStringKey(
                            model.isScreenRecordingReady
                                ? "text.remote_actions_are_now_being_recorded"
                                : "text.wait_until_recording_is_ready"
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(11)
        }
    }

    private var deviceStatus: some View {
        TVADBPanel {
            HStack(spacing: 13) {
                Image(systemName: "tv.fill")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(TVADBTheme.accentGradient, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(connectedName)
                        .font(.headline)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Circle()
                            .fill(TVADBTheme.status)
                            .frame(width: 7, height: 7)
                        Text("text.connected")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "wifi")
                    .foregroundStyle(TVADBTheme.accent)
            }
            .padding(11)
        }
    }

    private var modePicker: some View {
        Picker("text.mode", selection: $controlMode) {
            ForEach(orderedControlModes) { mode in
                Label(mode.title, systemImage: mode.systemImage)
                    .tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .padding(5)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onChange(of: controlMode) { _, mode in
            feedbackToken += 1
        }
        .onChange(of: remoteControlOrderRawValue) {
            controlMode = orderedControlModes.first ?? .gestures
        }
    }

    private var orderedControlModes: [RemoteControlMode] {
        TVADBPreferences.remoteControlOrder(from: remoteControlOrderRawValue)
    }

    private var mouseConfigurationID: String {
        "\(controlMode.rawValue):\(liveScreenControlMode.rawValue)"
    }

    private var directionPad: some View {
        ZStack {
            Circle()
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.10), radius: 24, y: 12)
            Circle()
                .strokeBorder(.white.opacity(0.36), lineWidth: 1)
            Circle()
                .strokeBorder(TVADBTheme.accent.opacity(0.10), lineWidth: 18)
                .frame(width: 138, height: 138)

            directionButton("chevron.up", 19)
                .offset(y: -80)
            directionButton("chevron.down", 20)
                .offset(y: 80)
            directionButton("chevron.left", 21)
                .offset(x: -80)
            directionButton("chevron.right", 22)
                .offset(x: 80)

            Button { send(23) } label: {
                Text(verbatim: "OK")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                    .frame(width: 72, height: 72)
                    .background(TVADBTheme.accentGradient, in: Circle())
                    .overlay { Circle().strokeBorder(.white.opacity(0.34)) }
                    .shadow(color: TVADBTheme.accent.opacity(0.34), radius: 14, y: 8)
            }
            .buttonStyle(TVADBPressableStyle(scale: 0.92))
            .accessibilityLabel("text.confirm")
        }
        .frame(width: 258, height: 258)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
    }

    private var gesturePad: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.09), radius: 24, y: 12)
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .strokeBorder(.white.opacity(0.36))

            gestureArrow("chevron.up", direction: .up)
                .offset(y: -150)
            gestureArrow("chevron.down", direction: .down)
                .offset(y: 150)
            gestureArrow("chevron.left", direction: .left)
                .offset(x: -128)
            gestureArrow("chevron.right", direction: .right)
                .offset(x: 128)

            VStack(spacing: 11) {
                Image(systemName: "hand.draw.fill")
                    .font(.system(size: 42, weight: .medium))
                    .foregroundStyle(TVADBTheme.accentGradient)
                Text("text.swipe_to_navigate_tap_to_confirm")
                    .font(.subheadline.weight(.semibold))
                Text("text.tap_or_swipe")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(height: 380)
        .contentShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
        .onTapGesture {
            activeGestureDirection = nil
            send(23)
        }
        .highPriorityGesture(
            DragGesture(minimumDistance: 12)
                .onChanged { value in
                    gesturePadIsActive = true
                    withAnimation(.easeOut(duration: 0.12)) {
                        activeGestureDirection = gestureDirection(for: value.translation)
                    }
                }
                .onEnded { value in
                    if let direction = gestureDirection(for: value.translation) {
                        send(keyCode(for: direction))
                    }
                    withAnimation(.easeOut(duration: 0.18)) {
                        activeGestureDirection = nil
                    }
                    gesturePadIsActive = false
                }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("text.remote_gesture_area")
        .accessibilityHint("text.tap_to_confirm_swipe_up_down_left_or_right_to_navigate")
    }

    private var mousePad: some View {
        GeometryReader { proxy in
            ZStack {
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(.regularMaterial)
                    .shadow(color: .black.opacity(0.09), radius: 24, y: 12)
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .strokeBorder(TVADBTheme.accent.opacity(0.18))

                if model.mouseMoveUnavailable && !model.mouseClickUnavailable {
                    coordinateTouchIndicator(in: proxy.size)
                        .allowsHitTesting(false)
                }

                VStack(spacing: 10) {
                    Image(
                        systemName: model.mouseClickUnavailable
                            ? "rectangle.and.hand.point.up.left.filled"
                            : model.nativeMouseInputActive
                                ? "cursorarrow.rays"
                                : "cursorarrow.motionlines"
                    )
                        .font(.system(size: 38, weight: .medium))
                        .foregroundStyle(TVADBTheme.accentGradient)
                    Text(mousePadTitle)
                        .font(.subheadline.weight(.semibold))
                    Text(mousePadSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if model.nativeMouseInputActive {
                        Label(
                            model.physicalHIDMouseActive
                                ? "text.physical_hid_mouse_active"
                                : "text.system_mouse_input_active",
                            systemImage: "checkmark.circle.fill"
                        )
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(TVADBTheme.status)
                    }

                }
                .allowsHitTesting(false)

                VStack {
                    Spacer()
                    HStack(spacing: 8) {
                        Button {
                            resetMousePosition(movePointer: true)
                        } label: {
                            Label("text.center", systemImage: "scope")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(.thinMaterial, in: Capsule())
                        }
                        Spacer()
                        if model.nativeMouseInputActive {
                            Button {
                                toggleMouseDrag()
                            } label: {
                                Label(
                                    model.mouseDragActive
                                        ? "text.release_drag"
                                        : "text.drag_lock",
                                    systemImage: model.mouseDragActive
                                        ? "hand.raised.fill"
                                        : "hand.draw.fill"
                                )
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .foregroundStyle(
                                    model.mouseDragActive
                                        ? Color.white
                                        : TVADBTheme.accent
                                )
                                .background(
                                    model.mouseDragActive
                                        ? AnyShapeStyle(TVADBTheme.accentGradient)
                                        : AnyShapeStyle(TVADBTheme.accent.opacity(0.14)),
                                    in: Capsule()
                                )
                            }
                            .accessibilityHint("text.drag_lock_hint")
                        } else {
                            Button {
                                doubleClickMouse()
                            } label: {
                                Label("text.double_click", systemImage: "hand.tap.fill")
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(TVADBTheme.accent.opacity(0.14), in: Capsule())
                            }
                        }
                        Menu {
                            if model.mouseMoveUnavailable && !model.mouseClickUnavailable {
                                Button {
                                    Task { await model.setShowTouches(true) }
                                } label: {
                                    Label("text.show_tap_locations", systemImage: "eye")
                                }
                                Button {
                                    Task { await model.setShowTouches(false) }
                                } label: {
                                    Label("text.hide_tap_locations", systemImage: "eye.slash")
                                }
                                Divider()
                            }
                            Button {
                                doubleClickMouse()
                            } label: {
                                Label("text.double_click", systemImage: "hand.tap.fill")
                            }
                            Button {
                                rightClickMouse()
                            } label: {
                                Label("text.right_click", systemImage: "arrowshape.turn.up.left.fill")
                            }
                            Button {
                                middleClickMouse()
                            } label: {
                                Label("text.middle_click", systemImage: "button.programmable")
                            }
                            Divider()
                            Button {
                                scrollMouse(amount: 1)
                            } label: {
                                Label("text.scroll_up", systemImage: "arrow.up")
                            }
                            Button {
                                scrollMouse(amount: -1)
                            } label: {
                                Label("text.scroll_down", systemImage: "arrow.down")
                            }
                        } label: {
                            Label("text.more", systemImage: "ellipsis")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(.thinMaterial, in: Capsule())
                        }
                    }
                    .padding(14)
                }

                // Keep one explicit interaction surface above the decorative
                // content. A fully transparent view behind the labels may lose
                // the hit test in some iOS/SwiftUI combinations, which makes a
                // center tap appear to do nothing. The lower strip remains
                // available to the Center/Drag/More controls.
                VStack(spacing: 0) {
                    Rectangle()
                        .fill(Color.black.opacity(0.001))
                        .contentShape(Rectangle())
                        .highPriorityGesture(mouseDragGesture(in: proxy.size))
                        .simultaneousGesture(
                            mouseTapGesture(in: proxy.size)
                        )
                    Color.clear
                        .frame(height: 64)
                        .allowsHitTesting(false)
                }
                .clipShape(
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                )
            }
        }
        .frame(height: 380)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("text.mouse_trackpad")
    }

    private var liveScreenPanel: some View {
        GeometryReader { proxy in
            liveScreenCanvas(size: proxy.size, isFullScreen: false)
        }
        .frame(height: 380)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("text.interactive_live_screen")
    }

    private var fullScreenLiveScreen: some View {
        GeometryReader { proxy in
            ZStack {
                liveScreenCanvas(size: proxy.size, isFullScreen: true)
                fullScreenLiveControls
            }
        }
        .background(Color.black)
        .ignoresSafeArea()
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            model.ensureMousePreview()
        }
        .onDisappear {
            fullScreenControlsExpanded = false
            gesturePadIsActive = false
        }
        .onChange(of: liveScreenOrientationRawValue) {
            applyLiveScreenOrientation()
        }
        .onChange(of: detectedLiveScreenOrientation) {
            guard liveScreenOrientationPreference == .automatic else {
                return
            }
            applyLiveScreenOrientation()
        }
        .sheet(isPresented: $isRemoteKeyboardPresented) {
            remoteKeyboardSheet
        }
    }

    private func liveScreenCanvas(
        size: CGSize,
        isFullScreen: Bool
    ) -> some View {
        let controlsHeight: CGFloat = isFullScreen ? 0 : 64
        let interactionBounds = CGRect(
            x: 0,
            y: 0,
            width: size.width,
            height: max(size.height - controlsHeight, 1)
        )
        let previewImage = mousePreviewImage
        let hasVideo = model.mousePreviewHasVideoFrame
        let sourceSize =
            (hasVideo ? model.mousePreviewVideoSize : nil)
            ?? previewImage?.size
            ?? televisionSize
        let basePreviewRect = aspectFitRect(
            sourceSize: sourceSize,
            inside: interactionBounds.insetBy(
                dx: isFullScreen ? 0 : 8,
                dy: isFullScreen ? 0 : 8
            )
        )
        let displayRect = transformedLiveScreenRect(
            baseRect: basePreviewRect
        )

        return ZStack {
            if isFullScreen {
                Color.black
            } else {
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(Color.black)
                    .shadow(color: .black.opacity(0.12), radius: 24, y: 12)
            }

            // Keep the display layer alive before the first H.264 sample
            // arrives. Otherwise the initial IDR can be published before
            // SwiftUI creates this view, leaving the decoder with only P
            // frames until the next keyframe.
            H264VideoSurface(hub: model.mousePreviewVideoHub)
                .frame(
                    width: basePreviewRect.width,
                    height: basePreviewRect.height
                )
                .position(
                    x: basePreviewRect.midX,
                    y: basePreviewRect.midY
                )
                .scaleEffect(liveScreenZoom)
                .offset(liveScreenOffset)
                .opacity(hasVideo ? 1 : 0.001)
                .allowsHitTesting(false)

            if !hasVideo, let previewImage {
                Image(uiImage: previewImage)
                    .resizable()
                    .interpolation(.medium)
                    .frame(
                        width: basePreviewRect.width,
                        height: basePreviewRect.height
                    )
                    .position(
                        x: basePreviewRect.midX,
                        y: basePreviewRect.midY
                    )
                    .scaleEffect(liveScreenZoom)
                    .offset(liveScreenOffset)

            } else if !hasVideo {
                livePreviewPlaceholder
                    .frame(
                        width: interactionBounds.width,
                        height: interactionBounds.height
                    )
                    .position(
                        x: interactionBounds.midX,
                        y: interactionBounds.midY
                    )
                    .allowsHitTesting(false)
            }

            if (hasVideo || previewImage != nil),
               liveScreenControlMode == .mouse {
                livePreviewCursor(
                    in: displayRect,
                    sourceSize: sourceSize
                )
                .allowsHitTesting(false)
            }

            LiveScreenGestureLayer(
                onTap: { location in
                    handleLiveScreenTap(
                        location,
                        displayRect: displayRect,
                        sourceSize: sourceSize,
                        isDoubleTap: false
                    )
                },
                onDoubleTap: { location in
                    handleLiveScreenTap(
                        location,
                        displayRect: displayRect,
                        sourceSize: sourceSize,
                        isDoubleTap: true
                    )
                },
                onOneFingerPan: { phase, location in
                    handleLiveScreenPan(
                        phase: phase,
                        location: location,
                        displayRect: displayRect,
                        sourceSize: sourceSize
                    )
                },
                onOneFingerLongPressDrag: { phase, location in
                    handleLiveScreenLongPressDrag(
                        phase: phase,
                        location: location,
                        displayRect: displayRect,
                        sourceSize: sourceSize
                    )
                },
                onTwoFingerLongPress: {
                    feedbackToken += 1
                    send(82)
                },
                onThreeFingerPan: { translationY in
                    handleLiveScreenScroll(
                        translationY: translationY,
                        sourceSize: sourceSize
                    )
                },
                onPinch: { scale, location in
                    updateLiveScreenZoom(
                        by: scale,
                        anchor: location,
                        baseRect: basePreviewRect,
                        interactionBounds: interactionBounds
                    )
                },
                onViewportPan: { translation in
                    updateLiveScreenOffset(
                        by: translation,
                        baseRect: basePreviewRect,
                        interactionBounds: interactionBounds
                    )
                },
                onTouchActivityChanged: { isActive in
                    gesturePadIsActive = isActive
                }
            )
            .frame(
                width: interactionBounds.width,
                height: interactionBounds.height
            )
            .position(
                x: interactionBounds.midX,
                y: interactionBounds.midY
            )
            .allowsHitTesting(hasVideo || previewImage != nil)

            if !isFullScreen {
                regularLiveScreenControls
            }
        }
        .clipShape(
            RoundedRectangle(
                cornerRadius: isFullScreen ? 0 : 30,
                style: .continuous
            )
        )
        .overlay {
            if !isFullScreen {
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .strokeBorder(TVADBTheme.accent.opacity(0.24))
            }
        }
    }

    private var regularLiveScreenControls: some View {
        VStack {
            Spacer()
            HStack(spacing: 7) {
                liveScreenModeButton(.touch)
                liveScreenModeButton(.mouse)

                Spacer(minLength: 0)

                if liveScreenZoom > 1.01 {
                    Button {
                        resetLiveScreenZoom()
                    } label: {
                        Text("\(liveScreenZoom, specifier: "%.1f")×")
                            .font(.caption.weight(.bold))
                            .frame(minWidth: 32, minHeight: 32)
                            .background(.white.opacity(0.14), in: Capsule())
                    }
                    .accessibilityLabel("text.reset_zoom")
                }

                liveScreenOrientationMenu(
                    buttonSize: 32,
                    showsBackground: true
                )

                Button {
                    isLiveScreenFullScreen = true
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.caption.weight(.bold))
                        .frame(width: 32, height: 32)
                        .background(.white.opacity(0.14), in: Circle())
                }
                .accessibilityLabel("text.enter_full_screen")

                Button {
                    model.startMousePreview()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption.weight(.bold))
                        .frame(width: 32, height: 32)
                        .background(.white.opacity(0.14), in: Circle())
                }
                .accessibilityLabel("text.refresh")
            }
            .foregroundStyle(.white)
            .padding(14)
            .background(
                LinearGradient(
                    colors: [.clear, .black.opacity(0.76)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
    }

    private var fullScreenLiveControls: some View {
        VStack {
            HStack {
                Spacer()
                Button {
                    isLiveScreenFullScreen = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(.black.opacity(0.52), in: Circle())
                }
                .accessibilityLabel("text.exit_full_screen")
            }

            Spacer()

            if fullScreenControlsExpanded {
                VStack(spacing: 8) {
                    HStack(spacing: 9) {
                        Button {
                            fullScreenControlsExpanded = false
                        } label: {
                            Image(systemName: "chevron.down")
                                .frame(width: 34, height: 34)
                        }
                        liveScreenModeButton(.touch)
                        liveScreenModeButton(.mouse)
                        liveScreenOrientationMenu(
                            buttonSize: 34,
                            showsTitle: true
                        )

                        if liveScreenZoom > 1.01 {
                            Button {
                                resetLiveScreenZoom()
                            } label: {
                                Image(systemName: "1.magnifyingglass")
                                    .frame(width: 34, height: 34)
                            }
                            .accessibilityLabel("text.reset_zoom")
                        }
                    }

                    HStack(spacing: 7) {
                        fullScreenQuickKey(
                            "arrow.uturn.backward",
                            title: "text.back",
                            code: 4
                        )
                        fullScreenQuickKey(
                            "house.fill",
                            title: "text.home",
                            code: 3
                        )
                        fullScreenQuickKey(
                            "line.3.horizontal",
                            title: "text.menu",
                            code: 82
                        )
                        Button {
                            remoteKeyboardText = ""
                            isRemoteKeyboardPresented = true
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: "keyboard")
                                    .font(.body.weight(.semibold))
                                Text("text.keyboard")
                                    .font(.caption2.weight(.semibold))
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, minHeight: 46)
                            .background(
                                Color.white.opacity(0.12),
                                in: RoundedRectangle(
                                    cornerRadius: 12,
                                    style: .continuous
                                )
                            )
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: 520)
                .foregroundStyle(.white)
                .background(
                    .black.opacity(0.68),
                    in: RoundedRectangle(
                        cornerRadius: 20,
                        style: .continuous
                    )
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                Button {
                    fullScreenControlsExpanded = true
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 54, height: 30)
                        .background(.black.opacity(0.62), in: Capsule())
                }
                .accessibilityLabel("text.show_screen_controls")
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 16)
        .safeAreaPadding(.top, 8)
        .safeAreaPadding(.bottom, 8)
        .animation(
            .spring(response: 0.3, dampingFraction: 0.84),
            value: fullScreenControlsExpanded
        )
    }

    private func fullScreenQuickKey(
        _ systemImage: String,
        title: LocalizedStringKey,
        code: Int
    ) -> some View {
        Button {
            send(code)
        } label: {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.body.weight(.semibold))
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 46)
            .background(
                Color.white.opacity(0.12),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
        }
    }

    private var remoteKeyboardSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text("text.remote_keyboard_hint")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                TextField(
                    "text.enter_text_for_tv",
                    text: $remoteKeyboardText,
                    axis: .vertical
                )
                .lineLimit(2...5)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.send)
                .focused($remoteKeyboardIsFocused)
                .padding(12)
                .background(
                    Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(
                        cornerRadius: 14,
                        style: .continuous
                    )
                )
                .onSubmit {
                    sendRemoteKeyboardText()
                }

                Button {
                    sendRemoteKeyboardText()
                } label: {
                    HStack {
                        if isSendingRemoteText {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Image(systemName: "paperplane.fill")
                        }
                        Text("text.send_to_tv")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(
                    remoteKeyboardText
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty
                        || isSendingRemoteText
                )

                Spacer(minLength: 0)
            }
            .padding(16)
            .navigationTitle("text.tv_keyboard")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("text.cancel") {
                        isRemoteKeyboardPresented = false
                    }
                    .disabled(isSendingRemoteText)
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(isSendingRemoteText)
        .onAppear {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                remoteKeyboardIsFocused = true
            }
        }
    }

    private func liveScreenOrientationMenu(
        buttonSize: CGFloat,
        showsBackground: Bool = false,
        showsTitle: Bool = false
    ) -> some View {
        Menu {
            ForEach(LiveScreenOrientationPreference.allCases) { preference in
                Button {
                    feedbackToken += 1
                    liveScreenOrientationRawValue = preference.rawValue
                    applyLiveScreenOrientation(preference)
                } label: {
                    Label(
                        preference.title,
                        systemImage:
                            liveScreenOrientationPreference == preference
                                ? "checkmark"
                                : preference.systemImage
                    )
                }
            }
        } label: {
            Group {
                if showsTitle {
                    Label(
                        "text.rotate_screen",
                        systemImage: "rectangle.landscape.rotate"
                    )
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.horizontal, 8)
                    .frame(height: buttonSize)
                } else {
                    Image(
                        systemName:
                            liveScreenOrientationPreference.systemImage
                    )
                    .font(.caption.weight(.bold))
                    .frame(width: buttonSize, height: buttonSize)
                }
            }
                .background(
                    showsBackground
                        ? Color.white.opacity(0.14)
                        : Color.clear,
                    in: Circle()
                )
        }
        .accessibilityLabel("text.screen_orientation")
    }

    private func liveScreenModeButton(
        _ mode: LiveScreenControlMode
    ) -> some View {
        Button {
            feedbackToken += 1
            liveScreenControlMode = mode
        } label: {
            Label(mode.title, systemImage: mode.systemImage)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .frame(height: 32)
                .foregroundStyle(
                    liveScreenControlMode == mode
                        ? Color.white
                        : Color.white.opacity(0.72)
                )
                .background(
                    liveScreenControlMode == mode
                        ? AnyShapeStyle(TVADBTheme.accentGradient)
                        : AnyShapeStyle(Color.white.opacity(0.12)),
                    in: Capsule()
                )
        }
    }

    private var mousePreviewImage: UIImage? {
        model.mousePreviewImage
    }

    private enum DetectedLiveScreenOrientation: Equatable {
        case portrait
        case landscape
    }

    private var liveScreenOrientationPreference:
        LiveScreenOrientationPreference {
        LiveScreenOrientationPreference(
            rawValue: liveScreenOrientationRawValue
        ) ?? .automatic
    }

    private var currentLiveScreenSourceSize: CGSize {
        (model.mousePreviewHasVideoFrame
            ? model.mousePreviewVideoSize
            : nil)
            ?? mousePreviewImage?.size
            ?? televisionSize
    }

    private var detectedLiveScreenOrientation:
        DetectedLiveScreenOrientation {
        let size = currentLiveScreenSourceSize
        return size.width >= size.height ? .landscape : .portrait
    }

    private var activeWindowScene: UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
    }

    private func applyLiveScreenOrientation(
        _ preference: LiveScreenOrientationPreference? = nil
    ) {
        let selectedPreference =
            preference ?? liveScreenOrientationPreference
        let orientationMask: UIInterfaceOrientationMask
        switch selectedPreference {
        case .automatic:
            orientationMask = detectedLiveScreenOrientation == .landscape
                ? .landscape
                : .portrait
        case .portrait:
            orientationMask = .portrait
        case .landscapeLeft:
            orientationMask = .landscapeLeft
        case .landscapeRight:
            orientationMask = .landscapeRight
        }
        orientationLogger.info(
            "Applying preference \(selectedPreference.rawValue, privacy: .public), mask \(orientationMask.rawValue)"
        )
        requestInterfaceOrientation(orientationMask)
    }

    private func handleFullScreenPresentationChange(_ isPresented: Bool) {
        orientationLogger.info(
            "Full-screen presentation changed: \(isPresented)"
        )
        orientationTransitionTask?.cancel()
        if isPresented {
            liveScreenOrientationRawValue =
                LiveScreenOrientationPreference.automatic.rawValue
            orientationBeforeFullScreen =
                activeWindowScene?.interfaceOrientation
            orientationLogger.info(
                "Saved previous orientation \(orientationBeforeFullScreen?.rawValue ?? -1)"
            )
            orientationTransitionTask = Task { @MainActor in
                // Wait for the cover transition before changing its geometry.
                try? await Task.sleep(for: .milliseconds(520))
                guard !Task.isCancelled else { return }
                orientationLogger.info(
                    "Full-screen presentation settled; applying orientation"
                )
                applyLiveScreenOrientation(.automatic)
            }
        } else {
            restoreOrientationAfterFullScreen()
        }
    }

    private func restoreOrientationAfterFullScreen() {
        guard let orientationBeforeFullScreen else {
            releaseInterfaceOrientationLock()
            return
        }
        self.orientationBeforeFullScreen = nil
        let orientationMask: UIInterfaceOrientationMask
        switch orientationBeforeFullScreen {
        case .portrait:
            orientationMask = .portrait
        case .portraitUpsideDown:
            orientationMask = .portraitUpsideDown
        case .landscapeLeft:
            orientationMask = .landscapeLeft
        case .landscapeRight:
            orientationMask = .landscapeRight
        default:
            orientationMask = .all
        }
        requestInterfaceOrientation(
            orientationMask,
            releaseOrientationLockAfterUpdate: true
        )
        orientationTransitionTask = Task { @MainActor in
            // UIKit can reject geometry changes while a full-screen cover is
            // still dismissing. Retry after the transition has settled.
            try? await Task.sleep(for: .milliseconds(420))
            guard !Task.isCancelled else { return }
            requestInterfaceOrientation(
                orientationMask,
                releaseOrientationLockAfterUpdate: true
            )
        }
    }

    private func requestInterfaceOrientation(
        _ orientationMask: UIInterfaceOrientationMask,
        releaseOrientationLockAfterUpdate: Bool = false
    ) {
        guard let scene = activeWindowScene else {
            orientationLogger.error(
                "No foreground window scene for orientation request"
            )
            return
        }
        TVADBAppDelegate.supportedInterfaceOrientations = orientationMask
        var viewController = scene.keyWindow?.rootViewController
        viewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        while let presentedViewController =
            viewController?.presentedViewController {
            presentedViewController
                .setNeedsUpdateOfSupportedInterfaceOrientations()
            viewController = presentedViewController
        }
        scene.requestGeometryUpdate(
            .iOS(interfaceOrientations: orientationMask)
        ) { error in
            self.orientationLogger.error(
                "Geometry update failed for mask \(orientationMask.rawValue): \(error.localizedDescription, privacy: .public)"
            )
        }
        guard releaseOrientationLockAfterUpdate else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            TVADBAppDelegate.supportedInterfaceOrientations = .all
            scene.keyWindow?.rootViewController?
                .setNeedsUpdateOfSupportedInterfaceOrientations()
        }
    }

    private func releaseInterfaceOrientationLock() {
        orientationTransitionTask?.cancel()
        TVADBAppDelegate.supportedInterfaceOrientations = .all
        guard let scene = activeWindowScene else { return }
        var viewController = scene.keyWindow?.rootViewController
        viewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        while let presentedViewController =
            viewController?.presentedViewController {
            presentedViewController
                .setNeedsUpdateOfSupportedInterfaceOrientations()
            viewController = presentedViewController
        }
    }

    private func handleLiveScreenSourceSizeChange(
        from oldSize: CGSize,
        to newSize: CGSize
    ) {
        guard controlMode == .screen,
              oldSize.width > 0,
              oldSize.height > 0,
              newSize.width > 0,
              newSize.height > 0,
              abs(oldSize.width - newSize.width) > 0.5
                || abs(oldSize.height - newSize.height) > 0.5 else {
            return
        }

        screenCoordinateSyncTask?.cancel()
        let previousRotation = androidScreenRotation
        screenCoordinateSyncTask = Task { @MainActor in
            let currentRotation =
                await model.televisionScreenRotation()
            guard !Task.isCancelled else { return }

            let mappedPosition = rotatedMousePosition(
                mousePosition,
                from: oldSize,
                to: newSize,
                oldRotation: previousRotation,
                newRotation: currentRotation
            )
            mousePosition = mappedPosition
            televisionSize = newSize
            lastMouseTranslation = .zero
            liveScreenLastPanLocation = nil
            liveScreenTouchStart = nil
            androidScreenRotation =
                currentRotation ?? previousRotation
        }
    }

    private func rotatedMousePosition(
        _ point: CGPoint,
        from oldSize: CGSize,
        to newSize: CGSize,
        oldRotation: Int?,
        newRotation: Int?
    ) -> CGPoint {
        let normalizedX = min(
            max(point.x / max(oldSize.width - 1, 1), 0),
            1
        )
        let normalizedY = min(
            max(point.y / max(oldSize.height - 1, 1), 0),
            1
        )

        let mapped: CGPoint
        if let oldRotation, let newRotation {
            switch (newRotation - oldRotation + 4) % 4 {
            case 1:
                mapped = CGPoint(
                    x: 1 - normalizedY,
                    y: normalizedX
                )
            case 2:
                mapped = CGPoint(
                    x: 1 - normalizedX,
                    y: 1 - normalizedY
                )
            case 3:
                mapped = CGPoint(
                    x: normalizedY,
                    y: 1 - normalizedX
                )
            default:
                mapped = CGPoint(
                    x: normalizedX,
                    y: normalizedY
                )
            }
        } else {
            mapped = CGPoint(x: normalizedX, y: normalizedY)
        }

        return CGPoint(
            x: mapped.x * max(newSize.width - 1, 0),
            y: mapped.y * max(newSize.height - 1, 0)
        )
    }

    @ViewBuilder
    private var livePreviewPlaceholder: some View {
        VStack(spacing: 12) {
            if model.mousePreviewIsLoading {
                ProgressView()
                    .tint(.white)
                Text("text.loading_live_screen")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
            } else {
                Image(systemName: "display.trianglebadge.exclamationmark")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(TVADBTheme.accent)
                Text("text.live_screen_unavailable")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text("text.tap_refresh_to_try_again")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.62))
            }
        }
    }

    private func livePreviewCursor(
        in previewRect: CGRect,
        sourceSize: CGSize
    ) -> some View {
        let width = max(sourceSize.width, 1)
        let height = max(sourceSize.height, 1)
        let x = previewRect.minX
            + min(max(mousePosition.x / width, 0), 1) * previewRect.width
        let y = previewRect.minY
            + min(max(mousePosition.y / height, 0), 1) * previewRect.height

        return Image(systemName: "cursorarrow")
            .font(.system(size: 25, weight: .bold))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.88), radius: 2, x: 1, y: 2)
            .position(x: x, y: y)
            .animation(.linear(duration: 0.045), value: mousePosition)
    }

    private func aspectFitRect(
        sourceSize: CGSize,
        inside bounds: CGRect
    ) -> CGRect {
        guard sourceSize.width > 0,
              sourceSize.height > 0,
              bounds.width > 0,
              bounds.height > 0 else {
            return bounds
        }
        let scale = min(
            bounds.width / sourceSize.width,
            bounds.height / sourceSize.height
        )
        let fittedSize = CGSize(
            width: sourceSize.width * scale,
            height: sourceSize.height * scale
        )
        return CGRect(
            x: bounds.midX - fittedSize.width / 2,
            y: bounds.midY - fittedSize.height / 2,
            width: fittedSize.width,
            height: fittedSize.height
        )
    }

    private func coordinateTouchIndicator(in padSize: CGSize) -> some View {
        let width = max(televisionSize.width, 1)
        let height = max(televisionSize.height, 1)
        let interactionHeight = max(padSize.height - 64, 1)
        let x = min(
            max(mousePosition.x / width * padSize.width, 14),
            max(padSize.width - 14, 14)
        )
        let y = min(
            max(mousePosition.y / height * interactionHeight, 14),
            max(interactionHeight - 14, 14)
        )

        return ZStack {
            Circle()
                .fill(TVADBTheme.accent.opacity(0.16))
                .frame(width: 28, height: 28)
            Circle()
                .fill(TVADBTheme.accent)
                .frame(width: 8, height: 8)
        }
        .position(x: x, y: y)
        .animation(.linear(duration: 0.06), value: mousePosition)
    }

    private func controlSection<Content: View>(
        _ title: LocalizedStringKey,
        subtitle: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func directionButton(_ icon: String, _ code: Int) -> some View {
        Button { send(code) } label: {
            Image(systemName: icon)
                .font(.title3.bold())
                .foregroundStyle(.primary)
                .frame(width: 52, height: 52)
                .background(.thinMaterial, in: Circle())
        }
        .buttonStyle(TVADBPressableStyle(scale: 0.9))
        .accessibilityLabel(directionLabel(for: code))
    }

    private func remoteCard(
        _ icon: String,
        _ title: LocalizedStringKey,
        _ code: Int,
        tint: Color = TVADBTheme.accent
    ) -> some View {
        Button { send(code) } label: {
            VStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.title3)
                    .frame(width: 42, height: 42)
                    .background(tint.opacity(0.13), in: Circle())
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 19, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 19, style: .continuous)
                    .strokeBorder(tint.opacity(0.10))
            }
        }
        .buttonStyle(TVADBPressableStyle())
    }

    private func gestureArrow(
        _ icon: String,
        direction: GestureDirection
    ) -> some View {
        let isActive = activeGestureDirection == direction
        return Image(systemName: icon)
            .font(.body.bold())
            .foregroundStyle(isActive ? TVADBTheme.accent : Color.secondary)
            .frame(width: 38, height: 38)
            .background(isActive ? TVADBTheme.accent.opacity(0.14) : Color.clear, in: Circle())
            .scaleEffect(isActive ? 1.12 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.72), value: isActive)
    }

    private var controlColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)
    }

    private var connectedName: String {
        if case .connected(let name) = model.connectionState { return name }
        return model.currentDevice?.name ?? "Android TV"
    }

    private func directionLabel(for code: Int) -> LocalizedStringKey {
        switch code {
        case 19: "text.up"
        case 20: "text.down"
        case 21: "text.left"
        default: "text.right"
        }
    }

    private func gestureDirection(for translation: CGSize) -> GestureDirection? {
        guard max(abs(translation.width), abs(translation.height)) > 18 else { return nil }
        if abs(translation.width) > abs(translation.height) {
            return translation.width > 0 ? .right : .left
        }
        return translation.height > 0 ? .down : .up
    }

    private func keyCode(for direction: GestureDirection) -> Int {
        switch direction {
        case .up: 19
        case .down: 20
        case .left: 21
        case .right: 22
        }
    }

    private func send(_ code: Int) {
        feedbackToken += 1
        Task { await model.sendRemoteKey(code) }
    }

    private func sendRemoteKeyboardText() {
        guard !isSendingRemoteText,
              !remoteKeyboardText
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty else {
            return
        }
        let text = remoteKeyboardText
        isSendingRemoteText = true
        remoteKeyboardIsFocused = false
        Task {
            let didSend = await model.sendRemoteText(text)
            isSendingRemoteText = false
            guard didSend else { return }
            remoteKeyboardText = ""
            isRemoteKeyboardPresented = false
        }
    }

    private func prepareMouse() async {
        televisionSize = await model.prepareMouseControl()
        resetMousePosition()
    }

    private func resetMousePosition(movePointer: Bool = false) {
        mousePosition = CGPoint(
            x: televisionSize.width * 0.5,
            y: televisionSize.height * 0.5
        )
        lastMouseTranslation = .zero
        if movePointer {
            let point = mousePosition
            Task {
                await model.moveMouse(to: point)
            }
        }
    }

    private var mousePadTitle: String {
        if model.mouseClickUnavailable {
            return L10n.string("text.button_compatibility_mode")
        }
        if model.mouseMoveUnavailable {
            return L10n.string("text.coordinate_touch_mode")
        }
        if model.nativeMouseInputActive {
            return L10n.string("text.swipe_to_move_the_native_pointer")
        }
        return L10n.string("text.swipe_to_move_tap_or_double_tap")
    }

    private var mousePadSubtitle: String {
        if model.mouseClickUnavailable {
            return L10n.string("text.tap_to_confirm_swipe_to_navigate_double_tap_to_confirm_twice")
        }
        if model.mouseMoveUnavailable {
            return L10n.string("text.the_tv_pointer_is_hidden_move_the_cursor_here_then_tap")
        }
        if model.nativeMouseInputActive {
            if model.physicalHIDMouseActive {
                return L10n.string(
                    "text.android_recognized_tvadb_as_a_physical_hid_mouse"
                )
            }
            return L10n.string("text.android_recognized_tvadb_as_a_virtual_mouse")
        }
        return L10n.string("text.the_tv_firmware_must_support_a_system_mouse_pointer")
    }

    private func clickMouse() {
        feedbackToken += 1
        Task {
            if model.mouseDragActive {
                await model.setMouseDragActive(false)
            } else {
                await model.clickMouse(at: mousePosition)
            }
        }
    }

    private func doubleClickMouse() {
        feedbackToken += 1
        Task {
            if model.mouseDragActive {
                await model.setMouseDragActive(false)
            } else {
                await model.doubleClickMouse(at: mousePosition)
            }
        }
    }

    private func toggleMouseDrag() {
        feedbackToken += 1
        Task {
            await model.setMouseDragActive(!model.mouseDragActive)
        }
    }

    private func rightClickMouse() {
        feedbackToken += 1
        Task {
            if model.mouseDragActive {
                await model.setMouseDragActive(false)
            }
            await model.rightClickMouse()
        }
    }

    private func middleClickMouse() {
        feedbackToken += 1
        Task {
            if model.mouseDragActive {
                await model.setMouseDragActive(false)
            }
            await model.middleClickMouse()
        }
    }

    private func scrollMouse(amount: Int) {
        feedbackToken += 1
        Task {
            await model.scrollMouse(amount: amount)
        }
    }

    private func transformedLiveScreenRect(baseRect: CGRect) -> CGRect {
        CGRect(
            x: baseRect.midX
                - baseRect.width * liveScreenZoom / 2
                + liveScreenOffset.width,
            y: baseRect.midY
                - baseRect.height * liveScreenZoom / 2
                + liveScreenOffset.height,
            width: baseRect.width * liveScreenZoom,
            height: baseRect.height * liveScreenZoom
        )
    }

    private func liveScreenPoint(
        for location: CGPoint,
        in displayRect: CGRect,
        sourceSize: CGSize,
        clampsToScreen: Bool
    ) -> CGPoint? {
        guard displayRect.width > 0, displayRect.height > 0 else {
            return nil
        }
        if !clampsToScreen && !displayRect.contains(location) {
            return nil
        }
        let normalizedX = min(
            max((location.x - displayRect.minX) / displayRect.width, 0),
            1
        )
        let normalizedY = min(
            max((location.y - displayRect.minY) / displayRect.height, 0),
            1
        )
        return CGPoint(
            x: normalizedX * max(sourceSize.width - 1, 0),
            y: normalizedY * max(sourceSize.height - 1, 0)
        )
    }

    private func handleLiveScreenTap(
        _ location: CGPoint,
        displayRect: CGRect,
        sourceSize: CGSize,
        isDoubleTap: Bool
    ) {
        switch liveScreenControlMode {
        case .mouse:
            // The live screen is a relative trackpad in mouse mode. Tapping
            // anywhere on the visible picture clicks the cursor's current
            // position; only dragging is allowed to move that cursor.
            guard displayRect.contains(location) else { return }
            let point = mousePosition
            feedbackToken += 1
            Task {
                if isDoubleTap {
                    await model.tapTouchscreen(at: point)
                    try? await Task.sleep(for: .milliseconds(120))
                    await model.tapTouchscreen(at: point)
                } else {
                    await model.tapTouchscreen(at: point)
                }
            }
        case .touch:
            // Touch mode maps the finger's absolute picture coordinate to the
            // Android display, matching a real touchscreen.
            guard let point = liveScreenPoint(
                for: location,
                in: displayRect,
                sourceSize: sourceSize,
                clampsToScreen: false
            ) else {
                return
            }
            feedbackToken += 1
            Task {
                await model.tapTouchscreen(at: point)
                if isDoubleTap {
                    try? await Task.sleep(for: .milliseconds(120))
                    await model.tapTouchscreen(at: point)
                }
            }
        }
    }

    private func handleLiveScreenPan(
        phase: LiveScreenPanPhase,
        location: CGPoint,
        displayRect: CGRect,
        sourceSize: CGSize
    ) {
        switch phase {
        case .began:
            liveScreenLastPanLocation = location
            liveScreenTouchStart = liveScreenPoint(
                for: location,
                in: displayRect,
                sourceSize: sourceSize,
                clampsToScreen: true
            )
        case .changed:
            if liveScreenControlMode == .mouse,
               let previousLocation = liveScreenLastPanLocation {
                updateLiveScreenMousePosition(
                    from: previousLocation,
                    to: location,
                    displayRect: displayRect,
                    sourceSize: sourceSize
                )
            }
            liveScreenLastPanLocation = location
        case .ended:
            if liveScreenControlMode == .touch,
               let start = liveScreenTouchStart,
                      let end = liveScreenPoint(
                        for: location,
                        in: displayRect,
                        sourceSize: sourceSize,
                        clampsToScreen: true
                      ),
                      hypot(end.x - start.x, end.y - start.y) >= 12 {
                Task {
                    await model.swipeTouchscreen(
                        from: start,
                        to: end
                    )
                }
            }
            liveScreenLastPanLocation = nil
            liveScreenTouchStart = nil
            lastMouseDispatch = .distantPast
        case .cancelled:
            liveScreenLastPanLocation = nil
            liveScreenTouchStart = nil
            lastMouseDispatch = .distantPast
        }
    }

    private func handleLiveScreenLongPressDrag(
        phase: LiveScreenPanPhase,
        location: CGPoint,
        displayRect: CGRect,
        sourceSize: CGSize
    ) {
        switch phase {
        case .began:
            feedbackToken += 1
            liveScreenLongDragLastLocation = location

            switch liveScreenControlMode {
            case .mouse:
                liveScreenLongDragStart = mousePosition
            case .touch:
                liveScreenLongDragStart = liveScreenPoint(
                    for: location,
                    in: displayRect,
                    sourceSize: sourceSize,
                    clampsToScreen: true
                )
            }

        case .changed:
            if liveScreenControlMode == .mouse,
               let previousLocation = liveScreenLongDragLastLocation {
                updateLiveScreenMousePosition(
                    from: previousLocation,
                    to: location,
                    displayRect: displayRect,
                    sourceSize: sourceSize
                )
            }
            liveScreenLongDragLastLocation = location

        case .ended:
            if liveScreenControlMode == .mouse,
               let previousLocation = liveScreenLongDragLastLocation {
                updateLiveScreenMousePosition(
                    from: previousLocation,
                    to: location,
                    displayRect: displayRect,
                    sourceSize: sourceSize
                )
            }

            let mode = liveScreenControlMode
            let start = liveScreenLongDragStart
            let end: CGPoint? = switch mode {
            case .mouse:
                mousePosition
            case .touch:
                liveScreenPoint(
                    for: location,
                    in: displayRect,
                    sourceSize: sourceSize,
                    clampsToScreen: true
                )
            }
            clearLiveScreenLongDragState()

            Task { @MainActor in
                // Screen control deliberately uses absolute Android display
                // coordinates for dragging in both modes. This works even
                // when the TV rejects a persistent HID/uinput mouse button.
                if let start, let end {
                    let distance = hypot(
                        end.x - start.x,
                        end.y - start.y
                    )
                    if mode == .mouse, distance < 12 {
                        // Some Android builds collapse a zero-distance
                        // `draganddrop` into a normal tap. Use an explicit
                        // held touchscreen gesture so a stationary press at
                        // the virtual cursor reliably opens context menus.
                        await model.longPressTouchscreen(at: end)
                    } else {
                        await model.dragTouchscreen(
                            from: start,
                            to: end
                        )
                    }
                }
            }

        case .cancelled:
            clearLiveScreenLongDragState()
        }
    }

    private func updateLiveScreenMousePosition(
        from previousLocation: CGPoint,
        to location: CGPoint,
        displayRect: CGRect,
        sourceSize: CGSize
    ) {
        let xScale = sourceSize.width / max(displayRect.width, 1)
        let yScale = sourceSize.height / max(displayRect.height, 1)
        mousePosition = CGPoint(
            x: min(
                max(
                    mousePosition.x
                        + (location.x - previousLocation.x) * xScale,
                    0
                ),
                max(sourceSize.width - 1, 0)
            ),
            y: min(
                max(
                    mousePosition.y
                        + (location.y - previousLocation.y) * yScale,
                    0
                ),
                max(sourceSize.height - 1, 0)
            )
        )
    }

    private func clearLiveScreenLongDragState() {
        liveScreenLongDragStart = nil
        liveScreenLongDragLastLocation = nil
        lastMouseDispatch = .distantPast
    }

    private func handleLiveScreenScroll(
        translationY: CGFloat,
        sourceSize: CGSize
    ) {
        guard abs(translationY) >= 28 else { return }
        feedbackToken += 1

        switch liveScreenControlMode {
        case .mouse:
            let centerX = min(
                max(mousePosition.x, 0),
                max(sourceSize.width - 1, 0)
            )
            let startY = translationY < 0
                ? sourceSize.height * 0.72
                : sourceSize.height * 0.28
            let endY = translationY < 0
                ? sourceSize.height * 0.28
                : sourceSize.height * 0.72
            Task {
                await model.swipeTouchscreen(
                    from: CGPoint(x: centerX, y: startY),
                    to: CGPoint(x: centerX, y: endY),
                    durationMilliseconds: 320
                )
            }
        case .touch:
            let centerX = sourceSize.width / 2
            let startY = translationY < 0
                ? sourceSize.height * 0.72
                : sourceSize.height * 0.28
            let endY = translationY < 0
                ? sourceSize.height * 0.28
                : sourceSize.height * 0.72
            Task {
                await model.swipeTouchscreen(
                    from: CGPoint(x: centerX, y: startY),
                    to: CGPoint(x: centerX, y: endY),
                    durationMilliseconds: 320
                )
            }
        }
    }

    private func updateLiveScreenZoom(
        by scale: CGFloat,
        anchor: CGPoint,
        baseRect: CGRect,
        interactionBounds: CGRect
    ) {
        let oldZoom = liveScreenZoom
        let newZoom = min(max(oldZoom * scale, 1), 4)
        guard abs(newZoom - oldZoom) > 0.0001 else { return }

        let oldCenter = CGPoint(
            x: baseRect.midX + liveScreenOffset.width,
            y: baseRect.midY + liveScreenOffset.height
        )
        let ratio = newZoom / oldZoom
        let proposedOffset = CGSize(
            width: anchor.x
                - (anchor.x - oldCenter.x) * ratio
                - baseRect.midX,
            height: anchor.y
                - (anchor.y - oldCenter.y) * ratio
                - baseRect.midY
        )
        liveScreenZoom = newZoom
        liveScreenOffset = clampedLiveScreenOffset(
            proposedOffset,
            scale: newZoom,
            baseRect: baseRect,
            interactionBounds: interactionBounds
        )
    }

    private func updateLiveScreenOffset(
        by translation: CGSize,
        baseRect: CGRect,
        interactionBounds: CGRect
    ) {
        guard liveScreenZoom > 1.01 else { return }
        liveScreenOffset = clampedLiveScreenOffset(
            CGSize(
                width: liveScreenOffset.width + translation.width,
                height: liveScreenOffset.height + translation.height
            ),
            scale: liveScreenZoom,
            baseRect: baseRect,
            interactionBounds: interactionBounds
        )
    }

    private func clampedLiveScreenOffset(
        _ proposedOffset: CGSize,
        scale: CGFloat,
        baseRect: CGRect,
        interactionBounds: CGRect
    ) -> CGSize {
        let scaledWidth = baseRect.width * scale
        let scaledHeight = baseRect.height * scale
        let horizontalLimit = max(
            0,
            (scaledWidth - interactionBounds.width) / 2
                + abs(baseRect.midX - interactionBounds.midX)
        )
        let verticalLimit = max(
            0,
            (scaledHeight - interactionBounds.height) / 2
                + abs(baseRect.midY - interactionBounds.midY)
        )
        return CGSize(
            width: min(max(proposedOffset.width, -horizontalLimit), horizontalLimit),
            height: min(max(proposedOffset.height, -verticalLimit), verticalLimit)
        )
    }

    private func resetLiveScreenZoom() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
            liveScreenZoom = 1
            liveScreenOffset = .zero
        }
    }

    private func mouseTapGesture(in padSize: CGSize) -> some Gesture {
        SpatialTapGesture(count: 2)
            .exclusively(before: SpatialTapGesture(count: 1))
            .onEnded { value in
                switch value {
                case .first(let tap):
                    updateCoordinateTouchPosition(
                        tap.location,
                        in: padSize
                    )
                    doubleClickMouse()
                case .second(let tap):
                    updateCoordinateTouchPosition(
                        tap.location,
                        in: padSize
                    )
                    clickMouse()
                }
            }
    }

    private func updateCoordinateTouchPosition(
        _ location: CGPoint,
        in padSize: CGSize
    ) {
        guard model.mouseMoveUnavailable else { return }
        let interactionHeight = max(padSize.height - 64, 1)
        mousePosition = CGPoint(
            x: min(
                max(location.x / max(padSize.width, 1) * televisionSize.width, 0),
                televisionSize.width - 1
            ),
            y: min(
                max(location.y / interactionHeight * televisionSize.height, 0),
                televisionSize.height - 1
            )
        )
    }

    private func mouseDragGesture(in padSize: CGSize) -> some Gesture {
        // Start on touch-down so the parent ScrollView is disabled before it
        // can claim the same pan gesture.
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                gesturePadIsActive = true
                if model.mouseMoveUnavailable {
                    updateCoordinateTouchPosition(
                        value.location,
                        in: padSize
                    )
                } else {
                    let delta = CGSize(
                        width: value.translation.width - lastMouseTranslation.width,
                        height: value.translation.height - lastMouseTranslation.height
                    )
                    lastMouseTranslation = value.translation
                    let xScale = televisionSize.width / max(padSize.width, 1) * 1.35
                    let yScale = televisionSize.height / max(padSize.height, 1) * 1.35
                    mousePosition = CGPoint(
                        x: min(max(mousePosition.x + delta.width * xScale, 0), televisionSize.width - 1),
                        y: min(max(mousePosition.y + delta.height * yScale, 0), televisionSize.height - 1)
                    )
                    dispatchMouseMoveIfNeeded()
                }
            }
            .onEnded { value in
                gesturePadIsActive = false
                lastMouseTranslation = .zero
                lastMouseDispatch = .distantPast
                if model.mouseClickUnavailable,
                   let direction = gestureDirection(for: value.translation) {
                    send(keyCode(for: direction))
                } else if !model.mouseMoveUnavailable {
                    Task { await model.moveMouse(to: mousePosition) }
                }
            }
    }

    private func dispatchMouseMoveIfNeeded() {
        guard !model.mouseMoveUnavailable else { return }
        let now = Date()
        guard now.timeIntervalSince(lastMouseDispatch) >= 0.025 else { return }
        lastMouseDispatch = now
        let point = mousePosition
        Task { await model.moveMouse(to: point) }
    }
}

private enum LiveScreenPanPhase {
    case began
    case changed
    case ended
    case cancelled
}

private struct LiveScreenGestureLayer: UIViewRepresentable {
    let onTap: (CGPoint) -> Void
    let onDoubleTap: (CGPoint) -> Void
    let onOneFingerPan: (LiveScreenPanPhase, CGPoint) -> Void
    let onOneFingerLongPressDrag: (LiveScreenPanPhase, CGPoint) -> Void
    let onTwoFingerLongPress: () -> Void
    let onThreeFingerPan: (CGFloat) -> Void
    let onPinch: (CGFloat, CGPoint) -> Void
    let onViewportPan: (CGSize) -> Void
    let onTouchActivityChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true
        view.isUserInteractionEnabled = true
        view.accessibilityLabel = L10n.string("text.interactive_live_screen")

        let singleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleSingleTap(_:))
        )
        singleTap.numberOfTapsRequired = 1
        singleTap.numberOfTouchesRequired = 1

        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        doubleTap.numberOfTouchesRequired = 1
        singleTap.require(toFail: doubleTap)

        let oneFingerPan = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleOneFingerPan(_:))
        )
        oneFingerPan.minimumNumberOfTouches = 1
        oneFingerPan.maximumNumberOfTouches = 1

        let oneFingerLongPressDrag = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(
                Coordinator.handleOneFingerLongPressDrag(_:)
            )
        )
        oneFingerLongPressDrag.minimumPressDuration = 0.38
        oneFingerLongPressDrag.allowableMovement = 30
        oneFingerLongPressDrag.numberOfTouchesRequired = 1

        // A screen swipe must never be interpreted as the click that follows
        // a mouse-up event. Let the pan recognizer make the first decision;
        // a stationary touch still lets the tap recognizers proceed.
        singleTap.require(toFail: oneFingerPan)
        doubleTap.require(toFail: oneFingerPan)
        singleTap.require(toFail: oneFingerLongPressDrag)
        doubleTap.require(toFail: oneFingerLongPressDrag)

        let twoFingerLongPress = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTwoFingerLongPress(_:))
        )
        twoFingerLongPress.minimumPressDuration = 0.55
        twoFingerLongPress.allowableMovement = 16
        twoFingerLongPress.numberOfTouchesRequired = 2

        let twoFingerPan = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTwoFingerPan(_:))
        )
        twoFingerPan.minimumNumberOfTouches = 2
        twoFingerPan.maximumNumberOfTouches = 2

        let threeFingerPan = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleThreeFingerPan(_:))
        )
        threeFingerPan.minimumNumberOfTouches = 3
        threeFingerPan.maximumNumberOfTouches = 3

        let pinch = UIPinchGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePinch(_:))
        )

        [
            singleTap,
            doubleTap,
            oneFingerPan,
            oneFingerLongPressDrag,
            twoFingerLongPress,
            twoFingerPan,
            threeFingerPan,
            pinch
        ].forEach {
            $0.delegate = context.coordinator
            $0.cancelsTouchesInView = true
            view.addGestureRecognizer($0)
        }

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: LiveScreenGestureLayer
        private var activeRecognizers: Set<ObjectIdentifier> = []
        private var panMoved = false
        private var oneFingerLongDragActive = false
        private var oneFingerPanClaimedByLongDrag = false
        private var suppressTapUntil = Date.distantPast

        init(parent: LiveScreenGestureLayer) {
            self.parent = parent
        }

        @objc func handleSingleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended,
                  Date() >= suppressTapUntil,
                  let view = recognizer.view else {
                return
            }
            parent.onTap(recognizer.location(in: view))
        }

        @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended,
                  Date() >= suppressTapUntil,
                  let view = recognizer.view else {
                return
            }
            parent.onDoubleTap(recognizer.location(in: view))
        }

        @objc func handleOneFingerPan(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let location = recognizer.location(in: view)
            switch recognizer.state {
            case .began:
                if oneFingerLongDragActive {
                    oneFingerPanClaimedByLongDrag = true
                    setActive(recognizer, true)
                    return
                }
                oneFingerPanClaimedByLongDrag = false
                panMoved = false
                setActive(recognizer, true)
                parent.onOneFingerPan(.began, location)
            case .changed:
                guard !oneFingerPanClaimedByLongDrag,
                      !oneFingerLongDragActive else {
                    return
                }
                let translation = recognizer.translation(in: view)
                if hypot(translation.x, translation.y) >= 8 {
                    panMoved = true
                }
                parent.onOneFingerPan(.changed, location)
            case .ended:
                if oneFingerPanClaimedByLongDrag {
                    oneFingerPanClaimedByLongDrag = false
                    panMoved = false
                    setActive(recognizer, false)
                    return
                }
                parent.onOneFingerPan(.ended, location)
                if panMoved {
                    suppressTapUntil = Date().addingTimeInterval(0.2)
                }
                panMoved = false
                setActive(recognizer, false)
            case .cancelled, .failed:
                if oneFingerPanClaimedByLongDrag {
                    oneFingerPanClaimedByLongDrag = false
                    panMoved = false
                    setActive(recognizer, false)
                    return
                }
                parent.onOneFingerPan(.cancelled, location)
                panMoved = false
                setActive(recognizer, false)
            default:
                break
            }
        }

        @objc func handleOneFingerLongPressDrag(
            _ recognizer: UILongPressGestureRecognizer
        ) {
            guard let view = recognizer.view else { return }
            let location = recognizer.location(in: view)
            switch recognizer.state {
            case .began:
                oneFingerLongDragActive = true
                oneFingerPanClaimedByLongDrag = true
                panMoved = false
                suppressTapUntil = Date().addingTimeInterval(0.3)
                // A pan may already have entered `.began` while the finger
                // was settling. Clear its partial state before drag takes
                // ownership of the gesture.
                parent.onOneFingerPan(.cancelled, location)
                setActive(recognizer, true)
                parent.onOneFingerLongPressDrag(.began, location)
            case .changed:
                parent.onOneFingerLongPressDrag(.changed, location)
            case .ended:
                parent.onOneFingerLongPressDrag(.ended, location)
                oneFingerLongDragActive = false
                suppressTapUntil = Date().addingTimeInterval(0.3)
                setActive(recognizer, false)
            case .cancelled, .failed:
                parent.onOneFingerLongPressDrag(.cancelled, location)
                oneFingerLongDragActive = false
                suppressTapUntil = Date().addingTimeInterval(0.3)
                setActive(recognizer, false)
            default:
                break
            }
        }

        @objc func handleTwoFingerLongPress(
            _ recognizer: UILongPressGestureRecognizer
        ) {
            switch recognizer.state {
            case .began:
                setActive(recognizer, true)
                parent.onTwoFingerLongPress()
            case .ended, .cancelled, .failed:
                setActive(recognizer, false)
            default:
                break
            }
        }

        @objc func handleTwoFingerPan(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            switch recognizer.state {
            case .began:
                setActive(recognizer, true)
                recognizer.setTranslation(.zero, in: view)
            case .changed:
                let translation = recognizer.translation(in: view)
                parent.onViewportPan(
                    CGSize(width: translation.x, height: translation.y)
                )
                recognizer.setTranslation(.zero, in: view)
            case .ended, .cancelled, .failed:
                setActive(recognizer, false)
            default:
                break
            }
        }

        @objc func handleThreeFingerPan(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            switch recognizer.state {
            case .began:
                setActive(recognizer, true)
            case .ended:
                parent.onThreeFingerPan(recognizer.translation(in: view).y)
                setActive(recognizer, false)
            case .cancelled, .failed:
                setActive(recognizer, false)
            default:
                break
            }
        }

        @objc func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            guard let view = recognizer.view else { return }
            switch recognizer.state {
            case .began:
                setActive(recognizer, true)
                recognizer.scale = 1
            case .changed:
                parent.onPinch(
                    recognizer.scale,
                    recognizer.location(in: view)
                )
                recognizer.scale = 1
            case .ended, .cancelled, .failed:
                setActive(recognizer, false)
            default:
                break
            }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer:
                UIGestureRecognizer
        ) -> Bool {
            true
        }

        private func setActive(
            _ recognizer: UIGestureRecognizer,
            _ isActive: Bool
        ) {
            let identifier = ObjectIdentifier(recognizer)
            if isActive {
                activeRecognizers.insert(identifier)
            } else {
                activeRecognizers.remove(identifier)
            }
            parent.onTouchActivityChanged(!activeRecognizers.isEmpty)
        }
    }
}
