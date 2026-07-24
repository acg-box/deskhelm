//! Apple Silicon DDC/CI transport.

use std::{ffi::c_void, ptr, slice, thread, time::Duration};

use color_eyre::{Result, eyre};
use core_foundation_sys::{
	base::{CFAllocatorRef, CFRelease, CFTypeRef, kCFAllocatorDefault},
	data::{CFDataGetBytePtr, CFDataGetLength, CFDataRef},
};
use io_kit_sys::{
	IOIteratorNext, IOObjectRelease, IOServiceGetMatchingServices, IOServiceMatching,
	kIOMasterPortDefault,
	types::{io_iterator_t, io_object_t, io_service_t},
};

const DDC_ADDRESS: u32 = 0x37;
const DDC_DATA_ADDRESS: u32 = 0x51;
const READ_ATTEMPTS: usize = 5;
const WRITE_CYCLES: usize = 2;

pub(super) struct Monitor {
	service: CFTypeRef,
}
impl Monitor {
	pub(super) fn discover() -> Result<Vec<Self>> {
		// SAFETY: The C string is static. IOKit consumes the returned matching dictionary.
		let matching = unsafe { IOServiceMatching(c"DCPAVServiceProxy".as_ptr()) };

		if matching.is_null() {
			eyre::bail!("IOKit could not create a DCPAVServiceProxy match request.");
		}

		let mut raw_iterator = 0;
		// SAFETY: `matching` is a valid dictionary returned by IOKit, and the output pointer is
		// valid for one iterator handle.
		let status = unsafe {
			IOServiceGetMatchingServices(kIOMasterPortDefault, matching, &mut raw_iterator)
		};

		verify_io("discover", status)?;

		if raw_iterator == 0 {
			eyre::bail!("IOKit returned an invalid DDC/CI service iterator.");
		}

		let iterator = ServiceIterator(raw_iterator);
		let mut monitors = Vec::new();

		for io_service in iterator {
			// SAFETY: `io_service` is live while this call runs. The returned CF object is
			// retained.
			let service =
				unsafe { IOAVServiceCreateWithService(kCFAllocatorDefault, io_service.0) };

			if service.is_null() {
				eyre::bail!(
					"macOS found a display service but could not open its DDC/CI interface."
				);
			}

			monitors.push(Self { service });
		}

		Ok(monitors)
	}

	pub(super) fn identity(&self) -> Result<(u16, u16)> {
		let mut raw_edid: CFDataRef = ptr::null();
		// SAFETY: The service is retained for `Self`, and the output pointer is valid for one
		// retained CFData reference.
		let status = unsafe { IOAVServiceCopyEDID(self.service, &mut raw_edid) };

		verify_io("read display identity", status)?;

		if raw_edid.is_null() {
			eyre::bail!("macOS returned no EDID for a DDC/CI service.");
		}

		let edid = Edid(raw_edid);
		// SAFETY: `edid.0` remains retained, and Core Foundation owns its immutable bytes.
		let length = unsafe { CFDataGetLength(edid.0) };

		if length < 12 {
			eyre::bail!("macOS returned an EDID that is too short ({length} bytes).");
		}

		// SAFETY: A non-empty retained CFData has a readable byte buffer for its reported length.
		let bytes = unsafe { slice::from_raw_parts(CFDataGetBytePtr(edid.0), length as usize) };

		parse_edid_identity(bytes)
	}

	pub(super) fn read_value(&mut self, code: u8) -> Result<(u16, u16)> {
		let packet = get_packet(code);
		let mut last_error = None;

		for attempt in 0..READ_ATTEMPTS {
			match self.read_once(code, &packet) {
				Ok(value) => return Ok(value),
				Err(error) => last_error = Some(error),
			}

			if attempt + 1 < READ_ATTEMPTS {
				thread::sleep(Duration::from_millis(20));
			}
		}

		let error = last_error.ok_or_else(|| eyre::eyre!("DDC/CI read did not run."))?;

		eyre::bail!("DDC/CI read failed after {READ_ATTEMPTS} attempts: {error}");
	}

	pub(super) fn set_value(&mut self, code: u8, value: u16) -> Result<()> {
		self.write_packet(&set_packet(code, value))
	}

