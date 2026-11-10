import CoreLocation
import Core
import CoreImage
import CoreImage.CIFilterBuiltins
import DesignSystem
import PhotosUI
import SwiftUI
import VehicleCatalog
import Vision

/// Car spotting (plan 10.3 M12): photograph, blur plates on-device, tag from the catalog,
/// store at city level only. Map action "Spot a car", route `spotCar`.
public enum SpotsFeature: FeatureModule {
    public static let isAvailable = true

    @MainActor
    public static func register(in registry: FeatureRegistry, env: AppEnvironment) {
        registry.registerMapAction(SpotAction())
        registry.registerRoute(.spotCar, presentation: .fullScreen) { _ in AnyView(SpotFlow(env: env)) }
    }
}

struct SpotAction: MapAction {
    var id: String { "spot" }
    var title: String { String(localized: "Spot a car") }
    var symbol: String { "camera" }
    var order: Int { 40 }
    @MainActor func perform(at coordinate: Coordinate, router: any Router) { router.open(.spotCar) }
}

/// A blur region in normalized image coordinates (origin top-left).
struct BlurBox: Identifiable, Hashable {
    let id = UUID()
    var rect: CGRect
}

enum PlateBlur {
    /// Text regions with a plate-like aspect ratio (wider than tall, 1.6:1 to 6:1).
    static func detect(_ image: CGImage) async -> [BlurBox] {
        await withCheckedContinuation { c in
            let request = VNRecognizeTextRequest { req, _ in
                let boxes = (req.results as? [VNRecognizedTextObservation] ?? []).compactMap { o -> BlurBox? in
                    let b = o.boundingBox
                    let ratio = (b.width * CGFloat(image.width)) / max(1, b.height * CGFloat(image.height))
                    guard (1.6...6).contains(ratio) else { return nil }
                    let r = CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height).insetBy(dx: -b.width * 0.15, dy: -b.height * 0.4)
                    return BlurBox(rect: r)
                }
                c.resume(returning: boxes)
            }
            request.recognitionLevel = .fast
            try? VNImageRequestHandler(cgImage: image).perform([request])
        }
    }

    static func apply(_ boxes: [BlurBox], to image: UIImage) -> UIImage {
        guard let cg = image.cgImage else { return image }
        let input = CIImage(cgImage: cg)
        var out = input
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        for b in boxes {
            let r = CGRect(x: b.rect.minX * w, y: (1 - b.rect.maxY) * h, width: b.rect.width * w, height: b.rect.height * h)
            let blur = CIFilter.pixellate()
            blur.inputImage = input.cropped(to: r).clampedToExtent()
            blur.scale = Float(max(12, r.width / 6))
            if let blurred = blur.outputImage?.cropped(to: r) { out = blurred.composited(over: out) }
        }
        guard let rendered = CIContext().createCGImage(out, from: input.extent) else { return image }
        return UIImage(cgImage: rendered, scale: image.scale, orientation: image.imageOrientation)
    }
}

