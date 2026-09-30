import SwiftUI

// weft's motion, in one place, so Setup and Settings move with the same feel:
// quick responses and high damping, so things arrive fast and settle without
// wobble. Everything here honours Reduce Motion — a fade instead of a flight.

extension Animation {
    /// Windows and tiles finding their place: previews, the layout picker.
    static let tile = Animation.spring(response: 0.3, dampingFraction: 0.9)
    /// Pages and other large surfaces.
    static let stage = Animation.spring(response: 0.5, dampingFraction: 0.88)
    /// Cards, banners and controls appearing or changing.
    static let chrome = Animation.spring(response: 0.26, dampingFraction: 0.88)
    /// Small hover and press responses.
    static let hover = Animation.spring(response: 0.18, dampingFraction: 0.75)
}

/// A headline whose words rise out of a blur one after another.
struct RevealText: View {
    let text: String
    var size: CGFloat = 56
    var weight: Font.Weight = .semibold
    var delay: Double = 0

    @State private var isShown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let words = text.split(separator: " ").map(String.init)
        HStack(alignment: .firstTextBaseline, spacing: size * 0.24) {
            ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                Text(word)
                    .font(.system(size: size, weight: weight))
                    .tracking(-size * 0.028)
                    .opacity(isShown ? 1 : 0)
                    .blur(radius: isShown || reduceMotion ? 0 : 12)
                    .offset(y: isShown || reduceMotion ? 0 : size * 0.35)
                    .animation(
                        reduceMotion
                            ? .easeOut(duration: 0.3)
                            : .spring(response: 0.7, dampingFraction: 0.82).delay(delay + Double(index) * 0.07),
                        value: isShown
                    )
            }
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .accessibilityAddTraits(.isHeader)
        .onAppear { isShown = true }
    }
}

/// Fades and lifts content in, a beat after whatever came before it.
struct Arrive: ViewModifier {
    let delay: Double
    @State private var isShown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(isShown ? 1 : 0)
            .offset(y: isShown || reduceMotion ? 0 : 14)
            .animation(
                reduceMotion ? .easeOut(duration: 0.3) : .spring(response: 0.6, dampingFraction: 0.86).delay(delay),
                value: isShown
            )
            .onAppear { isShown = true }
    }
}

extension View {
    func arrive(after delay: Double) -> some View { modifier(Arrive(delay: delay)) }
}

/// Scales down a touch while pressed.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
