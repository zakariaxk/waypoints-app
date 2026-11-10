import SwiftUI

// Field, Chip, SegmentedSwitch (plan 9.9).

/// A text input: label above in `foot` `dust`, `concrete` fill, error below in `brake`. The
/// character count appears only within 10 of the limit.
public struct Field: View {
    private let label: LocalizedStringKey
    @Binding private var text: String
    private let prompt: LocalizedStringKey?
    private let limit: Int?
    private let error: Text?
    private let axis: Axis
    @ScaledMetric(relativeTo: .body) private var minHeight = Size.control

    public init(_ label: LocalizedStringKey, text: Binding<String>, prompt: LocalizedStringKey? = nil,
                limit: Int? = nil, error: Text? = nil, axis: Axis = .horizontal) {
        self.label = label
        self._text = text
        self.prompt = prompt
        self.limit = limit
        self.error = error
        self.axis = axis
    }

    private var remaining: Int? {
        guard let limit else { return nil }
        let left = limit - text.count
        return left <= 10 ? left : nil
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.s8) {
            HStack {
                Text(label).typeStyle(.foot).foregroundStyle(Color.dust)
                Spacer()
                if let remaining {
                    Text(verbatim: "\(remaining)")
                        .typeStyle(.readoutS)
                        .foregroundStyle(remaining < 0 ? Color.brake : Color.dust)
                        .accessibilityLabel(Text("\(remaining) characters left", bundle: .module))
                }
            }
            TextField(text: $text, prompt: prompt.map { Text($0).foregroundStyle(Color.gravel) }, axis: axis) {
                Text(label)
            }
            .typeStyle(.body)
            .foregroundStyle(Color.chalk)
            .tint(.sodium)
            .padding(.horizontal, Space.s16)
            .padding(.vertical, Space.s12)
            .frame(minHeight: minHeight)
            .background(Color.concrete, in: RoundedRectangle(cornerRadius: Radius.r12, style: .continuous))
            .overlay {
                if error != nil {
                    RoundedRectangle(cornerRadius: Radius.r12, style: .continuous)
                        .strokeBorder(Color.brake, lineWidth: Size.Marker.innerStroke)
                }
            }
            if let error {
                error.typeStyle(.foot).foregroundStyle(Color.brake)
            }
        }
    }
}

/// A filter or single-choice chip. 32 pt, `r6`; selected is `sodiumDim` with `sodium` text.
public struct Chip: View {
    private let title: LocalizedStringKey
    private let isSelected: Bool
    private let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .subheadline) private var height = Size.chip

    public init(_ title: LocalizedStringKey, isSelected: Bool, action: @escaping () -> Void) {
        self.title = title
        self.isSelected = isSelected
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(title)
                .typeStyle(.sub)
                .foregroundStyle(isSelected ? Color.sodium : Color.chalk)
                .padding(.horizontal, Space.s12)
                .frame(minHeight: height)
                .background(isSelected ? Color.sodiumDim : Color.concrete,
                            in: RoundedRectangle(cornerRadius: Radius.r6, style: .continuous))
                .frame(minHeight: Size.hitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
        .animation(Motion.quick.resolved(reduceMotion: reduceMotion), value: isSelected)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .haptic(.tick, trigger: isSelected)
    }
}

/// Up to three options with an underline indicator that slides with `quick`.
public struct SegmentedSwitch<Value: Hashable>: View {
    private let options: [(value: Value, title: LocalizedStringKey)]
    @Binding private var selection: Value
    @Namespace private var namespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(selection: Binding<Value>, options: [(value: Value, title: LocalizedStringKey)]) {
        precondition(options.count <= 3, "SegmentedSwitch holds at most three options (plan 9.9)")
        self._selection = selection
        self.options = options
    }

    public var body: some View {
        HStack(spacing: Space.s24) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let isSelected = option.value == selection
                Button {
                    withMotion(.quick, reduceMotion: reduceMotion) { selection = option.value }
                } label: {
                    VStack(spacing: Space.s4) {
                        Text(option.title)
                            .typeStyle(.bodyStrong)
                            .foregroundStyle(isSelected ? Color.chalk : Color.dust)
                        ZStack {
                            Color.clear.frame(height: Size.underline)
                            if isSelected {
                                Capsule()
                                    .fill(Color.sodium)
                                    .frame(height: Size.underline)
                                    .matchedGeometryEffect(id: "underline", in: namespace)
                            }
                        }
                    }
                    .frame(minHeight: Size.hitTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .haptic(.tick, trigger: selection)
    }
}

private struct InputsPreview: View {
    @State private var handle = "maya.drives"
    @State private var title = "Sunday cruise to Lake Nockamixon, leaving at 9"
    @State private var filter = "All"
    @State private var mode = 0

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s16) {
            Field("Handle", text: $handle, prompt: "your.handle")
            Field("Meet title", text: $title, limit: 50)
            Field("Email", text: .constant("maya@"), error: Text(verbatim: "Enter the full address, like name@example.com."))
            HStack(spacing: Space.s8) {
                ForEach(["All", "Friends", "Team"], id: \.self) { name in
                    Chip(LocalizedStringKey(name), isSelected: filter == name) { filter = name }
                }
            }
            SegmentedSwitch(selection: $mode, options: [(0, "Following"), (1, "Nearby"), (2, "Showdown")])
        }
        .padding(Space.margin)
    }
}

#Preview("Inputs") {
    InputsPreview().background(Color.asphalt).preferredColorScheme(.dark)
}
