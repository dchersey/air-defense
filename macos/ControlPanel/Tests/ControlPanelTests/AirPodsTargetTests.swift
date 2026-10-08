import Testing
@testable import ControlPanel

struct AirPodsTargetTests {
  @Test func selectsOutputThenPreferredAndNeverGuessesBetweenPairs() {
    let max = AncController.ControlTarget(name: "AirPods Max", address: "max", isMacOutput: false)
    let pro = AncController.ControlTarget(name: "AirPods Pro", address: "pro", isMacOutput: false)
    let output = AncController.ControlTarget(name: "AirPods Pro", address: "pro", isMacOutput: true)
    #expect(AncController.selectTarget([max], preferred: nil) == max)
    #expect(AncController.selectTarget([max, pro], preferred: nil) == nil)
    #expect(AncController.selectTarget([max, pro], preferred: max.name) == max)
    #expect(AncController.selectTarget([max, output], preferred: max.name) == output)
    #expect(AncController.selectTarget([], preferred: max.name) == nil)
  }
}
