#if os(iOS)

import AVFoundation
import SwiftUI
import UIKit

/// The camera, looking for one QR code.
///
/// Deliberately thin. It reports the first payload it sees and stops; deciding
/// whether that payload means anything is `DevicePairing`'s job, because a
/// camera pointed at the world finds plenty of QR codes and none of the
/// judgement about them belongs in a capture session.
struct QRScannerView: UIViewControllerRepresentable {
    let onScan: (String) -> Void
    let onFailure: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        controller.onScan = onScan
        controller.onFailure = onFailure

        return controller
    }

    func updateUIViewController(_ controller: ScannerController, context: Context) {}

    /// `@preconcurrency` on the conformance, not `nonisolated` on the method:
    /// the delegate is declared with a queue, and the queue here is
    /// `.main` — so every callback genuinely arrives on the main actor. The
    /// protocol predates that being expressible, and marking the method
    /// `nonisolated` would make the compiler right and the code wrong.
    final class ScannerController: UIViewController,
        @preconcurrency AVCaptureMetadataOutputObjectsDelegate
    {
        var onScan: ((String) -> Void)?
        var onFailure: ((String) -> Void)?

        private let session = AVCaptureSession()
        private var preview: AVCaptureVideoPreviewLayer?
        /// One payload per presentation. Metadata output fires every frame the
        /// code is visible, and without this a single code would enrol the
        /// device several times over.
        private var hasScanned = false

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black

            guard let device = AVCaptureDevice.default(for: .video),
                let input = try? AVCaptureDeviceInput(device: device),
                session.canAddInput(input)
            else {
                onFailure?("This device has no camera available.")

                return
            }

            session.addInput(input)

            let output = AVCaptureMetadataOutput()

            guard session.canAddOutput(output) else {
                onFailure?("The camera couldn't be started.")

                return
            }

            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            // Set after the output is attached: the available types are not
            // known until then, and assigning .qr before it throws.
            output.metadataObjectTypes = [.qr]

            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.videoGravity = .resizeAspectFill
            preview.frame = view.bounds
            view.layer.addSublayer(preview)
            self.preview = preview
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            preview?.frame = view.bounds
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)

            guard session.isRunning == false else { return }

            // Off the main thread: starting a capture session blocks for long
            // enough to drop frames from the presentation animation.
            // `AVCaptureSession` is documented as safe to drive from a
            // background queue, which is exactly what Apple's own sample does;
            // it is simply not `Sendable`-annotated.
            nonisolated(unsafe) let session = session

            DispatchQueue.global(qos: .userInitiated).async {
                session.startRunning()
            }
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            session.stopRunning()
        }

        func metadataOutput(
            _ output: AVCaptureMetadataOutput,
            didOutput objects: [AVMetadataObject],
            from connection: AVCaptureConnection
        ) {
            guard hasScanned == false,
                let object = objects.first as? AVMetadataMachineReadableCodeObject,
                let value = object.stringValue
            else { return }

            hasScanned = true
            session.stopRunning()

            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onScan?(value)
        }
    }
}

/// The scanning sheet, with the framing and the copy around it.
struct PairingScannerSheet: View {
    let onScan: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var cameraFailure: String?

    var body: some View {
        NavigationStack {
            ZStack {
                if let cameraFailure {
                    ContentUnavailableView {
                        Label(.ui("Camera unavailable"), systemImage: "camera.slash")
                    } description: {
                        Text(cameraFailure)
                    }
                } else {
                    QRScannerView(
                        onScan: { value in
                            onScan(value)
                            dismiss()
                        },
                        onFailure: { cameraFailure = $0 }
                    )
                    .ignoresSafeArea()

                    // A reticle rather than a full-screen camera with no
                    // indication of where to aim.
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(.white.opacity(0.9), lineWidth: 3)
                        .frame(width: 240, height: 240)
                        .shadow(radius: 8)
                        .accessibilityHidden(true)
                }
            }
            .navigationTitle(.ui("Scan pairing code"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(.ui("Cancel")) { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Text(.ui("In plMail, open Settings → App passwords and choose Pair a device."))
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding()
            }
        }
    }
}

#endif