	fn read_once(&mut self, code: u8, packet: &[u8]) -> Result<(u16, u16)> {
		self.write_packet(packet)?;

		thread::sleep(Duration::from_millis(50));

		let mut reply = [0_u8; 11];
		// SAFETY: The service is retained for `Self`, and `reply` is a writable 11-byte buffer.
		let status = unsafe {
			IOAVServiceReadI2C(
				self.service,
				DDC_ADDRESS,
				0,
				reply.as_mut_ptr().cast(),
				reply.len() as u32,
			)
		};

		verify_io("read", status)?;

		parse_get_reply(code, &reply)
	}

	fn write_packet(&mut self, packet: &[u8]) -> Result<()> {
		for _ in 0..WRITE_CYCLES {
			thread::sleep(Duration::from_millis(10));

			// SAFETY: The service is retained for `Self`, and `packet` is readable for its length.
			let status = unsafe {
				IOAVServiceWriteI2C(
					self.service,
					DDC_ADDRESS,
					DDC_DATA_ADDRESS,
					packet.as_ptr().cast(),
					packet.len() as u32,
				)
			};

			verify_io("write", status)?;
		}

		Ok(())
	}
}

impl Drop for Monitor {
	fn drop(&mut self) {
		// SAFETY: `service` is a retained Core Foundation object owned by `Self`.
		unsafe { CFRelease(self.service) };
	}
}

struct ServiceIterator(io_iterator_t);
impl Iterator for ServiceIterator {
	type Item = IoObject;

	fn next(&mut self) -> Option<Self::Item> {
		// SAFETY: `self.0` is a live IOKit iterator until `Drop`.
		let object = unsafe { IOIteratorNext(self.0) };

		(object != 0).then_some(IoObject(object))
	}
}

impl Drop for ServiceIterator {
	fn drop(&mut self) {
		// SAFETY: `self.0` is an iterator returned with a positive retain count.
		let _ = unsafe { IOObjectRelease(self.0) };
	}
}

struct IoObject(io_object_t);
impl Drop for IoObject {
	fn drop(&mut self) {
		// SAFETY: `self.0` is an object returned with a positive retain count.
		let _ = unsafe { IOObjectRelease(self.0) };
	}
}

struct Edid(CFDataRef);
impl Drop for Edid {
	fn drop(&mut self) {
		// SAFETY: `self.0` is a Core Foundation object returned under the Copy rule.
		unsafe { CFRelease(self.0.cast()) };
	}
}

fn parse_edid_identity(edid: &[u8]) -> Result<(u16, u16)> {
	const HEADER: [u8; 8] = [0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00];

	if edid.len() < 12 {
		eyre::bail!("EDID is too short ({} bytes).", edid.len());
	}
	if edid[..HEADER.len()] != HEADER {
		eyre::bail!("EDID has an invalid header.");
	}

	let vendor = u16::from_be_bytes([edid[8], edid[9]]);
	let product = u16::from_le_bytes([edid[10], edid[11]]);

	Ok((vendor, product))
}

fn get_packet(code: u8) -> [u8; 4] {
	let mut packet = [0x82, 0x01, code, 0];

	packet[3] = checksum((DDC_ADDRESS << 1) as u8, &packet[..3]);

	packet
}

fn set_packet(code: u8, value: u16) -> [u8; 6] {
	let [high, low] = value.to_be_bytes();
	let mut packet = [0x84, 0x03, code, high, low, 0];

	packet[5] = checksum(((DDC_ADDRESS << 1) as u8) ^ DDC_DATA_ADDRESS as u8, &packet[..5]);

	packet
}