struct SpotFlow: View {
    let env: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var image: UIImage?
    @State private var boxes: [BlurBox] = []
    @State private var showCamera = true
    @State private var item: PhotosPickerItem?
    @State private var pickLibrary = false
    @State private var picking = false
    @State private var saving = false
    @State private var result: String?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: Space.s16) {
                if let result {
                    Spacer()
                    Text(verbatim: result).typeStyle(.display).foregroundStyle(Color.chalk).transition(.scale.combined(with: .opacity))
                    PrimaryButton("Done") { dismiss() }
                    Spacer()
                } else if let image {
                    GeometryReader { geo in
                        let size = fit(image.size, in: geo.size)
                        ZStack(alignment: .topLeading) {
                            Image(uiImage: PlateBlur.apply(boxes, to: image)).resizable().frame(width: size.width, height: size.height)
                            ForEach(boxes) { b in
                                Rectangle().strokeBorder(Color.sodium, lineWidth: Size.Marker.ring)
                                    .frame(width: b.rect.width * size.width, height: b.rect.height * size.height)
                                    .offset(x: b.rect.minX * size.width, y: b.rect.minY * size.height)
                                    .onTapGesture { boxes.removeAll { $0.id == b.id } }
                            }
                        }
                        .frame(width: size.width, height: size.height)
                        .contentShape(Rectangle())
                        .onTapGesture { p in
                            boxes.append(BlurBox(rect: CGRect(x: p.x / size.width - 0.12, y: p.y / size.height - 0.04, width: 0.24, height: 0.08)))
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    Text("Tap a box to remove it. Tap the photo to blur more.").typeStyle(.foot).foregroundStyle(Color.dust)
                    if let error { Text(verbatim: error).typeStyle(.foot).foregroundStyle(Color.brake) }
                    PrimaryButton("What is it?", isLoading: saving) { picking = true }
                } else {
                    Spacer()
                    SecondaryButton("Take a photo") { showCamera = true }
                    QuietButton("Choose from library") { pickLibrary = true }
                    Spacer()
                }
            }
            .padding(Space.margin)
            .background(Color.asphalt.ignoresSafeArea())
            .toolbar { ToolbarItem(placement: .topBarLeading) { QuietButton("Cancel") { dismiss() } } }
            .photosPicker(isPresented: $pickLibrary, selection: $item, matching: .images)
            .sheet(isPresented: $picking) {
                NavigationStack {
                    VehiclePicker(catalog: env.catalog, mode: .modelOnly) { p in
                        picking = false
                        if case let .model(make, model, id, year) = p { save(make: make, model: model, modelID: id, year: year) }
                    }
                    .navigationTitle("What is it?")
                }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraView { captured in
                    showCamera = false
                    if let captured { use(captured) } else if image == nil { pickLibrary = !UIImagePickerController.isSourceTypeAvailable(.camera) }
                }
                .ignoresSafeArea()
            }
        }
        .onChange(of: item) {
            Task { if let d = try? await item?.loadTransferable(type: Data.self), let ui = UIImage(data: d) { use(ui) } }
        }
    }

    private func fit(_ s: CGSize, in box: CGSize) -> CGSize {
        let scale = min(box.width / max(s.width, 1), box.height / max(s.height, 1))
        return CGSize(width: s.width * scale, height: s.height * scale)
    }

    private func use(_ ui: UIImage) {
        image = ui
        Task { if let cg = ui.cgImage { boxes = await PlateBlur.detect(cg) } }
    }

    private func save(make: String, model: String, modelID: Int64, year: Int?) {
        guard let image, let data = PlateBlur.apply(boxes, to: image).jpegData(compressionQuality: 0.85) else { return }
        saving = true
        Task {
            do {
                guard let me = await env.auth.currentSession()?.userID else { return }
                let city = await Self.city()
                let media = try await env.media.upload(data, contentType: "image/jpeg", to: .spots) { _ in }
                _ = try await env.spots.addSpot(Spot(spotterID: me, catalogModelID: modelID, year: year, make: make, model: model,
                                                     photoPath: media.path, city: city))
                let n = ((try? await env.spots.spots(by: me)) ?? []).filter { $0.catalogModelID == modelID }.count
                let ordinal = NumberFormatter.localizedString(from: NSNumber(value: n), number: .ordinal)
                withMotion(.win, reduceMotion: reduceMotion) { result = "\(make) \(model) · \(ordinal) spotted" }
            } catch {
                self.error = "Couldn't add it. Check your connection and try again."
            }
            saving = false
        }
    }

    /// City only: the coarse location is reverse-geocoded and only the locality is kept.
    static func city() async -> String {
        let manager = CLLocationManager()
        guard let loc = manager.location else { return "" }
        return await withCheckedContinuation { c in
            CLGeocoder().reverseGeocodeLocation(loc) { marks, _ in c.resume(returning: marks?.first?.locality ?? "") }
        }
    }
}

struct CameraView: UIViewControllerRepresentable {
    let done: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let done: (UIImage?) -> Void
        init(done: @escaping (UIImage?) -> Void) { self.done = done }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            done(info[.originalImage] as? UIImage)
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { done(nil) }
    }
}
