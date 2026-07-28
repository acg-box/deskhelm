//! C interface for the native display volume core.

use std::{
	any::Any,
	ffi::{CString, c_char},
	mem::MaybeUninit,
	panic::{self, AssertUnwindSafe},
	ptr,
};

use color_eyre::Report;

use crate::{VolumeReading, display::VerifiedSession, prelude::Result};

const STATUS_OK: i32 = 0;
const STATUS_RUNTIME_ERROR: i32 = 1;
const STATUS_INVALID_ARGUMENT: i32 = 2;
const STATUS_PANIC: i32 = 3;

/// A volume result whose strings are owned by DeskHelm.
#[repr(C)]
pub struct DeskHelmVolumeResult {
	/// The current or accepted volume value.
	pub current: u16,
	/// The maximum volume reported by the display.
	pub maximum: u16,
	/// A null-terminated display label, or null when unavailable.
	pub display: *mut c_char,
	/// A null-terminated error description, or null on success.
	pub error: *mut c_char,
}
impl DeskHelmVolumeResult {
	const fn empty() -> Self {
		Self { current: 0, maximum: 0, display: ptr::null_mut(), error: ptr::null_mut() }
	}
}

/// An opaque, verified display session for the native app.
pub struct DeskHelmSession {
	inner: VerifiedSession,
}

/// Reads the current display volume into `out_result`.
///
/// # Safety
///
/// `out_result` must be null or point to aligned, dereferenceable storage for
/// one [`DeskHelmVolumeResult`]. The storage may be uninitialized, but it must
/// remain exclusively accessible for the full call: the caller must not read or
/// write it, and it must not overlap any other argument. The caller must release returned strings
/// with [`deskhelm_volume_result_free`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn deskhelm_read_volume(
	out_result: Option<&mut MaybeUninit<DeskHelmVolumeResult>>,
) -> i32 {
	let Some(out_result) = prepare_output(out_result) else {
		return STATUS_INVALID_ARGUMENT;
	};

	run_operation(out_result, crate::read_volume)
}

/// Sets the display volume and writes the confirmed value into `out_result`.
///
/// # Safety
///
/// `out_result` follows the [`deskhelm_read_volume`] contract.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn deskhelm_set_volume(
	level: i32,
	out_result: Option<&mut MaybeUninit<DeskHelmVolumeResult>>,
) -> i32 {
	let Some(out_result) = prepare_output(out_result) else {
		return STATUS_INVALID_ARGUMENT;
	};

	run_boundary(out_result, |result| {
		if !(0..=100).contains(&level) {
			result.error = owned_c_string(&format!(
				"Volume level {level} is outside the supported 0–100 range."
			));

			return STATUS_INVALID_ARGUMENT;
		}

		complete_operation(result, || crate::set_volume(level as u8))
	})
}

/// Creates a verified display session and returns its initial volume reading.
///
/// # Safety
///
/// `out_session` must be null or point to aligned, dereferenceable storage for
/// one session pointer. When non-null, it must remain exclusively accessible
/// for the full call and must not overlap `out_result`. `out_result` follows the
/// [`deskhelm_read_volume`] contract. A successful session must be released
/// with [`deskhelm_session_free`]. The caller must release any returned strings
/// with [`deskhelm_volume_result_free`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn deskhelm_session_create(
	out_session: *mut *mut DeskHelmSession,
	out_result: Option<&mut MaybeUninit<DeskHelmVolumeResult>>,
) -> i32 {
	let session_output_ready = prepare_session_output(out_session);
	let Some(out_result) = prepare_output(out_result) else {
		return STATUS_INVALID_ARGUMENT;
	};

	run_boundary(out_result, |result| {
		if !session_output_ready {
			return invalid_argument(result, "DeskHelm received no session output storage.");
		}

		match VerifiedSession::create() {
			Ok((inner, reading)) => {
				let session = Box::new(DeskHelmSession { inner });

				write_reading(result, &reading);

				// SAFETY: `prepare_session_output` accepted and initialized this pointer.
				unsafe { ptr::write(out_session, Box::into_raw(session)) };

				STATUS_OK
			},
			Err(error) => runtime_error(result, &error),
		}
	})
}

