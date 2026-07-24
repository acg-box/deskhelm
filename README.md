# DeskHelm

DeskHelm is an early native macOS menu bar prototype for an external LG
display. A Rust core reads and sets display audio volume through DDC/CI. A
command-line interface and a native menu bar app use the same core.

DeskHelm does not invoke another display-control command-line tool.

## Requirements

- An Apple Silicon Mac.
- macOS 14 or later for the menu bar app.
- One external LG display whose DDC/CI audio volume (VCP code `0x62`) reports
  the range 0–100.
- DDC/CI enabled in the display settings.
- A connection path that passes DDC/CI traffic. Some docks and adapters block it.

## Run The App

Build the Rust core and SwiftUI app, stage `DeskHelm.app`, and open it:

```sh
./script/build_and_run.sh
```

DeskHelm runs as a menu-bar-only app and does not add a Dock icon. Select the
DeskHelm control-deck icon to open the volume panel. The status item has no text
label. The transparent, borderless, nonactivating panel can accept input without
taking focus from the current app. On macOS 26 or later, it hosts one surface
made with the public Liquid Glass APIs. Older supported macOS versions use one
adaptive system material surface.

To rebuild, launch, and confirm that DeskHelm created its AppKit status item:

```sh
./script/build_and_run.sh --verify
```

This diagnostic checks the app-owned status item. Menu bar space, a display
notch, or a third-party menu bar manager can still affect what macOS shows.

To also open the panel and verify that AppKit made it visible, key, nonactivating,
and positioned on the status item's screen:

```sh
./script/build_and_run.sh --verify-panel
```

The panel reads the confirmed display volume when it opens and retains that
verified display session. Moving the slider updates the UI immediately. DeskHelm
coalesces rapid movement into native DDC/CI preview writes. A preview reports
only that macOS accepted the transport request; it does not replace the last
confirmed value. DeskHelm reads the value back after 150 ms without new input,
or immediately when the slider is released. If the value differs, DeskHelm
performs one exact write and readback. A failed preview or confirmation triggers
a fresh hardware read. A failed refresh or recovery read marks the display
unavailable instead of showing an old value as current.

The custom volume control supports pointer dragging, the arrow keys, and the
VoiceOver adjustable action. If you select refresh during an active preview or
confirmation, DeskHelm queues one read instead of flashing or ignoring the
request.

### Optional Keyboard Volume Keys

Open the ellipsis menu in the panel and select **Enable Volume Keys…**. DeskHelm
first confirms that it can read the display, then asks macOS for Accessibility
permission. After you grant access, select **Enable Volume Keys…** again.

While the feature is enabled, DeskHelm checks the current macOS default audio
output for every recognized volume event. It consumes the event only when the
output is the LG UltraGear display. Each accepted press or system repeat adjusts
the display by one point. Holding a key uses the existing macOS key-repeat events
for continuous adjustment. Each accepted event updates the visible volume
surface and queues the latest preview target. One readback follows after input
stops.

The HUD does not accept mouse input. It is an app-owned surface, not Apple's
private system volume OSD. On macOS 26 or later, its SwiftUI content uses one
public `.clear.interactive()` Liquid Glass surface. The nonactivating panel
temporarily becomes the key window while the HUD is visible. This keeps the
clear, refractive glass appearance instead of the opaque inactive-window
appearance. The panel orders out after 1.25 seconds without new input.
Opening the menu panel dismisses a visible HUD. While the menu panel is open,
volume keys animate its control directly and do not open a second key window.

The menu control derives its track, thumb, and number from one animated level.
The HUD derives its progress, speaker symbol, and number from one animated
level. During a held key, each linear segment uses the preceding repeat interval
as its duration. This removes the dead time between one-point targets and keeps
the visual value separate from the immediate DDC/CI target. Reduce Motion makes
the update immediate.

For Bluetooth headphones, Mac speakers, and all other outputs, DeskHelm returns
the event unchanged so macOS can adjust that device normally. A Core Audio query
failure or more than one matching LG UltraGear audio endpoint also returns the
event unchanged. The feature is off by default. It subscribes to macOS
system-defined events only and does not subscribe to ordinary key-down or key-up
events, retain input, or inspect other apps. macOS still grants broad
Accessibility trust, so enable the feature only if you accept that permission
scope.

