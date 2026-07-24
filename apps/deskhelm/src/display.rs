//! External display volume access.

#[cfg(all(target_os = "macos", target_arch = "aarch64"))] mod macos;

#[cfg(all(target_os = "macos", target_arch = "aarch64"))] use std::thread;
#[cfg(any(test, all(target_os = "macos", target_arch = "aarch64")))]
use std::time::{Duration, Instant};

#[cfg(any(test, all(target_os = "macos", target_arch = "aarch64")))] use color_eyre::eyre;
#[cfg(all(target_os = "macos", target_arch = "aarch64"))] use color_eyre::eyre::WrapErr;
#[cfg(all(target_os = "macos", target_arch = "aarch64"))]
use core_graphics::display::CGDisplay;

use crate::prelude::Result;

#[cfg(all(target_os = "macos", target_arch = "aarch64"))]
const AUDIO_VOLUME: u8 = 0x62;
#[cfg(any(test, all(target_os = "macos", target_arch = "aarch64")))]
const LG_VENDOR: u16 = 0x1e6d;
#[cfg(any(test, all(target_os = "macos", target_arch = "aarch64")))]
const LG_39GX950B_PRODUCT: u16 = 0x7863;
#[cfg(any(test, all(target_os = "macos", target_arch = "aarch64")))]
const MINIMUM_SESSION_MESSAGE_GAP_AFTER_SET: Duration = Duration::from_millis(50);

/// A display volume result.
#[derive(Debug)]
pub struct VolumeReading {
	display: String,
	current: u16,
	maximum: u16,
}
impl VolumeReading {
	pub(crate) fn new(display: String, current: u16, maximum: u16) -> Self {
		Self { display, current, maximum }
	}

	/// Returns the display label.
	#[must_use]
	pub fn display(&self) -> &str {
		&self.display
	}

	/// Returns the current or accepted volume value.
	#[must_use]
	pub const fn current(&self) -> u16 {
		self.current
	}

	/// Returns the maximum volume reported by the display.
	#[must_use]
	pub const fn maximum(&self) -> u16 {
		self.maximum
	}
}

pub(crate) struct VerifiedSession {
	#[cfg(all(target_os = "macos", target_arch = "aarch64"))]
	monitor: macos::Monitor,
	#[cfg(all(target_os = "macos", target_arch = "aarch64"))]
	identity: DisplayIdentity,
	#[cfg(all(target_os = "macos", target_arch = "aarch64"))]
	display: String,
	#[cfg(all(target_os = "macos", target_arch = "aarch64"))]
	last_set_completed: Option<Instant>,
}
impl VerifiedSession {
	pub(crate) fn create() -> Result<(Self, VolumeReading)> {
		create_verified_session()
	}

	pub(crate) fn read_volume(&mut self) -> Result<VolumeReading> {
		read_verified_session(self)
	}

	pub(crate) fn set_volume(&mut self, level: u8) -> Result<VolumeReading> {
		validate_requested_level(level)?;

		set_verified_session(self, level)
	}

	pub(crate) fn write_volume(&mut self, level: u8) -> Result<VolumeReading> {
		validate_requested_level(level)?;

		write_verified_session(self, level)
	}
}

#[cfg(any(test, all(target_os = "macos", target_arch = "aarch64")))]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct DisplayIdentity {
	vendor: u16,
	product: u16,
}

/// Reads the current volume from the connected external LG display.
pub fn read_volume() -> Result<VolumeReading> {
	read_volume_inner()
}

/// Sets the connected external LG display volume and returns the confirmed value.
pub fn set_volume(level: u8) -> Result<VolumeReading> {
	validate_requested_level(level)?;

	set_volume_inner(level)
}

#[cfg(all(target_os = "macos", target_arch = "aarch64"))]
fn read_volume_inner() -> Result<VolumeReading> {
	let (mut monitor, _, display) = selected_monitor()?;

	read_from_monitor(&mut monitor, &display)
}