/// Reads volume through an existing verified display session.
///
/// # Safety
///
/// `session` must be null or a live pointer returned by
/// [`deskhelm_session_create`]. The caller must prevent concurrent access to
/// the session and must not free it while this function runs. `out_result`
/// follows the [`deskhelm_read_volume`] contract. After a non-success status,
/// the caller must release the session instead of reusing it.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn deskhelm_session_read(
	session: *mut DeskHelmSession,
	out_result: Option<&mut MaybeUninit<DeskHelmVolumeResult>>,
) -> i32 {
	let Some(out_result) = prepare_output(out_result) else {
		return STATUS_INVALID_ARGUMENT;
	};

	run_boundary(out_result, |result| {
		if session.is_null() {
			return invalid_argument(result, "DeskHelm received no display session.");
		}

		// SAFETY: The caller guarantees exclusive access to a live DeskHelm session.
		let session = unsafe { &mut *session };

		complete_operation(result, || session.inner.read_volume())
	})
}

/// Sets volume through an existing verified display session.
///
/// # Safety
///
/// `session` must satisfy the [`deskhelm_session_read`] contract. `out_result`
/// follows the [`deskhelm_read_volume`] contract. After a non-success status,
/// the caller must release the session instead of reusing it.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn deskhelm_session_set(
	session: *mut DeskHelmSession,
	level: i32,
	out_result: Option<&mut MaybeUninit<DeskHelmVolumeResult>>,
) -> i32 {
	let Some(out_result) = prepare_output(out_result) else {
		return STATUS_INVALID_ARGUMENT;
	};

	run_boundary(out_result, |result| {
		if !(0..=100).contains(&level) {
			return invalid_argument(
				result,
				&format!("Volume level {level} is outside the supported 0–100 range."),
			);
		}
		if session.is_null() {
			return invalid_argument(result, "DeskHelm received no display session.");
		}

		// SAFETY: The caller guarantees exclusive access to a live DeskHelm session.
		let session = unsafe { &mut *session };

		complete_operation(result, || session.inner.set_volume(level as u8))
	})
}

/// Writes volume through an existing verified display session without readback.
///
/// The successful result reports the accepted requested value. Call
/// [`deskhelm_session_set`] when exact display readback is required.
///
/// # Safety
///
/// `session` must satisfy the [`deskhelm_session_read`] contract. `out_result`
/// follows the [`deskhelm_read_volume`] contract. After a non-success status,
/// the caller must release the session instead of reusing it.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn deskhelm_session_write(
	session: *mut DeskHelmSession,
	level: i32,
	out_result: Option<&mut MaybeUninit<DeskHelmVolumeResult>>,
) -> i32 {
	let Some(out_result) = prepare_output(out_result) else {
		return STATUS_INVALID_ARGUMENT;
	};

	run_boundary(out_result, |result| {
		if !(0..=100).contains(&level) {
			return invalid_argument(
				result,
				&format!("Volume level {level} is outside the supported 0–100 range."),
			);
		}
		if session.is_null() {
			return invalid_argument(result, "DeskHelm received no display session.");
		}

		// SAFETY: The caller guarantees exclusive access to a live DeskHelm session.
		let session = unsafe { &mut *session };

		complete_operation(result, || session.inner.write_volume(level as u8))
	})
}

/// Releases an opaque display session.
///
/// # Safety
///
/// `session` must be null or a live pointer returned by
/// [`deskhelm_session_create`]. A non-null pointer must be freed exactly once,
/// after all operations on it have completed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn deskhelm_session_free(session: *mut DeskHelmSession) {
	if session.is_null() {
		return;
	}

	// SAFETY: The caller guarantees exclusive ownership of this live session pointer.
	drop(unsafe { Box::from_raw(session) });
}

/// Releases strings owned by a DeskHelm volume result and resets its fields.
///
/// # Safety
///
/// `result` must be null or point to a result initialized by this library. Each
/// initialized result must be freed at most once unless it is populated again by
/// a DeskHelm operation.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn deskhelm_volume_result_free(result: *mut DeskHelmVolumeResult) {
	if result.is_null() {
		return;
	}

	// SAFETY: The caller guarantees that `result` points to an initialized DeskHelm result.
	let result = unsafe { &mut *result };

	// SAFETY: The caller guarantees that both non-null string pointers came from DeskHelm.
	unsafe { free_owned_strings(result) };

	*result = DeskHelmVolumeResult::empty();
}

