import Testing
@testable import ControlPanel

struct MenuBarLookupTests {
  final class Node {
    let role: String
    let id: String?
    let children: [Node]
    init(_ role: String, _ id: String? = nil, _ children: [Node] = []) {
      self.role = role; self.id = id; self.children = children
    }
  }
  let target = "com.apple.menuextra.controlcenter"
  func find(_ root: Node) -> Node? {
    MenuBarLookup.find(roots: [root], identifier: target,
                      role: { $0.role }, identifier: { $0.id }, children: { $0.children })
  }

  @Test func findsLegacyControlCenterMenuBar() {
    let item = Node("AXMenuBarItem", target)
    let root = Node("AXApplication", nil, [Node("AXMenuBar", nil, [item])])
    #expect(find(root) === item)
  }

  @Test func findsMacOS27DialogWithoutMenuBar() {
    let item = Node("AXUnknown", target)
    let root = Node("AXApplication", nil,
                    [Node("AXDialog", nil, [Node("AXUnknown", nil, [item])])])
    #expect(find(root) === item)
  }

  @Test func skipsEmbeddedApplicationsAndRequiresExactIdentifier() {
    let decoy = Node("AXMenuBarItem", target)
    let partial = Node("AXUnknown", target + ".other")
    let actual = Node("AXUnknown", target)
    let root = Node("AXApplication", nil,
                    [Node("AXApplication", nil, [decoy]), partial, Node("AXDialog", nil, [actual])])
    #expect(find(root) === actual)
  }

  @Test func boundsTraversalOfUnexpectedTrees() {
    var visits = 0
    let root = Node("AXGroup")
    let found = MenuBarLookup.find(roots: [root], identifier: target,
      role: { $0.role }, identifier: { $0.id }, children: { node in
        visits += 1
        return [node, node, node, node]
      })
    #expect(found == nil)
    #expect(visits <= 256)
  }
}