#[cfg(all(target_os = "macos", target_arch = "aarch64"))]
fn set_volume_inner(level: u8) -> Result<VolumeReading> {
	let (mut monitor, _, display) = selected_monitor()?;
	let previous = read_from_monitor(&mut monitor, &display)?;

	validate_supported_maximum(previous.maximum)?;

	set_and_confirm(&mut monitor, &display, level)
}

#[cfg(not(all(target_os = "macos", target_arch = "aarch64")))]
fn read_volume_inner() -> Result<VolumeReading> {
	color_eyre::eyre::bail!(
		"External display volume control is supported only on Apple Silicon macOS."
	)
}

#[cfg(not(all(target_os = "macos", target_arch = "aarch64")))]
fn set_volume_inner(_level: u8) -> Result<VolumeReading> {
	color_eyre::eyre::bail!(
		"External display volume control is supported only on Apple Silicon macOS."
	)
}

#[cfg(all(target_os = "macos", target_arch = "aarch64"))]
fn create_verified_session() -> Result<(VerifiedSession, VolumeReading)> {
	let (mut monitor, identity, display) = selected_monitor()?;
	let reading = read_from_monitor(&mut monitor, &display)?;

	validate_supported_maximum(reading.maximum)?;

	Ok((VerifiedSession { monitor, identity, display, last_set_completed: None }, reading))
}

#[cfg(not(all(target_os = "macos", target_arch = "aarch64")))]
fn create_verified_session() -> Result<(VerifiedSession, VolumeReading)> {
	color_eyre::eyre::bail!(
		"External display volume control is supported only on Apple Silicon macOS."
	)
}

#[cfg(all(target_os = "macos", target_arch = "aarch64"))]
fn read_verified_session(session: &mut VerifiedSession) -> Result<VolumeReading> {
	verify_current_display(session.identity)?;
	wait_for_session_message(session);

	let reading = read_from_monitor(&mut session.monitor, &session.display)?;

	validate_supported_maximum(reading.maximum)?;

	Ok(reading)
}

#[cfg(not(all(target_os = "macos", target_arch = "aarch64")))]
fn read_verified_session(_session: &mut VerifiedSession) -> Result<VolumeReading> {
	color_eyre::eyre::bail!(
		"External display volume control is supported only on Apple Silicon macOS."
	)
}

#[cfg(all(target_os = "macos", target_arch = "aarch64"))]
fn set_verified_session(session: &mut VerifiedSession, level: u8) -> Result<VolumeReading> {
	verify_current_display(session.identity)?;
	write_session_value(session, level)?;

	let reading = confirm_written_value(&mut session.monitor, &session.display, level)?;

	validate_supported_maximum(reading.maximum)?;

	Ok(reading)
}

#[cfg(not(all(target_os = "macos", target_arch = "aarch64")))]
fn set_verified_session(_session: &mut VerifiedSession, _level: u8) -> Result<VolumeReading> {
	color_eyre::eyre::bail!(
		"External display volume control is supported only on Apple Silicon macOS."
	)
}

#[cfg(all(target_os = "macos", target_arch = "aarch64"))]
fn write_verified_session(session: &mut VerifiedSession, level: u8) -> Result<VolumeReading> {
	verify_current_display(session.identity)?;
	write_session_value(session, level)?;

	Ok(accepted_write(&session.display, level))
}

#[cfg(not(all(target_os = "macos", target_arch = "aarch64")))]
fn write_verified_session(_session: &mut VerifiedSession, _level: u8) -> Result<VolumeReading> {
	color_eyre::eyre::bail!(
		"External display volume control is supported only on Apple Silicon macOS."
	)
}

#[cfg(all(target_os = "macos", target_arch = "aarch64"))]
fn selected_monitor() -> Result<(macos::Monitor, DisplayIdentity, String)> {
	let identity = current_external_display_identity()?;
	let display = lg_display_label(identity.vendor, identity.product)?;
	let monitors =
		macos::Monitor::discover().wrap_err("Could not access the macOS DDC/CI service.")?;
	let mut matching_monitors = Vec::new();

	for monitor in monitors {
		let monitor_identity = monitor
			.identity()
			.wrap_err("Could not identify a macOS DDC/CI service from its display EDID.")?;

		if monitor_identity == (identity.vendor, identity.product) {
			matching_monitors.push(monitor);
		}
	}

	validate_monitor_count(matching_monitors.len())?;

	let monitor = matching_monitors
		.pop()
		.ok_or_else(|| eyre::eyre!("DDC/CI service discovery became inconsistent."))?;

	Ok((monitor, identity, display))
}

