import CoreGraphics

/// Fixed row heights for prompt mode's SwiftUI content (ios-18 spec, "Frame
/// and height"): the compact toolbar sitting at the Scratchpad's bottom
/// edge (`KeyboardCompactToolbar`), `KeyboardPromptPanel`'s chips row, and
/// its action row. Every SwiftUI row in prompt mode gets an explicit
/// `.frame(height:)` built from these constants, and
/// `KallilexKeyboardController.promptsModeConstraints` sizes the whole
/// hosting view to `total` — so nothing in prompt mode ever draws (or
/// receives touches) beyond the hosting view's own bounds, unlike the
/// previous fixed `88` that didn't account for the toolbar row at all.
enum KeyboardPromptMetrics {
    static let toolbarHeight: CGFloat = 32
    static let chipsHeight: CGFloat = 44
    static let actionHeight: CGFloat = 44
    static let total: CGFloat = toolbarHeight + chipsHeight + actionHeight
}