fn parse_get_reply(code: u8, reply: &[u8; 11]) -> Result<(u16, u16)> {
	let length = reply[1] & 0x7f;

	if length != 8 {
		eyre::bail!("invalid DDC/CI response length {length}; expected 8");
	}
	if checksum(0x50, &reply[..10]) != reply[10] {
		eyre::bail!("invalid DDC/CI response checksum");
	}
	if reply[2] != 0x02 {
		eyre::bail!("invalid DDC/CI response opcode 0x{:02x}", reply[2]);
	}
	if reply[3] == 0x01 {
		eyre::bail!("the display does not support VCP feature 0x{code:02x}");
	}
	if reply[3] != 0 {
		eyre::bail!("the display returned DDC/CI status 0x{:02x}", reply[3]);
	}
	if reply[4] != code {
		eyre::bail!("the display replied for VCP feature 0x{:02x}, not 0x{code:02x}", reply[4]);
	}

	Ok((u16::from_be_bytes([reply[8], reply[9]]), u16::from_be_bytes([reply[6], reply[7]])))
}

fn checksum(initial: u8, bytes: &[u8]) -> u8 {
	bytes.iter().fold(initial, |value, byte| value ^ byte)
}

fn verify_io(operation: &str, status: i32) -> Result<()> {
	if status == io_kit_sys::ret::kIOReturnSuccess {
		return Ok(());
	}

	let status_hex = status as u32;

	match status {
		io_kit_sys::ret::kIOReturnNotPrivileged | io_kit_sys::ret::kIOReturnNotPermitted => {
			eyre::bail!(
				"macOS denied permission to {operation} DDC/CI data (IOKit {status_hex:#010x})"
			)
		},
		io_kit_sys::ret::kIOReturnNoDevice => {
			eyre::bail!(
				"the display disconnected during the DDC/CI {operation} (IOKit {status_hex:#010x})"
			)
		},
		io_kit_sys::ret::kIOReturnUnsupported => {
			eyre::bail!(
				"the display connection does not support DDC/CI {operation} (IOKit {status_hex:#010x})"
			)
		},
		_ => eyre::bail!("DDC/CI {operation} failed with IOKit status {status_hex:#010x}"),
	}
}

#[link(name = "IOKit", kind = "framework")]
unsafe extern "C" {
	fn IOAVServiceCreateWithService(allocator: CFAllocatorRef, service: io_service_t) -> CFTypeRef;
	fn IOAVServiceCopyEDID(service: CFTypeRef, edid: *mut CFDataRef) -> i32;
	fn IOAVServiceReadI2C(
		service: CFTypeRef,
		chip_address: u32,
		offset: u32,
		output_buffer: *mut c_void,
		output_buffer_size: u32,
	) -> i32;
	fn IOAVServiceWriteI2C(
		service: CFTypeRef,
		chip_address: u32,
		data_address: u32,
		input_buffer: *const c_void,
		input_buffer_size: u32,
	) -> i32;
}

#[cfg(test)]
mod tests {
	use crate::display::macos;

	#[test]
	fn lg_edid_identity_is_decoded() {
		let edid = [0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00, 0x1e, 0x6d, 0x63, 0x78];

		assert_eq!(
			macos::parse_edid_identity(&edid).expect("valid EDID must decode"),
			(0x1e6d, 0x7863)
		);
	}

	#[test]
	fn invalid_edid_header_is_rejected() {
		let edid = [0_u8; 12];

		assert!(macos::parse_edid_identity(&edid).is_err());
	}

	#[test]
	fn volume_get_packet_matches_apple_silicon_transport() {
		assert_eq!(macos::get_packet(0x62), [0x82, 0x01, 0x62, 0x8f]);
	}

	#[test]
	fn volume_set_packet_matches_apple_silicon_transport() {
		assert_eq!(macos::set_packet(0x62, 6), [0x84, 0x03, 0x62, 0x00, 0x06, 0xdc]);
	}

	#[test]
	fn valid_volume_reply_is_decoded() {
		let reply = [0x6e, 0x88, 0x02, 0x00, 0x62, 0x00, 0x00, 0x64, 0x00, 0x05, 0xb7];

		assert_eq!(
			macos::parse_get_reply(0x62, &reply).expect("valid reply must decode"),
			(5, 100)
		);
	}

	#[test]
	fn invalid_volume_reply_checksum_is_rejected() {
		let reply = [0x6e, 0x88, 0x02, 0x00, 0x62, 0x00, 0x00, 0x64, 0x00, 0x05, 0x00];

		assert!(macos::parse_get_reply(0x62, &reply).is_err());
	}
}