#[cfg(all(target_os = "macos", target_arch = "aarch64"))]
fn current_external_display_identity() -> Result<DisplayIdentity> {
	let external_displays: Vec<_> = CGDisplay::active_displays()
		.map_err(|code| {
			eyre::eyre!("Could not discover displays through Core Graphics (error {code}).")
		})?
		.into_iter()
		.filter(|display_id| !CGDisplay::new(*display_id).is_builtin())
		.map(CGDisplay::new)
		.collect();

	validate_external_count(external_displays.len())?;

	let display = external_displays
		.into_iter()
		.next()
		.ok_or_else(|| eyre::eyre!("External display discovery became inconsistent."))?;
	let vendor = display.vendor_number() as u16;
	let product = display.model_number() as u16;

	Ok(DisplayIdentity { vendor, product })
}

#[cfg(all(target_os = "macos", target_arch = "aarch64"))]
fn verify_current_display(expected: DisplayIdentity) -> Result<()> {
	let actual = current_external_display_identity()?;

	validate_session_identity(expected, actual)
}

#[cfg(all(target_os = "macos", target_arch = "aarch64"))]
fn read_from_monitor(monitor: &mut macos::Monitor, display: &str) -> Result<VolumeReading> {
	let (current, maximum) = monitor.read_value(AUDIO_VOLUME).wrap_err_with(|| {
		format!(
			"Could not read volume from {display} over DDC/CI. The display, cable, adapter, dock, \
			 or macOS may have rejected the request."
		)
	})?;

	if current > 100 {
		eyre::bail!(
			"{display} returned volume {}, which is outside DeskHelm's supported 0–100 range.",
			current
		);
	}

	Ok(VolumeReading::new(display.to_owned(), current, maximum))
}

#[cfg(all(target_os = "macos", target_arch = "aarch64"))]
fn set_and_confirm(
	monitor: &mut macos::Monitor,
	display: &str,
	level: u8,
) -> Result<VolumeReading> {
	write_to_monitor(monitor, display, level)?;

	confirm_written_value(monitor, display, level)
}

#[cfg(all(target_os = "macos", target_arch = "aarch64"))]
fn confirm_written_value(
	monitor: &mut macos::Monitor,
	display: &str,
	level: u8,
) -> Result<VolumeReading> {
	thread::sleep(Duration::from_millis(80));

	let reading = read_from_monitor(monitor, display)?;

	verify_set_volume(level, reading.current)?;

	Ok(reading)
}

#[cfg(all(target_os = "macos", target_arch = "aarch64"))]
fn write_session_value(session: &mut VerifiedSession, level: u8) -> Result<()> {
	wait_for_session_message(session);

	let result = write_to_monitor(&mut session.monitor, &session.display, level);

	session.last_set_completed = Some(Instant::now());

	result
}

#[cfg(all(target_os = "macos", target_arch = "aarch64"))]
fn wait_for_session_message(session: &VerifiedSession) {
	let delay = remaining_session_message_gap(session.last_set_completed, Instant::now());

	if !delay.is_zero() {
		thread::sleep(delay);
	}
}

#[cfg(all(target_os = "macos", target_arch = "aarch64"))]
fn write_to_monitor(monitor: &mut macos::Monitor, display: &str, level: u8) -> Result<()> {
	monitor.set_value(AUDIO_VOLUME, u16::from(level)).wrap_err_with(|| {
		format!(
			"Could not set volume on {display} over DDC/CI. The display, cable, adapter, dock, \
			 or macOS may have rejected the request."
		)
	})
}

