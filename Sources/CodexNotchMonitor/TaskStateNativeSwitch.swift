import AppKit
import SwiftUI

/// Use AppKit's own thumb and track instead of inheriting SwiftUI row styling.
struct TaskStateNativeSwitch: NSViewRepresentable {
    @Binding var isOn: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator(binding: $isOn) }

    func makeNSView(context: Context) -> NSSwitch {
        let control = NSSwitch()
        control.controlSize = .regular
        control.target = context.coordinator
        control.action = #selector(Coordinator.changed(_:))
        control.setAccessibilityLabel("显示任务状态")
        control.setAccessibilityHelp("关闭后仍保留菜单栏额度与本地统计")
        return control
    }

    func updateNSView(_ control: NSSwitch, context: Context) {
        context.coordinator.binding = $isOn
        control.state = isOn ? .on : .off
        control.isEnabled = isEnabled
    }

    final class Coordinator: NSObject {
        var binding: Binding<Bool>
        init(binding: Binding<Bool>) { self.binding = binding }
        @objc func changed(_ sender: NSSwitch) { binding.wrappedValue = sender.state == .on }
    }
}
