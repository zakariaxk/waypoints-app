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
    /// Plates (text regions with a plate-like aspect ratio, wider than tall, 1.6:1 to 6:1) and
    /// faces (SPOT-6), both blurred the same way and both correctable by tapping.
    static func detect(_ image: CGImage) async -> [BlurBox] {
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .fast
        let faces = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(cgImage: image).perform([text, faces])
        let plates = (text.results ?? []).compactMap { o -> BlurBox? in
            let b = o.boundingBox
            let ratio = (b.width * CGFloat(image.width)) / max(1, b.height * CGFloat(image.height))
            guard (1.6...6).contains(ratio) else { return nil }
            return box(b, dx: -b.width * 0.15, dy: -b.height * 0.4)
        }
        let heads = (faces.results ?? []).map { o in
            box(o.boundingBox, dx: -o.boundingBox.width * 0.2, dy: -o.boundingBox.height * 0.25)
        }
        return plates + heads
    }

    /// Vision's normalized rect (origin bottom-left) to a blur box (origin top-left), grown by an inset.
    private static func box(_ b: CGRect, dx: CGFloat, dy: CGFloat) -> BlurBox {
        BlurBox(rect: CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height).insetBy(dx: dx, dy: dy))
    }

    /// Camera photos arrive rotated by EXIF; draw them upright so detection, blur, and the
    /// on-screen boxes share one coordinate space.
    static func upright(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
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
    @State private var picked: PickedModel?
    @State private var result: String?
    @State private var shot: UIImage?
    @State private var error: String?
    @Namespace private var collection

    /// The model chosen in "What is it?", waiting for "Add to collection".
    struct PickedModel {
        let make: String
        let model: String
        let id: Int64
        let year: Int?
        var label: String { [year.map { String($0) }, make, model].compactMap { $0 }.joined(separator: " ") }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: Space.s16) {
                if let result {
                    Spacer()
                    // SPOT-5: the photo flies into the collection counter with `win`.
                    HStack(spacing: Space.s12) {
                        if let shot {
                            Image(uiImage: shot).resizable().scaledToFill()
                                .frame(width: Size.row, height: Size.row)
                                .clipShape(RoundedRectangle(cornerRadius: Radius.r6, style: .continuous))
                                .matchedGeometryEffect(id: "shot", in: collection)
                                .accessibilityHidden(true)
                        }
                        Text(verbatim: result).typeStyle(.display).foregroundStyle(Color.chalk)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
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
                                    .accessibilityLabel(Text("Blurred area"))
                                    .accessibilityHint(Text("Removes the blur"))
                                    .accessibilityAddTraits(.isButton)
                            }
                        }
                        .frame(width: size.width, height: size.height)
                        .contentShape(Rectangle())
                        .onTapGesture { p in
                            boxes.append(BlurBox(rect: CGRect(x: p.x / size.width - 0.12, y: p.y / size.height - 0.04, width: 0.24, height: 0.08)))
                        }
                        .matchedGeometryEffect(id: "shot", in: collection)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    Text("Plates and faces are blurred. Tap a box to remove it. Tap the photo to blur more.")
                        .typeStyle(.foot).foregroundStyle(Color.dust)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let error { Text(verbatim: error).typeStyle(.foot).foregroundStyle(Color.brake) }
                    if let picked {
                        HStack {
                            Text(verbatim: picked.label).typeStyle(.bodyStrong).foregroundStyle(Color.chalk)
                            Spacer()
                            QuietButton("Change") { picking = true }
                        }
                        PrimaryButton("Add to collection", isLoading: saving) { save(picked) }
                    } else {
                        PrimaryButton("What is it?") { picking = true }
                    }
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
                        if case let .model(make, model, id, year) = p {
                            picked = PickedModel(make: make, model: model, id: id, year: year)
                        }
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
        let upright = PlateBlur.upright(ui)
        image = upright
        boxes = []
        picked = nil
        Task { if let cg = upright.cgImage { boxes = await PlateBlur.detect(cg) } }
    }

    private func save(_ picked: PickedModel) {
        let make = picked.make, model = picked.model, modelID = picked.id, year = picked.year
        guard let image else { return }
        let blurred = PlateBlur.apply(boxes, to: image)
        guard let data = blurred.jpegData(compressionQuality: 0.85) else { return }
        saving = true
        error = nil
        Task {
            do {
                guard let me = await env.auth.currentSession()?.userID else { saving = false; return }
                let city = await Self.city()
                let media = try await env.media.upload(data, contentType: "image/jpeg", to: .spots) { _ in }
                _ = try await env.spots.addSpot(Spot(spotterID: me, catalogModelID: modelID, year: year, make: make, model: model,
                                                     photoPath: media.path, city: city))
                let n = ((try? await env.spots.spots(by: me)) ?? []).filter { $0.catalogModelID == modelID }.count
                let ordinal = NumberFormatter.localizedString(from: NSNumber(value: n), number: .ordinal)
                shot = blurred
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