#[cfg(any(test, all(target_os = "macos", target_arch = "aarch64")))]
fn remaining_session_message_gap(last_set_completed: Option<Instant>, now: Instant) -> Duration {
	last_set_completed.map_or(Duration::ZERO, |completed| {
		MINIMUM_SESSION_MESSAGE_GAP_AFTER_SET
			.saturating_sub(now.saturating_duration_since(completed))
	})
}

#[cfg(any(test, all(target_os = "macos", target_arch = "aarch64")))]
fn accepted_write(display: &str, level: u8) -> VolumeReading {
	VolumeReading::new(display.to_owned(), u16::from(level), 100)
}

#[cfg(any(test, all(target_os = "macos", target_arch = "aarch64")))]
fn lg_display_label(vendor: u16, product: u16) -> Result<String> {
	if vendor != LG_VENDOR {
		eyre::bail!(
			"External display {vendor:04x}:{product:04x} is not an LG display. This DeskHelm MVP \
			 supports LG displays only."
		);
	}

	let model = match product {
		LG_39GX950B_PRODUCT => "LG 39GX950B",
		_ => "LG display",
	};

	Ok(format!("{model} ({vendor:04x}:{product:04x})"))
}

#[cfg(any(test, all(target_os = "macos", target_arch = "aarch64")))]
fn validate_session_identity(expected: DisplayIdentity, actual: DisplayIdentity) -> Result<()> {
	if actual != expected {
		eyre::bail!(
			"The connected external display changed from {:04x}:{:04x} to {:04x}:{:04x}. Discard \
			 this DeskHelm session and reconnect to the intended display.",
			expected.vendor,
			expected.product,
			actual.vendor,
			actual.product
		);
	}

	Ok(())
}

#[cfg(any(test, all(target_os = "macos", target_arch = "aarch64")))]
fn validate_external_count(external_count: usize) -> Result<()> {
	if external_count == 0 {
		eyre::bail!("No external display is connected.");
	}
	if external_count > 1 {
		eyre::bail!(
			"More than one external display is connected. Disconnect all but the target display \
			 and try again."
		);
	}

	Ok(())
}

#[cfg(any(test, all(target_os = "macos", target_arch = "aarch64")))]
fn validate_monitor_count(monitor_count: usize) -> Result<()> {
	match monitor_count {
		0 => eyre::bail!(
			"The LG display is connected, but no DDC/CI service has a matching display identity. \
			 Enable DDC/CI on the display and check the cable, adapter, or dock."
		),
		1 => Ok(()),
		_ => eyre::bail!(
			"More than one DDC/CI service matches the LG display identity. DeskHelm cannot safely \
			 select a service."
		),
	}
}

#[cfg(any(test, all(target_os = "macos", target_arch = "aarch64")))]
fn validate_supported_maximum(maximum: u16) -> Result<()> {
	if maximum != 100 {
		eyre::bail!(
			"The display reports a maximum volume of {maximum}; this DeskHelm MVP writes only \
			 displays whose volume range is 0–100."
		);
	}

	Ok(())
}

fn validate_requested_level(level: u8) -> Result<()> {
	if level > 100 {
		eyre::bail!("Volume level {level} is outside the supported 0–100 range.");
	}

	Ok(())
}

#[cfg(any(test, all(target_os = "macos", target_arch = "aarch64")))]
fn verify_set_volume(requested: u8, actual: u16) -> Result<()> {
	if actual != u16::from(requested) {
		color_eyre::eyre::bail!(
			"The display reported volume {actual} after DeskHelm requested {requested}; the \
			 DDC/CI write was not confirmed."
		);
	}

	Ok(())
}

#[cfg(test)]
mod tests {
	use std::time::{Duration, Instant};

	use crate::display;

	#[test]
	fn no_external_display_has_a_specific_error() {
		let error = display::validate_external_count(0).expect_err("no display must fail");

		assert!(error.to_string().contains("No external display"));
	}

	#[test]
	fn unsupported_external_display_has_a_specific_error() {
		let error = display::validate_monitor_count(0).expect_err("unsupported display must fail");

		assert!(error.to_string().contains("no DDC/CI service has a matching display identity"));
	}

