import SwiftUI

@main
struct ControlPanelApp: App {
  @State private var model = StatusModel()

  var body: some Scene {
    MenuBarExtra {
      PanelView(model: model)
    } label: {
      Image(systemName: menuIcon)
    }
    .menuBarExtraStyle(.window)
  }

  private var menuIcon: String {
    if !model.reachable { return "airplane.slash" }
    if model.active && model.mode == "anc" { return "airpodsmax" }
    return model.active ? "airplane.circle.fill" : "airplane"
  }
}
