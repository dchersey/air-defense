/// Searches only the system menu host's own tree. On macOS 27, MenuBarAgent
/// contains embedded AXApplication trees for unrelated apps as well as its own
/// status items. Walking those is both expensive and an incorrect lookup scope.
enum MenuBarLookup {
  static func find<Node>(roots: [Node], identifier wanted: String,
                         role: (Node) -> String, identifier: (Node) -> String?,
                         children: (Node) -> [Node]) -> Node? {
    var queue = roots.map { (node: $0, depth: 0) }
    var index = 0
    let limit = 256
    while index < queue.count && index < limit {
      let (node, depth) = queue[index]
      index += 1
      if depth > 0 && role(node) == "AXApplication" { continue }
      if identifier(node) == wanted { return node }
      if depth < 5 {
        let remaining = max(0, limit - queue.count)
        queue.append(contentsOf: children(node).prefix(remaining).map { ($0, depth + 1) })
      }
    }
    return nil
  }
}