	#[test]
	fn multiple_supported_displays_fail_safely() {
		let error = display::validate_external_count(2).expect_err("ambiguous displays must fail");

		assert!(error.to_string().contains("More than one external display"));
	}

	#[test]
	fn multiple_ddc_services_fail_safely() {
		let error = display::validate_monitor_count(2).expect_err("ambiguous services must fail");

		assert!(error.to_string().contains("More than one DDC/CI service matches"));
	}

	#[test]
	fn non_lg_display_is_rejected() {
		let error =
			display::lg_display_label(0x1234, 0x5678).expect_err("non-LG display must fail");

		assert!(error.to_string().contains("is not an LG display"));
	}

	#[test]
	fn known_lg_product_uses_its_model_name() {
		assert_eq!(
			display::lg_display_label(0x1e6d, 0x7863).expect("known LG display must be accepted"),
			"LG 39GX950B (1e6d:7863)"
		);
	}

	#[test]
	fn verified_session_accepts_the_same_display_identity() {
		let identity = display::DisplayIdentity { vendor: 0x1e6d, product: 0x7863 };

		assert!(display::validate_session_identity(identity, identity).is_ok());
	}

	#[test]
	fn verified_session_rejects_a_changed_display_identity() {
		let expected = display::DisplayIdentity { vendor: 0x1e6d, product: 0x7863 };
		let actual = display::DisplayIdentity { vendor: 0x1e6d, product: 0x1234 };
		let error = display::validate_session_identity(expected, actual)
			.expect_err("a changed display must invalidate the session");

		assert!(error.to_string().contains("connected external display changed"));
		assert!(error.to_string().contains("Discard this DeskHelm session"));
	}

	#[test]
	fn nonstandard_display_maximum_is_rejected() {
		let error =
			display::validate_supported_maximum(50).expect_err("nonstandard maximum must fail");

		assert!(error.to_string().contains("maximum volume of 50"));
	}

	#[test]
	fn one_hundred_display_maximum_is_accepted() {
		assert!(display::validate_supported_maximum(100).is_ok());
	}

	#[test]
	fn requested_volume_above_one_hundred_is_rejected_before_device_access() {
		let error = display::set_volume(101).expect_err("out-of-range volume must fail");

		assert!(error.to_string().contains("outside the supported 0–100 range"));
	}

	#[test]
	fn accepted_fast_write_reports_the_requested_value() {
		let reading = display::accepted_write("LG 39GX950B", 42);

		assert_eq!(reading.display(), "LG 39GX950B");
		assert_eq!(reading.current(), 42);
		assert_eq!(reading.maximum(), 100);
	}

	#[test]
	fn session_message_without_a_prior_set_has_no_gap_delay() {
		assert_eq!(display::remaining_session_message_gap(None, Instant::now()), Duration::ZERO);
	}

	#[test]
	fn session_message_after_a_recent_set_waits_for_the_remaining_gap() {
		let completed = Instant::now();

		assert_eq!(
			display::remaining_session_message_gap(Some(completed), completed),
			Duration::from_millis(50)
		);
		assert_eq!(
			display::remaining_session_message_gap(
				Some(completed),
				completed + Duration::from_millis(20)
			),
			Duration::from_millis(30)
		);
	}

	#[test]
	fn session_message_after_the_minimum_set_gap_has_no_delay() {
		let completed = Instant::now();

		assert_eq!(
			display::remaining_session_message_gap(
				Some(completed),
				completed + Duration::from_millis(50)
			),
			Duration::ZERO
		);
		assert_eq!(
			display::remaining_session_message_gap(
				Some(completed),
				completed + Duration::from_millis(80)
			),
			Duration::ZERO
		);
	}

	#[test]
	fn matching_write_readback_is_accepted() {
		assert!(display::verify_set_volume(42, 42).is_ok());
	}

	#[test]
	fn mismatched_write_readback_is_an_error() {
		let error = display::verify_set_volume(42, 41).expect_err("mismatched readback must fail");

		assert!(error.to_string().contains("write was not confirmed"));
	}
}
