import AppKit

/// Settings 表单行(标签列 + 值列)复用组件。
///
/// 行不自行决定几何; 值列对齐由所属 section 的 NSGridView 完成 —— 所有 section
/// 共享同一标签列宽(全表单 max intrinsic 标签宽 + gap), 因此值控件统一起始 x。
@MainActor
public final class SettingsFormRow {
    public let label: NSTextField
    public let value: NSView

    public init(title: String, value: NSView) {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        self.label = label
        self.value = value
    }

    public var labelIntrinsicWidth: CGFloat {
        label.intrinsicContentSize.width
    }
}
