//! C interface for the native display volume core.

use std::{
	any::Any,
	ffi::{CString, c_char},
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
/// `out_result` must be null or point to writable memory for one
/// [`DeskHelmVolumeResult`]. The caller must release returned strings with
/// [`deskhelm_volume_result_free`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn deskhelm_read_volume(out_result: *mut DeskHelmVolumeResult) -> i32 {
	if !prepare_output(out_result) {
		return STATUS_INVALID_ARGUMENT;
	}

	run_operation(out_result, crate::read_volume)
}

/// Sets the display volume and writes the confirmed value into `out_result`.
///
/// # Safety
///
/// `out_result` must be null or point to writable memory for one
/// [`DeskHelmVolumeResult`]. The caller must release returned strings with
/// [`deskhelm_volume_result_free`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn deskhelm_set_volume(
	level: i32,
	out_result: *mut DeskHelmVolumeResult,
) -> i32 {
	if !prepare_output(out_result) {
		return STATUS_INVALID_ARGUMENT;
	}

	run_boundary(out_result, || {
		if !(0..=100).contains(&level) {
			// SAFETY: `prepare_output` accepted this pointer and initialized its pointee.
			unsafe {
				(*out_result).error = owned_c_string(&format!(
					"Volume level {level} is outside the supported 0–100 range."
				));
			}

			return STATUS_INVALID_ARGUMENT;
		}

		complete_operation(out_result, || crate::set_volume(level as u8))
	})
}

