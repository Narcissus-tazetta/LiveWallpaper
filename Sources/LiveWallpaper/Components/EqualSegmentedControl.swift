import AppKit
import SwiftUI

struct EqualSegmentedControl<T: Hashable>: NSViewRepresentable {
    let options: [(label: String, value: T)]
    @Binding var selection: T

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(
            labels: options.map(\.label),
            trackingMode: .selectOne,
            target: context.coordinator,
            action: #selector(Coordinator.segmentChanged(_:))
        )
        control.segmentDistribution = .fillEqually
        updateSelection(control)
        return control
    }

    func updateNSView(_ nsView: NSSegmentedControl, context _: Context) {
        updateSelection(nsView)
    }

    private func updateSelection(_ control: NSSegmentedControl) {
        if let index = options.firstIndex(where: { $0.value == selection }) {
            control.selectedSegment = index
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    class Coordinator: NSObject {
        var parent: EqualSegmentedControl

        init(parent: EqualSegmentedControl) {
            self.parent = parent
        }

        @objc func segmentChanged(_ sender: NSSegmentedControl) {
            let index = sender.selectedSegment
            guard index >= 0, index < parent.options.count else { return }
            parent.selection = parent.options[index].value
        }
    }
}
