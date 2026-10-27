import AVFoundation
import SwiftUI
import UIKit

/// Broadcasts compressed H.264 samples directly to one or more display
/// layers. Only Core Foundation references are retained; decoded frames stay
/// in AVFoundation's IOSurface-backed rendering pipeline.
final class H264VideoFrameHub: @unchecked Sendable {
    private final class WeakLayer {
        weak var value: AVSampleBufferDisplayLayer?

        init(_ value: AVSampleBufferDisplayLayer) {
            self.value = value
        }
    }

    private let lock = NSLock()
    private var layers: [WeakLayer] = []
    private var cachedGroupOfPictures: [H264VideoSample] = []

    func attach(_ layer: AVSampleBufferDisplayLayer) {
        lock.lock()
        layers.removeAll { $0.value == nil }
        if layers.contains(where: { $0.value === layer }) {
            lock.unlock()
            return
        }
        layers.append(WeakLayer(layer))
        let cachedSamples = cachedGroupOfPictures
        lock.unlock()

        guard !cachedSamples.isEmpty else { return }
        DispatchQueue.main.async {
            if layer.status == .failed {
                layer.flushAndRemoveImage()
            }
            for sample in cachedSamples
            where layer.isReadyForMoreMediaData {
                layer.enqueue(sample.sampleBuffer)
            }
        }
    }

    func detach(_ layer: AVSampleBufferDisplayLayer) {
        lock.lock()
        layers.removeAll { $0.value == nil || $0.value === layer }
        lock.unlock()
        DispatchQueue.main.async {
            layer.flushAndRemoveImage()
        }
    }

    func enqueue(_ sample: H264VideoSample) {
        lock.lock()
        if sample.isSync {
            cachedGroupOfPictures = [sample]
        } else if !cachedGroupOfPictures.isEmpty {
            cachedGroupOfPictures.append(sample)
            if cachedGroupOfPictures.count > 300 {
                cachedGroupOfPictures.removeFirst(
                    cachedGroupOfPictures.count - 300
                )
            }
        }
        let targets = layers.compactMap(\.value)
        layers.removeAll { $0.value == nil }
        lock.unlock()

        DispatchQueue.main.async {
            for layer in targets {
                if layer.status == .failed {
#if DEBUG
                    print(
                        "[TVADB][error.h264_display] "
                            + (layer.error?.localizedDescription
                                ?? "Unknown display-layer error")
                    )
#endif
                    layer.flushAndRemoveImage()
                }
                guard layer.isReadyForMoreMediaData else { continue }
                layer.enqueue(sample.sampleBuffer)
            }
        }
    }

    func clear() {
        lock.lock()
        let targets = layers.compactMap(\.value)
        layers.removeAll { $0.value == nil }
        cachedGroupOfPictures.removeAll(keepingCapacity: false)
        lock.unlock()
        DispatchQueue.main.async {
            targets.forEach { $0.flushAndRemoveImage() }
        }
    }
}

final class H264SampleBufferView: UIView {
    override class var layerClass: AnyClass {
        AVSampleBufferDisplayLayer.self
    }

    var displayLayer: AVSampleBufferDisplayLayer {
        layer as! AVSampleBufferDisplayLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        displayLayer.backgroundColor = UIColor.black.cgColor
        displayLayer.videoGravity = .resizeAspect
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

struct H264VideoSurface: UIViewRepresentable {
    let hub: H264VideoFrameHub

    func makeUIView(context: Context) -> H264SampleBufferView {
        let view = H264SampleBufferView()
        hub.attach(view.displayLayer)
        return view
    }

    func updateUIView(
        _ uiView: H264SampleBufferView,
        context: Context
    ) {
        hub.attach(uiView.displayLayer)
    }

    static func dismantleUIView(
        _ uiView: H264SampleBufferView,
        coordinator: Void
    ) {
        uiView.displayLayer.flushAndRemoveImage()
    }
}