/// Creates a verified display session and returns its initial volume reading.
///
/// # Safety
///
/// `out_session` must be null or point to writable storage for one session
/// pointer. `out_result` follows the [`deskhelm_read_volume`] contract. A
/// successful session must be released with [`deskhelm_session_free`]. The
/// caller must release any returned strings with
/// [`deskhelm_volume_result_free`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn deskhelm_session_create(
	out_session: *mut *mut DeskHelmSession,
	out_result: *mut DeskHelmVolumeResult,
) -> i32 {
	let session_output_ready = prepare_session_output(out_session);

	if !prepare_output(out_result) {
		return STATUS_INVALID_ARGUMENT;
	}

	run_boundary(out_result, || {
		if !session_output_ready {
			return invalid_argument(out_result, "DeskHelm received no session output storage.");
		}

		match VerifiedSession::create() {
			Ok((inner, reading)) => {
				let session = Box::new(DeskHelmSession { inner });

				write_reading(out_result, &reading);

				// SAFETY: `prepare_session_output` accepted and initialized this pointer.
				unsafe { ptr::write(out_session, Box::into_raw(session)) };

				STATUS_OK
			},
			Err(error) => runtime_error(out_result, &error),
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
	out_result: *mut DeskHelmVolumeResult,
) -> i32 {
	if !prepare_output(out_result) {
		return STATUS_INVALID_ARGUMENT;
	}

	run_boundary(out_result, || {
		if session.is_null() {
			return invalid_argument(out_result, "DeskHelm received no display session.");
		}

		// SAFETY: The caller guarantees exclusive access to a live DeskHelm session.
		let session = unsafe { &mut *session };

		complete_operation(out_result, || session.inner.read_volume())
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
	out_result: *mut DeskHelmVolumeResult,
) -> i32 {
	if !prepare_output(out_result) {
		return STATUS_INVALID_ARGUMENT;
	}

	run_boundary(out_result, || {
		if !(0..=100).contains(&level) {
			return invalid_argument(
				out_result,
				&format!("Volume level {level} is outside the supported 0–100 range."),
			);
		}
		if session.is_null() {
			return invalid_argument(out_result, "DeskHelm received no display session.");
		}

		// SAFETY: The caller guarantees exclusive access to a live DeskHelm session.
		let session = unsafe { &mut *session };

		complete_operation(out_result, || session.inner.set_volume(level as u8))
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
	out_result: *mut DeskHelmVolumeResult,
) -> i32 {
	if !prepare_output(out_result) {
		return STATUS_INVALID_ARGUMENT;
	}

	run_boundary(out_result, || {
		if !(0..=100).contains(&level) {
			return invalid_argument(
				out_result,
				&format!("Volume level {level} is outside the supported 0–100 range."),
			);
		}
		if session.is_null() {
			return invalid_argument(out_result, "DeskHelm received no display session.");
		}

		// SAFETY: The caller guarantees exclusive access to a live DeskHelm session.
		let session = unsafe { &mut *session };

		complete_operation(out_result, || session.inner.write_volume(level as u8))
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

fn prepare_output(out_result: *mut DeskHelmVolumeResult) -> bool {
	if out_result.is_null() {
		return false;
	}

	// SAFETY: The caller promises writable memory for one result.
	unsafe { ptr::write(out_result, DeskHelmVolumeResult::empty()) };

	true
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
	out_result: *mut DeskHelmVolumeResult,
	operation: impl FnOnce() -> Result<VolumeReading>,
) -> i32 {
	run_boundary(out_result, || complete_operation(out_result, operation))
}

fn complete_operation(
	out_result: *mut DeskHelmVolumeResult,
	operation: impl FnOnce() -> Result<VolumeReading>,
) -> i32 {
	match operation() {
		Ok(reading) => {
			write_reading(out_result, &reading);

			STATUS_OK
		},
		Err(error) => runtime_error(out_result, &error),
	}
}

fn write_reading(out_result: *mut DeskHelmVolumeResult, reading: &VolumeReading) {
	// SAFETY: The exported function prepared and validated this output pointer.
	unsafe {
		(*out_result).current = reading.current();
		(*out_result).maximum = reading.maximum();
		(*out_result).display = owned_c_string(reading.display());
	}
}

fn runtime_error(out_result: *mut DeskHelmVolumeResult, error: &Report) -> i32 {
	// SAFETY: The exported function prepared and validated this output pointer.
	unsafe {
		(*out_result).error = owned_c_string(&error_text(error));
	}

	STATUS_RUNTIME_ERROR
}

fn invalid_argument(out_result: *mut DeskHelmVolumeResult, message: &str) -> i32 {
	// SAFETY: The exported function prepared and validated this output pointer.
	unsafe {
		(*out_result).error = owned_c_string(message);
	}

	STATUS_INVALID_ARGUMENT
}

fn run_boundary(out_result: *mut DeskHelmVolumeResult, operation: impl FnOnce() -> i32) -> i32 {
	match panic::catch_unwind(AssertUnwindSafe(operation)) {
		Ok(status) => status,
		Err(payload) => {
			// SAFETY: The exported function prepared this output pointer before entering the
			// boundary. Any non-null string came from DeskHelm.
			unsafe {
				free_owned_strings(&mut *out_result);

				ptr::write(out_result, DeskHelmVolumeResult::empty());
			}

			let _ = panic::catch_unwind(AssertUnwindSafe(|| {
				// SAFETY: The result was reset immediately above and remains writable.
				unsafe {
					(*out_result).error = owned_c_string(&panic_text(payload.as_ref()));
				}
			}));

			STATUS_PANIC
		},
	}
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
	use std::{ffi::CStr, mem::MaybeUninit, ptr};

	use color_eyre::eyre::{self, WrapErr};

	use crate::{
		VolumeReading,
		ffi::{
			self, DeskHelmVolumeResult, STATUS_INVALID_ARGUMENT, STATUS_OK, STATUS_PANIC,
			STATUS_RUNTIME_ERROR,
		},
	};

	#[test]
	fn null_output_is_rejected() {
		// SAFETY: A null output is explicitly permitted and rejected by the ABI.
		let status = unsafe { ffi::deskhelm_read_volume(ptr::null_mut()) };

		assert_eq!(status, STATUS_INVALID_ARGUMENT);
	}

	#[test]
	fn session_create_rejects_null_session_output_without_device_access() {
		let mut result = MaybeUninit::<DeskHelmVolumeResult>::uninit();
		// SAFETY: The null session output is rejected before device access, and `result` is
		// writable.
		let status = unsafe { ffi::deskhelm_session_create(ptr::null_mut(), result.as_mut_ptr()) };
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
		let status = unsafe { ffi::deskhelm_session_create(session.as_mut_ptr(), ptr::null_mut()) };
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
			unsafe { ffi::deskhelm_session_read(ptr::null_mut(), read_result.as_mut_ptr()) };
		// SAFETY: DeskHelm initializes a non-null result before returning.
		let mut read_result = unsafe { read_result.assume_init() };

		assert_eq!(read_status, STATUS_INVALID_ARGUMENT);

		// SAFETY: DeskHelm initialized this result and owns its returned strings.
		unsafe { ffi::deskhelm_volume_result_free(&mut read_result) };

		let mut set_result = MaybeUninit::<DeskHelmVolumeResult>::uninit();
		// SAFETY: A null session is rejected, the level is valid, and `set_result` is writable.
		let set_status =
			unsafe { ffi::deskhelm_session_set(ptr::null_mut(), 42, set_result.as_mut_ptr()) };
		// SAFETY: DeskHelm initializes a non-null result before returning.
		let mut set_result = unsafe { set_result.assume_init() };

		assert_eq!(set_status, STATUS_INVALID_ARGUMENT);

		// SAFETY: DeskHelm initialized this result and owns its returned strings.
		unsafe { ffi::deskhelm_volume_result_free(&mut set_result) };

		let mut write_result = MaybeUninit::<DeskHelmVolumeResult>::uninit();
		// SAFETY: A null session is rejected, the level is valid, and `write_result` is writable.
		let write_status =
			unsafe { ffi::deskhelm_session_write(ptr::null_mut(), 42, write_result.as_mut_ptr()) };
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
			let status = unsafe { ffi::deskhelm_set_volume(level, result.as_mut_ptr()) };
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
				unsafe { ffi::deskhelm_session_write(ptr::null_mut(), level, result.as_mut_ptr()) };
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
		let status = unsafe { ffi::deskhelm_session_write(ptr::null_mut(), 42, ptr::null_mut()) };

		assert_eq!(status, STATUS_INVALID_ARGUMENT);
	}

	#[test]
	fn success_result_converts_and_frees_owned_strings() {
		let mut result = DeskHelmVolumeResult::empty();
		let status = ffi::run_operation(&mut result, || {
			Ok(VolumeReading::new("LG\0UltraGear".to_owned(), 42, 100))
		});

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
		let mut result = DeskHelmVolumeResult::empty();
		let status = ffi::run_operation(&mut result, || {
			let failed_read: color_eyre::Result<()> = Err(eyre::eyre!("DDC/CI unavailable"));

			failed_read.wrap_err("Could not read volume")?;

			Ok(VolumeReading::new(String::new(), 0, 0))
		});

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
		let mut result = DeskHelmVolumeResult::empty();
		let status = ffi::run_operation(&mut result, || panic!("test panic"));

		assert_eq!(status, STATUS_PANIC);

		// SAFETY: A caught panic returns a valid null-terminated error string.
		let error = unsafe { CStr::from_ptr(result.error) }.to_string_lossy();

		assert!(error.contains("test panic"));

		// SAFETY: DeskHelm initialized this result and owns its returned strings.
		unsafe { ffi::deskhelm_volume_result_free(&mut result) };
	}
}
