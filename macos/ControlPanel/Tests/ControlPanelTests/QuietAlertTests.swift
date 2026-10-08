import Foundation
import Testing
@testable import ControlPanel

struct QuietAlertTests {
  @MainActor private func model() -> StatusModel {
    let model = StatusModel(startMonitoring: false)
    model.active = true
    model.reachable = true
    model.headphonesConnected = true
    return model
  }

  @MainActor @Test func phonePlaybackDoesNotPlayMacQuietAlert() {
    let m = model()
    let start = Date(timeIntervalSince1970: 10000)
    m.headphonesAreMacOutput = false
    #expect(!m.quietAlertDue(at: start, enabled: true))
    #expect(!m.quietAlertDue(at: start.addingTimeInterval(1800), enabled: true))
  }

  @MainActor @Test func repeatedNearMissesDeferButDoNotResetQuietTime() {
    let m = model()
    let start = Date(timeIntervalSince1970: 10000)
    #expect(!m.quietAlertDue(at: start, enabled: true))
    for seconds in stride(from: 100, through: 900, by: 100) {
      m.ancPhase = "armed"
      #expect(!m.quietAlertDue(at: start.addingTimeInterval(Double(seconds)), enabled: true))
    }
    m.ancPhase = "idle"
    #expect(m.quietAlertDue(at: start.addingTimeInterval(902), enabled: true))
    #expect(!m.quietAlertDue(at: start.addingTimeInterval(904), enabled: true))
    #expect(m.quietAlertDue(at: start.addingTimeInterval(1502), enabled: true))
  }

  @MainActor @Test func actualEngagementRestartsQuietWindow() {
    let m = model()
    let start = Date(timeIntervalSince1970: 10000)
    #expect(!m.quietAlertDue(at: start, enabled: true))
    m.ancPhase = "engaged"
    #expect(!m.quietAlertDue(at: start.addingTimeInterval(590), enabled: true))
    m.ancPhase = "idle"
    #expect(!m.quietAlertDue(at: start.addingTimeInterval(601), enabled: true))
    #expect(m.quietAlertDue(at: start.addingTimeInterval(1190), enabled: true))
  }

  @MainActor @Test func unavailableMonitoringNeverAnnouncesQuiet() {
    let m = model()
    let start = Date(timeIntervalSince1970: 10000)
    #expect(!m.quietAlertDue(at: start, enabled: true))
    let later = start.addingTimeInterval(900)
    m.feedOk = false
    #expect(!m.quietAlertDue(at: later, enabled: true))
    m.feedOk = true
    m.headphonesConnected = false
    #expect(!m.quietAlertDue(at: later, enabled: true))
    m.headphonesConnected = true
    m.reachable = false
    #expect(!m.quietAlertDue(at: later, enabled: true))
    m.reachable = true
    #expect(!m.quietAlertDue(at: later, enabled: false))
    m.active = false
    #expect(!m.quietAlertDue(at: later, enabled: true))
    m.active = true
    #expect(!m.quietAlertDue(at: later, enabled: true))
  }
}
