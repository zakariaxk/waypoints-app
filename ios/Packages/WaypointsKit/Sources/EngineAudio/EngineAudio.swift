import AVFoundation
import Core
import Synchronization

// Procedural engine sound (plan 11.3): firing pulses on the engine's real firing intervals,
// a waveguide pipe per bank, a muffler, and intake, whine, whistle, and crackle layers.

public enum FiringLayout: String, Sendable, Hashable, CaseIterable {
    case inline4, inline6, crossPlaneV8, flatPlaneV8, boxer4, v6, rotary

    /// Crank angles (degrees in a 720° cycle) at which a cylinder fires.
    var angles: [Double] {
        switch self {
        case .inline4: [0, 180, 360, 540]
        case .inline6: [0, 120, 240, 360, 480, 600]
        case .v6: [0, 120, 240, 360, 480, 600]
        // Cross-plane V8: even overall, but each bank sees 90/180/270/180, which is the burble.
        case .crossPlaneV8: [0, 90, 180, 270, 360, 450, 540, 630]
        case .flatPlaneV8: [0, 90, 180, 270, 360, 450, 540, 630]
        case .boxer4: [0, 180, 360, 540]
        case .rotary: [0, 240, 480]
        }
    }

    /// Bank of each firing, for the two pipes. Cross-plane V8 uses the 1-8-4-3-6-5-7-2 bank pattern.
    var banks: [Int] {
        switch self {
        case .crossPlaneV8: [0, 1, 0, 0, 1, 0, 1, 1]
        case .flatPlaneV8: [0, 1, 0, 1, 0, 1, 0, 1]
        case .v6: [0, 1, 0, 1, 0, 1]
        case .boxer4: [0, 1, 0, 1]
        default: angles.map { _ in 0 }
        }
    }

    /// Unequal-length header delay offsets per firing, in degrees (the boxer rumble).
    var jitterDegrees: [Double] {
        switch self {
        case .boxer4: [0, 14, 4, 18]
        default: angles.map { _ in 0 }
        }
    }

    public var title: String {
        switch self {
        case .inline4: "Inline-4"
        case .inline6: "Inline-6"
        case .crossPlaneV8: "Cross-plane V8"
        case .flatPlaneV8: "Flat-plane V8"
        case .boxer4: "Boxer-4"
        case .v6: "V6"
        case .rotary: "Rotary"
        }
    }

    public static func from(cylinders: Int, flat: Bool, crossPlane: Bool, rotary: Bool) -> FiringLayout {
        if rotary { return .rotary }
        switch cylinders {
        case 8...: return crossPlane ? .crossPlaneV8 : .flatPlaneV8
        case 6: return flat ? .boxer4 : .inline6
        case 5: return .inline6
        default: return flat ? .boxer4 : .inline4
        }
    }
}

/// Everything the synthesizer needs about one car and its mods.
public struct SoundProfile: Sendable, Hashable {
    public var layout: FiringLayout
    public var redline: Double
    public var gainDb: Double
    public var cutoffScale: Double
    public var resonator: Bool
    public var brightness: Double
    public var reflection: Double
    public var crackle: Bool
    public var whine: Bool
    public var whistle: Bool

    public init(layout: FiringLayout, redline: Double = 7000, gainDb: Double = 0, cutoffScale: Double = 1, resonator: Bool = true,
                brightness: Double = 0, reflection: Double = 0, crackle: Bool = false, whine: Bool = false, whistle: Bool = false) {
        self.layout = layout; self.redline = redline; self.gainDb = gainDb; self.cutoffScale = cutoffScale
        self.resonator = resonator; self.brightness = brightness; self.reflection = reflection; self.crackle = crackle
        self.whine = whine; self.whistle = whistle
    }
}

/// The audio-thread kernel. This is the only `@unchecked Sendable` type in the app (plan 11.3):
/// it is shared between the main actor, which writes parameters through `Atomic` values, and the
/// render thread, which owns every other field. The render path does not allocate, lock, or call
/// into the Swift or Objective-C runtime; buffers are preallocated `UnsafeMutablePointer`s.
final class RenderKernel: @unchecked Sendable {
    // Parameters written by the main actor (Double bit patterns).
    let rpmBits = Atomic<UInt64>(Double(900).bitPattern)
    let loadBits = Atomic<UInt64>(Double(0).bitPattern)
    let gainBits = Atomic<UInt64>(Double(1).bitPattern)
    let cutoffBits = Atomic<UInt64>(Double(1800).bitPattern)
    let brightBits = Atomic<UInt64>(Double(0).bitPattern)
    let reflBits = Atomic<UInt64>(Double(0.35).bitPattern)
    let flags = Atomic<UInt32>(0)          // 1 resonator, 2 crackle, 4 whine, 8 whistle, 16 muted
    let layoutIndex = Atomic<Int>(0)