unsafe fn free_owned_strings(result: &mut DeskHelmVolumeResult) {
	if !result.display.is_null() {
		// SAFETY: DeskHelm created this pointer with `CString::into_raw`, and it is freed once.
		drop(unsafe { CString::from_raw(result.display) });
	}
	if !result.error.is_null() {
		// SAFETY: DeskHelm created this pointer with `CString::into_raw`, and it is freed once.
		drop(unsafe { CString::from_raw(result.error) });
	}
}

fn prepare_output(
	out_result: Option<&mut MaybeUninit<DeskHelmVolumeResult>>,
) -> Option<&mut MaybeUninit<DeskHelmVolumeResult>> {
	let out_result = out_result?;

	out_result.write(DeskHelmVolumeResult::empty());

	Some(out_result)
}

fn prepare_session_output(out_session: *mut *mut DeskHelmSession) -> bool {
	if out_session.is_null() {
		return false;
	}

	// SAFETY: The caller promises writable storage for one session pointer.
	unsafe { ptr::write(out_session, ptr::null_mut()) };

	true
}

fn run_operation(
	out_result: &mut MaybeUninit<DeskHelmVolumeResult>,
	operation: impl FnOnce() -> Result<VolumeReading>,
) -> i32 {
	run_boundary(out_result, |result| complete_operation(result, operation))
}

fn complete_operation(
	result: &mut DeskHelmVolumeResult,
	operation: impl FnOnce() -> Result<VolumeReading>,
) -> i32 {
	match operation() {
		Ok(reading) => {
			write_reading(result, &reading);

			STATUS_OK
		},
		Err(error) => runtime_error(result, &error),
	}
}

fn write_reading(result: &mut DeskHelmVolumeResult, reading: &VolumeReading) {
	result.current = reading.current();
	result.maximum = reading.maximum();
	result.display = owned_c_string(reading.display());
}

fn runtime_error(result: &mut DeskHelmVolumeResult, error: &Report) -> i32 {
	result.error = owned_c_string(&error_text(error));

	STATUS_RUNTIME_ERROR
}

fn invalid_argument(result: &mut DeskHelmVolumeResult, message: &str) -> i32 {
	result.error = owned_c_string(message);

	STATUS_INVALID_ARGUMENT
}

fn run_boundary(
	out_result: &mut MaybeUninit<DeskHelmVolumeResult>,
	operation: impl FnOnce(&mut DeskHelmVolumeResult) -> i32,
) -> i32 {
	let mut result = DeskHelmVolumeResult::empty();
	let status = match panic::catch_unwind(AssertUnwindSafe(|| operation(&mut result))) {
		Ok(status) => status,
		Err(payload) => {
			// SAFETY: Any non-null string in the private staging result came from DeskHelm.
			unsafe { free_owned_strings(&mut result) };

			result = DeskHelmVolumeResult::empty();

			let _ = panic::catch_unwind(AssertUnwindSafe(|| {
				result.error = owned_c_string(&panic_text(payload.as_ref()));
			}));

			STATUS_PANIC
		},
	};

	out_result.write(result);

	status
}

fn error_text(error: &Report) -> String {
	error.chain().map(ToString::to_string).collect::<Vec<_>>().join(": ")
}

fn panic_text(payload: &(dyn Any + Send)) -> String {
	if let Some(message) = payload.downcast_ref::<&str>() {
		return format!("DeskHelm core panicked: {message}");
	}

	if let Some(message) = payload.downcast_ref::<String>() {
		return format!("DeskHelm core panicked: {message}");
	}

	"DeskHelm core panicked with a non-text payload.".to_owned()
}

fn owned_c_string(text: &str) -> *mut c_char {
	let sanitized = text.replace('\0', "�");

	match CString::new(sanitized) {
		Ok(value) => value.into_raw(),
		Err(_) => c"DeskHelm could not encode result text.".to_owned().into_raw(),
	}
}

#[cfg(test)]
mod tests {
	use std::{
		ffi::CStr,
		mem::{self, MaybeUninit},
		ptr,
	};

	use color_eyre::eyre::{self, WrapErr};

	use crate::{
		VolumeReading,
		ffi::{
			self, DeskHelmSession, DeskHelmVolumeResult, STATUS_INVALID_ARGUMENT, STATUS_OK,
			STATUS_PANIC, STATUS_RUNTIME_ERROR,
		},
	};

