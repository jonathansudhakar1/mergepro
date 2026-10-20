import Foundation

/// Keep restored windows reachable after display resolution or arrangement changes.
public enum WindowFrameRestoration {
    public static func fit(_ saved: CGRect, inside visible: CGRect, minimum: CGSize) -> CGRect {
        let valid = saved.origin.x.isFinite && saved.origin.y.isFinite && saved.width.isFinite && saved.height.isFinite && saved.width > 0 && saved.height > 0
        let width = min(visible.width, max(minimum.width, valid ? saved.width : minimum.width))
        let height = min(visible.height, max(minimum.height, valid ? saved.height : minimum.height))
        let x = valid ? saved.minX : visible.midX - width / 2
        let y = valid ? saved.minY : visible.midY - height / 2
        return CGRect(x: min(max(x, visible.minX), visible.maxX - width),
                      y: min(max(y, visible.minY), visible.maxY - height), width: width, height: height)
    }
    /// A further window of a role that already has visible windows (`occupied`, frontmost last): keep the
    /// remembered size, place it one `step` down and right of the frontmost window, wrap to the visible
    /// top-left when the cascade runs off the screen, and never land exactly on another window's corner.
    public static func cascade(size: CGSize, after occupied: [CGRect], inside visible: CGRect, minimum: CGSize, step: CGFloat = 24) -> CGRect {
        let sized = fit(CGRect(origin: .zero, size: size), inside: visible, minimum: minimum).size
        guard let front = occupied.last else { return fit(CGRect(x: .nan, y: .nan, width: sized.width, height: sized.height), inside: visible, minimum: minimum) }
        func frame(topLeft: CGPoint) -> CGRect { CGRect(x: topLeft.x, y: topLeft.y - sized.height, width: sized.width, height: sized.height) }
        func taken(_ candidate: CGRect) -> Bool { occupied.contains { abs($0.minX - candidate.minX) < 2 && abs($0.maxY - candidate.maxY) < 2 } }
        let first = frame(topLeft: CGPoint(x: front.minX + step, y: front.maxY - step))
        var candidate = first
        for _ in 0..<64 {
            if !visible.insetBy(dx: -0.5, dy: -0.5).contains(candidate) { candidate = frame(topLeft: CGPoint(x: visible.minX, y: visible.maxY)) }
            if !taken(candidate) { return candidate }
            candidate = frame(topLeft: CGPoint(x: candidate.minX + step, y: candidate.maxY - step))
        }
        return fit(first, inside: visible, minimum: minimum)
    }
}
