import CDeskHelm
import Testing

private typealias ReadVolumeFunction =
  @convention(c) (UnsafeMutablePointer<DeskHelmVolumeResult>?) -> Int32
private typealias SetVolumeFunction =
  @convention(c) (
    Int32,
    UnsafeMutablePointer<DeskHelmVolumeResult>?
  ) -> Int32
private typealias SessionCreateFunction =
  @convention(c) (
    UnsafeMutablePointer<OpaquePointer?>?,
    UnsafeMutablePointer<DeskHelmVolumeResult>?
  ) -> Int32
private typealias SessionReadFunction =
  @convention(c) (
    OpaquePointer?,
    UnsafeMutablePointer<DeskHelmVolumeResult>?
  ) -> Int32
private typealias SessionSetFunction =
  @convention(c) (
    OpaquePointer?,
    Int32,
    UnsafeMutablePointer<DeskHelmVolumeResult>?
  ) -> Int32
private typealias SessionFreeFunction =
  @convention(c) (OpaquePointer?) -> Void
private typealias ResultFreeFunction =
  @convention(c) (UnsafeMutablePointer<DeskHelmVolumeResult>?) -> Void

@Suite("C ABI")
struct CDeskHelmABITests {
  @Test("Header status values and result layout match the stable contract")
  func headerContract() {
    #expect(Int32(DESKHELM_STATUS_OK) == 0)
    #expect(Int32(DESKHELM_STATUS_RUNTIME_ERROR) == 1)
    #expect(Int32(DESKHELM_STATUS_INVALID_ARGUMENT) == 2)
    #expect(Int32(DESKHELM_STATUS_PANIC) == 3)

    #expect(MemoryLayout<DeskHelmVolumeResult>.size == 24)
    #expect(MemoryLayout<DeskHelmVolumeResult>.stride == 24)
    #expect(MemoryLayout<DeskHelmVolumeResult>.alignment == 8)
    #expect(
      MemoryLayout<DeskHelmVolumeResult>.offset(
        of: \DeskHelmVolumeResult.current
      ) == 0
    )
    #expect(
      MemoryLayout<DeskHelmVolumeResult>.offset(
        of: \DeskHelmVolumeResult.maximum
      ) == 2
    )
    #expect(
      MemoryLayout<DeskHelmVolumeResult>.offset(
        of: \DeskHelmVolumeResult.display
      ) == 8
    )
    #expect(
      MemoryLayout<DeskHelmVolumeResult>.offset(
        of: \DeskHelmVolumeResult.error
      ) == 16
    )
  }

  @Test("Every exported symbol links without hardware access")
  func exportedSymbols() {
    let invalidArgument = Int32(DESKHELM_STATUS_INVALID_ARGUMENT)
    let readVolume: ReadVolumeFunction = deskhelm_read_volume
    let setVolume: SetVolumeFunction = deskhelm_set_volume
    let sessionCreate: SessionCreateFunction = deskhelm_session_create
    let sessionRead: SessionReadFunction = deskhelm_session_read
    let sessionSet: SessionSetFunction = deskhelm_session_set
    let sessionWrite: SessionSetFunction = deskhelm_session_write
    let sessionFree: SessionFreeFunction = deskhelm_session_free
    let resultFree: ResultFreeFunction = deskhelm_volume_result_free

    #expect(readVolume(nil) == invalidArgument)
    #expect(setVolume(42, nil) == invalidArgument)
    #expect(sessionCreate(nil, nil) == invalidArgument)
    #expect(sessionRead(nil, nil) == invalidArgument)
    #expect(sessionSet(nil, 42, nil) == invalidArgument)
    #expect(sessionWrite(nil, 42, nil) == invalidArgument)
    sessionFree(nil)
    resultFree(nil)
  }

  @Test("Invalid calls preserve result layout and ownership")
  func invalidResultOwnership() {
    var result = DeskHelmVolumeResult()

    let status = deskhelm_session_write(nil, -1, &result)

    #expect(status == Int32(DESKHELM_STATUS_INVALID_ARGUMENT))
    #expect(result.current == 0)
    #expect(result.maximum == 0)
    #expect(result.display == nil)
    #expect(result.error != nil)
    if let error = result.error {
      #expect(
        String(cString: UnsafePointer(error))
          .contains("outside the supported 0–100 range")
      )
    }

    deskhelm_volume_result_free(&result)

    #expect(result.current == 0)
    #expect(result.maximum == 0)
    #expect(result.display == nil)
    #expect(result.error == nil)
  }
}