    // Render-thread state.
    private let sampleRate: Double
    private let delayLength = 4096
    private let delay: UnsafeMutablePointer<Float>
    private let delay2: UnsafeMutablePointer<Float>
    /// Every layout's tables, 16 slots each, filled at init so the render path only indexes.
    private let angles: UnsafeMutablePointer<Double>
    private let banks: UnsafeMutablePointer<Int>
    private let offsets: UnsafeMutablePointer<Double>
    private let counts: UnsafeMutablePointer<Int>
    private var writeIndex = 0
    private var crank = 0.0
    private var rpm = 900.0
    private var load = 0.0
    private var lastLoad = 0.0
    private var age0 = 1e9, age1 = 1e9, amp0 = 0.0, amp1 = 0.0
    private var lp1 = 0.0, lp2 = 0.0, intake = 0.0, whinePhase = 0.0, whistlePhase = 0.0, spool = 0.0
    private var crackleLeft = 0
    private var seed: UInt64 = 0x9E3779B97F4A7C15

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        delay = .allocate(capacity: delayLength); delay.initialize(repeating: 0, count: delayLength)
        delay2 = .allocate(capacity: delayLength); delay2.initialize(repeating: 0, count: delayLength)
        let n = FiringLayout.allCases.count * 16
        angles = .allocate(capacity: n); angles.initialize(repeating: 0, count: n)
        banks = .allocate(capacity: n); banks.initialize(repeating: 0, count: n)
        offsets = .allocate(capacity: n); offsets.initialize(repeating: 0, count: n)
        counts = .allocate(capacity: FiringLayout.allCases.count)
        for (li, layout) in FiringLayout.allCases.enumerated() {
            let a = layout.angles, b = layout.banks, o = layout.jitterDegrees
            counts[li] = a.count
            for i in 0..<a.count { angles[li * 16 + i] = a[i]; banks[li * 16 + i] = b[i]; offsets[li * 16 + i] = o[i] }
        }
    }

    deinit {
        delay.deallocate(); delay2.deallocate(); angles.deallocate(); banks.deallocate(); offsets.deallocate()
        counts.deallocate()
    }

    @inline(__always) private func noise() -> Double {
        seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
        return Double(Int64(bitPattern: seed) >> 11) / Double(1 << 52)
    }

    func render(frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>?) {
        let base = layoutIndex.load(ordering: .relaxed) * 16
        let count = counts[base / 16]
        let targetRpm = Double(bitPattern: rpmBits.load(ordering: .relaxed))
        let targetLoad = Double(bitPattern: loadBits.load(ordering: .relaxed))
        let gain = Double(bitPattern: gainBits.load(ordering: .relaxed))
        let cutoff = Double(bitPattern: cutoffBits.load(ordering: .relaxed))
        let bright = Double(bitPattern: brightBits.load(ordering: .relaxed))
        let refl = Double(bitPattern: reflBits.load(ordering: .relaxed))
        let f = flags.load(ordering: .relaxed)
        let muted = f & 16 != 0
        let a1 = exp(-2 * .pi * cutoff / sampleRate)
        let pipeLen = max(32, min(delayLength - 1, Int(sampleRate / max(80, cutoff * 0.12))))

        for n in 0..<frames {
            rpm += (targetRpm - rpm) * 0.0008
            load += (targetLoad - load) * 0.002
            let degPerSample = rpm / 60 * 360 / sampleRate
            let before = crank
            crank += degPerSample
            if crank >= 720 { crank -= 720 }
            // Fire any cylinder whose angle was crossed.
            for i in 0..<count {
                let a = angles[base + i] + offsets[base + i]
                let crossed = before <= crank ? (a > before && a <= crank) : (a > before || a <= crank)
                if crossed {
                    let amp = (0.35 + 0.65 * load) * (1 + 0.03 * noise())
                    if banks[base + i] == 0 { age0 = 0; amp0 = amp } else { age1 = 0; amp1 = amp }
                }
            }
            var x = 0.0, x2 = 0.0
            let tau = sampleRate * (0.0016 - 0.0006 * bright)
            let grit = 0.3 + bright + load * 0.5
            if age0 < tau * 8 { x = exp(-age0 / tau) * (0.7 + 0.3 * noise() * grit) * amp0; age0 += 1 }
            if age1 < tau * 8 { x2 = exp(-age1 / tau) * (0.7 + 0.3 * noise() * grit) * amp1; age1 += 1 }
            // Crackle: random bursts on overrun above 3,500 rpm with a tune that allows it.
            if f & 2 != 0 && rpm > 3500 && lastLoad - load > 0.0005 && crackleLeft == 0 && noise() > 0.995 {
                crackleLeft = Int(sampleRate * 0.004)
            }
            if crackleLeft > 0 { crackleLeft -= 1; x += noise() * 0.9; x2 += noise() * 0.9 }
            lastLoad = load

            // Pipes: a delay line with reflection and a gentle loss filter, per bank.
            let r = (0.25 + refl * 0.6)
            let read = (writeIndex - pipeLen + delayLength) % delayLength
            let y1 = x + r * Double(delay[read])
            let y2 = (x2 == 0 && count < 6 ? x : x2) + r * Double(delay2[read])
            delay[writeIndex] = Float(y1 * 0.98)
            delay2[writeIndex] = Float(y2 * 0.98)
            writeIndex = (writeIndex + 1) % delayLength

            // Muffler low-pass.
            lp1 = (1 - a1) * y1 + a1 * lp1
            lp2 = (1 - a1) * y2 + a1 * lp2
            var outL = lp1, outR = lp2
            if f & 1 == 0 { let rasp = (y1 - lp1) * 0.25; outL += rasp; outR += rasp }
            // Intake noise rising with load.
            intake = 0.97 * intake + 0.03 * noise()
            outL += intake * load * 0.15; outR += intake * load * 0.15
            // Supercharger whine and turbo whistle.
            if f & 4 != 0 {
                whinePhase += 2 * .pi * (rpm / 60 * 2.6 * 4) / sampleRate
                if whinePhase > 2 * .pi { whinePhase -= 2 * .pi }
                let w = sin(whinePhase) * 0.08 * (0.3 + load)
                outL += w; outR += w
            }
            if f & 8 != 0 {
                spool += ((load > 0.5 ? 1 : 0) - spool) * 0.00005
                whistlePhase += 2 * .pi * (2000 + 6000 * spool) / sampleRate
                if whistlePhase > 2 * .pi { whistlePhase -= 2 * .pi }
                let w = sin(whistlePhase) * 0.03 * spool
                outL += w; outR += w
            }
            let g = muted ? 0 : gain * 0.5
            left[n] = Float(max(-1, min(1, outL * g)))
            right?[n] = Float(max(-1, min(1, outR * g)))
        }
    }
}

