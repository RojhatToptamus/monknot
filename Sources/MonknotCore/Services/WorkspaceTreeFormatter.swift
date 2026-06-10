import Foundation

public struct WorkspaceTreeFormatter: Sendable {
    public init() {}

    public func compactTree(from root: SidebarNode) -> String {
        var lines: [String] = ["."]
        appendChildren(root.children ?? [], prefix: "", isLastSibling: true, into: &lines)
        return lines.joined(separator: "\n")
    }

    private func appendChildren(
        _ children: [SidebarNode],
        prefix: String,
        isLastSibling: Bool,
        into lines: inout [String]
    ) {
        guard !children.isEmpty else { return }

        for (index, child) in children.enumerated() {
            let isLast = index == children.count - 1
            let branch = isLast ? "└── " : "├── "
            let childPrefix = prefix + (isLastSibling ? "    " : "│   ")

            if child.kind == .folder {
                lines.append(prefix + branch + child.name + "/")
                appendChildren(child.children ?? [], prefix: childPrefix, isLastSibling: isLast, into: &lines)
            } else {
                lines.append(prefix + branch + child.name)
            }
        }
    }
}