If permission is missing, macOS disables the event filter, or DDC/CI
communication fails, DeskHelm removes the filter. Later key presses then return
to normal macOS handling. DeskHelm does not intercept the mute key in this
version.

## Run The CLI

Build the Rust core and CLI:

```sh
cargo build --locked -p deskhelm
```

Read the current display volume:

```sh
cargo run --locked -p deskhelm -- volume
```

Set the display volume to a value from 0 through 100:

```sh
cargo run --locked -p deskhelm -- volume 25
```

The set command reads the volume before it writes. It refuses to write if the
display does not report a 0–100 range. It then reads the value back and reports
an error if the display does not confirm it. DeskHelm rejects values outside
0–100 before it contacts the display.

DeskHelm stops if the connected display is not LG, if it cannot match the
display to a DDC/CI service through its EDID, or if display or service selection
is ambiguous.

## Architecture

An AppKit `NSStatusItem` and transparent borderless `NSPanel` own the
menu-bar-only lifecycle and host the SwiftUI volume panel. The window has no
second background or popover chrome. The panel calls a narrow C ABI in the Rust
static library. The Rust core uses Core Graphics for display identity and the
macOS IOKit display service for DDC/CI transport. It reads and writes only VCP
code `0x62`, which is the display audio-volume control.

The optional keyboard path uses an active Core Graphics session event tap. Its
callback only classifies system-defined events; the main actor owns DDC/CI work,
write coalescing, feature state, and the transient HUD. DeskHelm uses no helper
CLI, private system-OSD call, Finder automation, or browser automation.

The app supplies its own native volume control. It does not make the disabled
volume slider in macOS Control Center adjustable. That slider belongs to the
Core Audio device model. Integrating there would require a separate Core Audio
HAL plug-in and a different installation, signing, and compatibility scope.

## Limitations

- DeskHelm uses the undocumented macOS `IOAVService` interface. A macOS update
  can change or remove this interface.
- Apple does not document the packed media-key payload used by the event
  decoder. Keyboard control is therefore an opt-in compatibility feature that
  needs physical testing after macOS or keyboard changes.
- DeskHelm cannot invoke Apple's genuine volume OSD through a public API. Its
  transient HUD uses public AppKit and SwiftUI surfaces. It temporarily takes
  key-window status to preserve the clear, refractive Liquid Glass appearance.
  Apple can change this appearance or its focus behavior in a macOS update.
- Local app staging uses ad-hoc signing by default. Set an Apple Development
  identity to retain Accessibility authorization across rebuilds. A distributed
  build still needs a Developer ID signature and notarization.
- The SwiftUI app controls the display directly. It does not register the
  display as a Core Audio output device, and this version does not map the mute
  key to monitor state.
- The current implementation supports Apple Silicon only and uses the standard
  DDC/CI I2C address `0x37`. Apple display paths that require another address,
  including some built-in HDMI bridges, are not supported.
- The hardware check uses an LG 39GX950B with vendor/product ID `1e6d:7863`.
  The display is connected directly to an M4 Max Mac through USB-C. macOS
  exposes its DisplayPort Alt Mode link through the external DCP/DP service
  path; this does not mean that the physical connector is DisplayPort.
- DDC/CI support and response timing vary by display, cable, adapter, and dock.
- Interactive writes are faster than hardware readback, so the UI and requested
  volume can move before the app has confirmed the display value. DeskHelm keeps
  the latest draft visible and confirms it after input stops.
- This version controls only volume. It does not change brightness, input
  source, or other display settings.

## Development

Run the repository validation gate:

```sh
npm ci --ignore-scripts
cargo make check
```

On macOS, this gate also builds the menu bar app and runs its Swift tests. Run
only the Swift tests with:

```sh
./script/build_and_run.sh --test
```

The native build script uses `/Applications/Xcode-beta.app` and ad-hoc signing
by default. Set `DESKHELM_CODE_SIGN_IDENTITY` to an authorized Apple Development
identity when Accessibility authorization must persist across rebuilds.

The source is licensed under [GPL-3.0-only](LICENSE).