	#[test]
	fn exported_abi_contract_is_stable() {
		assert_eq!(STATUS_OK, 0);
		assert_eq!(STATUS_RUNTIME_ERROR, 1);
		assert_eq!(STATUS_INVALID_ARGUMENT, 2);
		assert_eq!(STATUS_PANIC, 3);
		assert_eq!(mem::size_of::<DeskHelmVolumeResult>(), 24);
		assert_eq!(mem::align_of::<DeskHelmVolumeResult>(), 8);
		assert_eq!(mem::offset_of!(DeskHelmVolumeResult, current), 0);
		assert_eq!(mem::offset_of!(DeskHelmVolumeResult, maximum), 2);
		assert_eq!(mem::offset_of!(DeskHelmVolumeResult, display), 8);
		assert_eq!(mem::offset_of!(DeskHelmVolumeResult, error), 16);

		let _: for<'a> unsafe extern "C" fn(
			Option<&'a mut MaybeUninit<DeskHelmVolumeResult>>,
		) -> i32 = ffi::deskhelm_read_volume;
		let _: for<'a> unsafe extern "C" fn(
			i32,
			Option<&'a mut MaybeUninit<DeskHelmVolumeResult>>,
		) -> i32 = ffi::deskhelm_set_volume;
		let _: for<'a> unsafe extern "C" fn(
			*mut *mut DeskHelmSession,
			Option<&'a mut MaybeUninit<DeskHelmVolumeResult>>,
		) -> i32 = ffi::deskhelm_session_create;
		let _: for<'a> unsafe extern "C" fn(
			*mut DeskHelmSession,
			Option<&'a mut MaybeUninit<DeskHelmVolumeResult>>,
		) -> i32 = ffi::deskhelm_session_read;
		let _: for<'a> unsafe extern "C" fn(
			*mut DeskHelmSession,
			i32,
			Option<&'a mut MaybeUninit<DeskHelmVolumeResult>>,
		) -> i32 = ffi::deskhelm_session_set;
		let _: for<'a> unsafe extern "C" fn(
			*mut DeskHelmSession,
			i32,
			Option<&'a mut MaybeUninit<DeskHelmVolumeResult>>,
		) -> i32 = ffi::deskhelm_session_write;
		let _: unsafe extern "C" fn(*mut DeskHelmSession) = ffi::deskhelm_session_free;
		let _: unsafe extern "C" fn(*mut DeskHelmVolumeResult) = ffi::deskhelm_volume_result_free;
	}

	#[test]
	fn null_output_is_rejected() {
		// SAFETY: A null output is explicitly permitted and rejected by the ABI.
		let status = unsafe { ffi::deskhelm_read_volume(None) };

		assert_eq!(status, STATUS_INVALID_ARGUMENT);
	}

	#[test]
	fn session_create_rejects_null_session_output_without_device_access() {
		let mut result = MaybeUninit::<DeskHelmVolumeResult>::uninit();
		// SAFETY: The null session output is rejected before device access, and `result` is
		// writable.
		let status = unsafe { ffi::deskhelm_session_create(ptr::null_mut(), Some(&mut result)) };
		// SAFETY: DeskHelm initializes a non-null result before returning.
		let mut result = unsafe { result.assume_init() };

		assert_eq!(status, STATUS_INVALID_ARGUMENT);

		// SAFETY: The failed operation returns a valid null-terminated error string.
		let error = unsafe { CStr::from_ptr(result.error) }.to_string_lossy();

		assert!(error.contains("session output storage"));

		// SAFETY: DeskHelm initialized this result and owns its returned strings.
		unsafe { ffi::deskhelm_volume_result_free(&mut result) };
	}

	#[test]
	fn session_create_clears_output_when_result_storage_is_null() {
		let mut session = MaybeUninit::uninit();
		// SAFETY: `session` is writable, and a null result is explicitly rejected.
		let status = unsafe { ffi::deskhelm_session_create(session.as_mut_ptr(), None) };
		// SAFETY: DeskHelm initializes a non-null session output before returning.
		let session = unsafe { session.assume_init() };

		assert_eq!(status, STATUS_INVALID_ARGUMENT);
		assert!(session.is_null());
	}

	#[test]
	fn session_operations_reject_null_sessions_without_device_access() {
		let mut read_result = MaybeUninit::<DeskHelmVolumeResult>::uninit();
		// SAFETY: A null session is rejected, and `read_result` is writable.
		let read_status =
			unsafe { ffi::deskhelm_session_read(ptr::null_mut(), Some(&mut read_result)) };
		// SAFETY: DeskHelm initializes a non-null result before returning.
		let mut read_result = unsafe { read_result.assume_init() };

		assert_eq!(read_status, STATUS_INVALID_ARGUMENT);

		// SAFETY: DeskHelm initialized this result and owns its returned strings.
		unsafe { ffi::deskhelm_volume_result_free(&mut read_result) };

		let mut set_result = MaybeUninit::<DeskHelmVolumeResult>::uninit();
		// SAFETY: A null session is rejected, the level is valid, and `set_result` is writable.
		let set_status =
			unsafe { ffi::deskhelm_session_set(ptr::null_mut(), 42, Some(&mut set_result)) };
		// SAFETY: DeskHelm initializes a non-null result before returning.
		let mut set_result = unsafe { set_result.assume_init() };

		assert_eq!(set_status, STATUS_INVALID_ARGUMENT);

		// SAFETY: DeskHelm initialized this result and owns its returned strings.
		unsafe { ffi::deskhelm_volume_result_free(&mut set_result) };

		let mut write_result = MaybeUninit::<DeskHelmVolumeResult>::uninit();
		// SAFETY: A null session is rejected, the level is valid, and `write_result` is writable.
		let write_status =
			unsafe { ffi::deskhelm_session_write(ptr::null_mut(), 42, Some(&mut write_result)) };
		// SAFETY: DeskHelm initializes a non-null result before returning.
		let mut write_result = unsafe { write_result.assume_init() };

		assert_eq!(write_status, STATUS_INVALID_ARGUMENT);
		assert!(write_result.display.is_null());
		assert!(!write_result.error.is_null());

		// SAFETY: DeskHelm initialized this result and owns its returned strings.
		unsafe { ffi::deskhelm_volume_result_free(&mut write_result) };

		assert!(write_result.display.is_null());
		assert!(write_result.error.is_null());
	}

	#[test]
	fn freeing_a_null_session_is_a_no_op() {
		// SAFETY: A null session is explicitly permitted.
		unsafe { ffi::deskhelm_session_free(ptr::null_mut()) };
	}

	#[test]
	fn invalid_levels_are_rejected_without_device_access() {
		for level in [-1, 101] {
			let mut result = MaybeUninit::<DeskHelmVolumeResult>::uninit();
			// SAFETY: `result` provides writable memory for the output.
			let status = unsafe { ffi::deskhelm_set_volume(level, Some(&mut result)) };
			// SAFETY: DeskHelm initializes the output before returning for a non-null pointer.
			let mut result = unsafe { result.assume_init() };

			assert_eq!(status, STATUS_INVALID_ARGUMENT);
			assert!(result.display.is_null());
			assert!(!result.error.is_null());

			// SAFETY: DeskHelm initialized this result and owns its returned strings.
			unsafe { ffi::deskhelm_volume_result_free(&mut result) };
		}
	}

	#[test]
	fn session_write_rejects_invalid_levels_before_session_access() {
		for level in [-1, 101] {
			let mut result = MaybeUninit::<DeskHelmVolumeResult>::uninit();
			// SAFETY: The invalid level is rejected before the null session can be accessed, and
			// `result` is writable.
			let status =
				unsafe { ffi::deskhelm_session_write(ptr::null_mut(), level, Some(&mut result)) };
			// SAFETY: DeskHelm initializes a non-null result before returning.
			let mut result = unsafe { result.assume_init() };

			assert_eq!(status, STATUS_INVALID_ARGUMENT);
			assert!(result.display.is_null());

			// SAFETY: A failed operation returns a valid null-terminated error string.
			let error = unsafe { CStr::from_ptr(result.error) }.to_string_lossy();

			assert!(error.contains("outside the supported 0–100 range"));

			// SAFETY: DeskHelm initialized this result and owns its returned strings.
			unsafe { ffi::deskhelm_volume_result_free(&mut result) };

			assert!(result.error.is_null());
		}
	}

	#[test]
	fn session_write_rejects_null_output_without_session_access() {
		// SAFETY: A null output is explicitly permitted and rejected before session access.
		let status = unsafe { ffi::deskhelm_session_write(ptr::null_mut(), 42, None) };

		assert_eq!(status, STATUS_INVALID_ARGUMENT);
	}

	#[test]
	fn success_result_converts_and_frees_owned_strings() {
		let mut output = MaybeUninit::<DeskHelmVolumeResult>::uninit();
		let status = ffi::run_operation(&mut output, || {
			Ok(VolumeReading::new("LG\0UltraGear".to_owned(), 42, 100))
		});
		// SAFETY: The boundary initializes its output before returning.
		let mut result = unsafe { output.assume_init() };

		assert_eq!(status, STATUS_OK);
		assert_eq!(result.current, 42);
		assert_eq!(result.maximum, 100);

		// SAFETY: A successful operation returns a valid null-terminated display string.
		let display = unsafe { CStr::from_ptr(result.display) }.to_string_lossy();

		assert_eq!(display, "LG�UltraGear");

		// SAFETY: DeskHelm initialized this result and owns its returned strings.
		unsafe { ffi::deskhelm_volume_result_free(&mut result) };

		assert_eq!(result.current, 0);
		assert_eq!(result.maximum, 0);
		assert!(result.display.is_null());
		assert!(result.error.is_null());
	}

	#[test]
	fn runtime_error_converts_to_an_owned_error_string() {
		let mut output = MaybeUninit::<DeskHelmVolumeResult>::uninit();
		let status = ffi::run_operation(&mut output, || {
			let failed_read: color_eyre::Result<()> = Err(eyre::eyre!("DDC/CI unavailable"));

			failed_read.wrap_err("Could not read volume")?;

			Ok(VolumeReading::new(String::new(), 0, 0))
		});
		// SAFETY: The boundary initializes its output before returning.
		let mut result = unsafe { output.assume_init() };

		assert_eq!(status, STATUS_RUNTIME_ERROR);

		// SAFETY: A failed operation returns a valid null-terminated error string.
		let error = unsafe { CStr::from_ptr(result.error) }.to_string_lossy();

		assert!(error.contains("Could not read volume"));
		assert!(error.contains("DDC/CI unavailable"));

		// SAFETY: DeskHelm initialized this result and owns its returned strings.
		unsafe { ffi::deskhelm_volume_result_free(&mut result) };
	}

	#[test]
	fn panics_do_not_cross_the_ffi_boundary() {
		let mut output = MaybeUninit::<DeskHelmVolumeResult>::uninit();
		let status = ffi::run_operation(&mut output, || panic!("test panic"));
		// SAFETY: The boundary initializes its output after catching the panic.
		let mut result = unsafe { output.assume_init() };

		assert_eq!(status, STATUS_PANIC);

		// SAFETY: A caught panic returns a valid null-terminated error string.
		let error = unsafe { CStr::from_ptr(result.error) }.to_string_lossy();

		assert!(error.contains("test panic"));

		// SAFETY: DeskHelm initialized this result and owns its returned strings.
		unsafe { ffi::deskhelm_volume_result_free(&mut result) };
	}

	#[test]
	fn panic_after_partial_result_resets_the_staged_output() {
		let mut output = MaybeUninit::<DeskHelmVolumeResult>::uninit();
		let status = ffi::run_boundary(&mut output, |staged| {
			staged.current = 42;
			staged.maximum = 100;
			staged.display = ffi::owned_c_string("LG UltraGear");

			panic!("panic after staging a result");
		});
		// SAFETY: The boundary initializes its output after catching the panic.
		let mut result = unsafe { output.assume_init() };

		assert_eq!(status, STATUS_PANIC);
		assert_eq!(result.current, 0);
		assert_eq!(result.maximum, 0);
		assert!(result.display.is_null());
		assert!(!result.error.is_null());

		// SAFETY: A caught panic returns a valid null-terminated error string.
		let error = unsafe { CStr::from_ptr(result.error) }.to_string_lossy();

		assert!(error.contains("panic after staging a result"));

		// SAFETY: DeskHelm initialized this result and owns its returned strings.
		unsafe { ffi::deskhelm_volume_result_free(&mut result) };
	}
}
