import SwiftUI

final class MenuModel: ObservableObject {
    @Published var selection: [URL] = []
    @Published var category: Category?  // nil = first ring (types)
    @Published var hot: Int?
    @Published var pressed: Int?
    @Published var appeared = false
    var run: (Action, [URL]) -> Void = { _, _ in }
    var close: () -> Void = {}

    struct Slot { let title, symbol, detail: String }

    /// Only what the current selection can actually use.
    var slots: [Slot] {
        guard let c = category else {
            return usableCategories(for: selection).map { c in
                let n = usableActions(c, for: selection).count
                return Slot(title: c.title, symbol: c.symbol, detail: "\(n) action\(n == 1 ? "" : "s")")
            }
        }
        return usableActions(c, for: selection).map { a in
            let files = inputs(a, in: c, from: selection)
            let scope = files.count == selection.count ? ""
                : files.count == 1 ? " · only \(files[0].lastPathComponent)" : " · only \(files.count) of \(selection.count) files"
            return Slot(title: a.title, symbol: a.symbol, detail: a.detail + scope)
        }
    }

    var summary: String {
        let kinds = Set(selection.map { kind(of: $0) })
        let n = selection.count
        if kinds == [.pdf] { return n == 1 ? "1 PDF" : "\(n) PDFs" }
        if kinds == [.image] { return n == 1 ? "1 image" : "\(n) images" }
        return n == 1 ? "1 file" : "\(n) files"
    }

    /// Shows the press for a beat, then acts, so a click always reads as a click.
    func choose(_ i: Int) {
        guard pressed == nil, slots.indices.contains(i) else { return }
        hot = i
        withAnimation(.smooth(duration: 0.1)) { pressed = i }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [self] in
            pressed = nil
            if let c = category {
                let action = usableActions(c, for: selection)[i]
                run(action, inputs(action, in: c, from: selection))
            } else {
                let next = usableCategories(for: selection)[i]
                withAnimation(.smooth(duration: 0.22)) { category = next; hot = nil }
            }
        }
    }

    func back() {
        if category == nil { close() } else { withAnimation(.smooth(duration: 0.22)) { category = nil; hot = nil } }
    }

    func step(_ delta: Int) {
        let n = slots.count
        guard n > 0 else { return }
        hot = ((hot ?? (delta > 0 ? -1 : 0)) + delta + n) % n
    }
}

extension View {
    /// One material for the ring and the caption: glass, plus a neutral veil that mutes
    /// whatever wallpaper colour the glass would otherwise pick up.
    func frosted<S: Shape>(_ shape: S) -> some View {
        background(shape.fill(Color(nsColor: .windowBackgroundColor).opacity(0.45)))
            .glassEffect(RadialMenuView.glass, in: shape)
    }
}

/// Moves along the ring instead of cutting across it.
struct Orbiting: ViewModifier, Animatable {
    var angle: Double
    let radius: CGFloat
    var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }
    func body(content: Content) -> some View {
        let r = angle * .pi / 180
        content.offset(x: radius * sin(r), y: -radius * cos(r))
    }
}

struct RadialMenuView: View {
    @ObservedObject var m: MenuModel
    @State private var lensAngle = 0.0

    static let ring: CGFloat = 300
    static let radius: CGFloat = 104
    static let hub: CGFloat = 92
    static let lens: CGFloat = 72
    /// Frosts the glass enough that whatever is behind it never reads through the icons.
    static let glass = Glass.regular.tint(Color(nsColor: .windowBackgroundColor).opacity(0.62))

    var body: some View {
        let slots = m.slots
        VStack(spacing: 12) {
            ZStack {
                Color.clear
                    .frame(width: Self.ring, height: Self.ring)
                    .frosted(Circle())

                if let hot = m.hot, slots.indices.contains(hot) {
                    Circle()
                        .fill(Color.accentColor.opacity(m.pressed == hot ? 0.3 : 0.15))
                        .frame(width: Self.lens, height: Self.lens)
                        .scaleEffect(m.pressed == hot ? 0.92 : 1)
                        .modifier(Orbiting(angle: lensAngle, radius: Self.radius))
                }

                ZStack {
                    ForEach(Array(slots.enumerated()), id: \.offset) { i, slot in
                        let a = Double(i) * 2 * .pi / Double(slots.count)
                        let on = m.hot == i
                        VStack(spacing: 4) {
                            Image(systemName: slot.symbol)
                                .font(.system(size: 19, weight: .regular))
                                .foregroundStyle(on ? Color.accentColor : .primary)
                                .frame(height: 22)
                            Text(slot.title)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.primary.opacity(on ? 1 : 0.72))
                                .lineLimit(1)
                        }
                        .frame(width: Self.lens)
                        .scaleEffect(m.pressed == i ? 0.94 : 1)
                        .offset(x: Self.radius * sin(a), y: -Self.radius * cos(a))
                    }
                }
                .id(m.category?.title ?? "types")
                .transition(.opacity.combined(with: .scale(scale: 0.9)))

                hub
            }
            .frame(width: Self.ring, height: Self.ring)
            .contentShape(Circle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                guard m.pressed == nil else { return }
                switch phase {
                case .active(let p): m.hot = slot(at: p, count: slots.count)
                case .ended: m.hot = nil
                }
            }
            .onTapGesture(coordinateSpace: .local) { p in
                if let i = slot(at: p, count: slots.count) { m.choose(i) } else { m.back() }
            }

            caption(slots)
        }
        .padding(10)
        .scaleEffect(m.appeared ? 1 : 0.6)
        .opacity(m.appeared ? 1 : 0)
        .animation(.smooth(duration: 0.15), value: m.hot)
        .onChange(of: m.hot) { _, hot in
            guard let hot, !slots.isEmpty else { return }
            let target = Double(hot) * 360 / Double(slots.count)
            let delta = ((target - lensAngle).truncatingRemainder(dividingBy: 360) + 540).truncatingRemainder(dividingBy: 360) - 180
            withAnimation(.smooth(duration: 0.3)) { lensAngle += delta }
        }
    }

    private var hub: some View {
        VStack(spacing: 4) {
            if let c = m.category {
                Image(systemName: c.symbol).font(.system(size: 20))
                HStack(spacing: 2) {
                    Image(systemName: "chevron.left").font(.system(size: 9, weight: .semibold))
                    Text(c.title).font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.secondary)
            } else {
                Image(systemName: "doc.on.doc").font(.system(size: 20))
                Text(m.summary).font(.system(size: 11, weight: .semibold))
            }
        }
        .frame(width: Self.hub, height: Self.hub)
        .background(Circle().fill(.primary.opacity(0.05)))
    }

    private func caption(_ slots: [MenuModel.Slot]) -> some View {
        let text = m.hot.flatMap { slots.indices.contains($0) ? slots[$0].detail : nil }
        return HStack(spacing: 8) {
            Text(text ?? " ").font(.system(size: 12)).lineLimit(1).fixedSize()
            if let hot = m.hot {
                Text("\(hot + 1)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 16)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4).fill(.primary.opacity(0.08)))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .frosted(Capsule())
        .opacity(text == nil ? 0 : 1)
    }

    private func slot(at p: CGPoint, count n: Int) -> Int? {
        let dx = p.x - Self.ring / 2, dy = p.y - Self.ring / 2
        guard n > 0, hypot(dx, dy) > Self.hub / 2 else { return nil }
        let step = 2 * Double.pi / Double(n)
        let angle = (atan2(dx, -dy) + 2 * .pi + step / 2).truncatingRemainder(dividingBy: 2 * .pi)
        return Int(angle / step) % n
    }
}