/// The engine synthesizer: start, stop, set rpm and load, and apply a `SoundProfile`.
@MainActor
public final class EngineSynth {
    private let engine = AVAudioEngine()
    private var node: AVAudioSourceNode?
    private var kernel: RenderKernel?
    public private(set) var isRunning = false
    public private(set) var profile = SoundProfile(layout: .inline4)

    public init() {}

    public func start() {
        guard !isRunning else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        let format = engine.outputNode.inputFormat(forBus: 0)
        let sr = format.sampleRate > 0 ? format.sampleRate : 48000
        let kernel = RenderKernel(sampleRate: sr)
        let node = Self.makeNode(kernel: kernel)
        let stereo = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: stereo)
        self.kernel = kernel
        self.node = node
        apply(profile)
        do {
            try engine.start()
            isRunning = true
        } catch {
            isRunning = false
        }
    }

    /// Built outside the main actor so the render block does not inherit its isolation.
    nonisolated private static func makeNode(kernel: RenderKernel) -> AVAudioSourceNode {
        AVAudioSourceNode { _, _, frameCount, bufferList -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(bufferList)
            guard let l = abl[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let r = abl.count > 1 ? abl[1].mData?.assumingMemoryBound(to: Float.self) : nil
            kernel.render(frames: Int(frameCount), left: l, right: r)
            return noErr
        }
    }

    public func stop() {
        engine.stop()
        if let node { engine.detach(node) }
        node = nil
        kernel = nil
        isRunning = false
    }

    /// rpm and load (0–1) are smoothed per sample on the audio thread.
    public func set(rpm: Double, load: Double) {
        kernel?.rpmBits.store(max(600, rpm).bitPattern, ordering: .relaxed)
        kernel?.loadBits.store(max(0, min(1, load)).bitPattern, ordering: .relaxed)
    }

    public func setMuted(_ muted: Bool) {
        guard let k = kernel else { return }
        let f = k.flags.load(ordering: .relaxed)
        k.flags.store(muted ? f | 16 : f & ~16, ordering: .relaxed)
    }

    public func apply(_ p: SoundProfile) {
        profile = p
        guard let k = kernel else { return }
        k.layoutIndex.store(FiringLayout.allCases.firstIndex(of: p.layout) ?? 0, ordering: .relaxed)
        k.gainBits.store(pow(10, p.gainDb / 20).bitPattern, ordering: .relaxed)
        k.cutoffBits.store((1400 * p.cutoffScale).bitPattern, ordering: .relaxed)
        k.brightBits.store(min(1, p.brightness).bitPattern, ordering: .relaxed)
        k.reflBits.store(min(1, 0.3 + p.reflection).bitPattern, ordering: .relaxed)
        var f: UInt32 = k.flags.load(ordering: .relaxed) & 16
        if p.resonator { f |= 1 }
        if p.crackle { f |= 2 }
        if p.whine { f |= 4 }
        if p.whistle { f |= 8 }
        k.flags.store(f, ordering: .relaxed)
    }
}
