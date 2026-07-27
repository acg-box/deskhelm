import CoreGraphics
import Testing

@testable import DeskHelmMac

@MainActor
@Suite("Display reconfiguration monitor")
struct DisplayReconfigurationMonitorTests {
  @Test("A callback burst emits one begin and one settled event")
  func callbackBurstIsCoalesced() async {
    var events: [DisplayReconfigurationEvent] = []
    let monitor = DisplayReconfigurationMonitor(
      settleDelay: .zero,
      onEvent: { events.append($0) }
    )

    monitor.receive(CGDisplayChangeSummaryFlags(rawValue: 1 << 0))
    monitor.receive(CGDisplayChangeSummaryFlags(rawValue: 1 << 4))
    monitor.receive(CGDisplayChangeSummaryFlags(rawValue: 1 << 5))
    await waitForEventCount(2, events: { events })

    #expect(events == [.began, .settled])
  }

  @Test("A begin callback waits for a completion callback")
  func beginCallbackWaitsForCompletion() async {
    var events: [DisplayReconfigurationEvent] = []
    let monitor = DisplayReconfigurationMonitor(
      settleDelay: .zero,
      onEvent: { events.append($0) }
    )

    monitor.receive(CGDisplayChangeSummaryFlags(rawValue: 1 << 0))
    for _ in 0..<20 {
      await Task.yield()
    }

    #expect(events == [.began])
  }

  @Test("The callback context delivers one ordered FIFO")
  func callbackContextIsOrdered() async {
    var rawFlags: [UInt32] = []
    let context = DisplayReconfigurationCallbackContext {
      rawFlags.append($0.rawValue)
    }

    context.enqueue(CGDisplayChangeSummaryFlags(rawValue: 1 << 0))
    context.enqueue(CGDisplayChangeSummaryFlags(rawValue: 1 << 4))
    context.enqueue(CGDisplayChangeSummaryFlags(rawValue: 1 << 5))
    await waitForEventCount(3, events: { rawFlags })

    #expect(rawFlags == [1 << 0, 1 << 4, 1 << 5])
  }

  @Test("A stopped callback context drops queued delivery")
  func stoppedCallbackContextDropsDelivery() async {
    var rawFlags: [UInt32] = []
    let context = DisplayReconfigurationCallbackContext {
      rawFlags.append($0.rawValue)
    }

    context.enqueue(CGDisplayChangeSummaryFlags(rawValue: 1 << 0))
    context.deactivate()
    await Task.yield()

    #expect(rawFlags.isEmpty)
  }

  private func waitForEventCount<Element>(
    _ count: Int,
    events: () -> [Element]
  ) async {
    for _ in 0..<500 {
      if events().count == count {
        return
      }
      await Task.yield()
    }
    Issue.record("Timed out waiting for display reconfiguration events.")
  }
}
