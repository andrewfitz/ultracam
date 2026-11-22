use crate::director::Director;
use crate::model::{StreamEvent, SwitcherConfig, SwitcherOutput};
use std::ffi::{CStr, CString};
use std::os::raw::c_char;

#[repr(C)]
pub struct AutoSwitcherHandle {
    director: Director,
}

fn output_json(outputs: Vec<SwitcherOutput>) -> *mut c_char {
    let json = match serde_json::to_string(&outputs) {
        Ok(json) => json,
        Err(error) => serde_json::to_string(&vec![SwitcherOutput::Error {
            message: format!("serialization failed: {error}"),
        }])
        .unwrap_or_else(|_| "[]".to_string()),
    };
    CString::new(json)
        .unwrap_or_else(|_| CString::new("[]").expect("static JSON is valid"))
        .into_raw()
}

fn error_json(message: impl Into<String>) -> *mut c_char {
    output_json(vec![SwitcherOutput::Error {
        message: message.into(),
    }])
}

/// Creates an engine from a JSON `SwitcherConfig`. A null or empty config uses
/// the package defaults. The returned pointer must be released with
/// `auto_switcher_destroy`.
///
/// # Safety
/// `config_json` must be null or point to a valid, NUL-terminated UTF-8 C
/// string for the duration of this call.
#[no_mangle]
pub unsafe extern "C" fn auto_switcher_create(
    config_json: *const c_char,
) -> *mut AutoSwitcherHandle {
    let config = if config_json.is_null() {
        SwitcherConfig::default()
    } else {
        let Ok(text) = CStr::from_ptr(config_json).to_str() else {
            return std::ptr::null_mut();
        };
        if text.trim().is_empty() {
            SwitcherConfig::default()
        } else {
            match serde_json::from_str(text) {
                Ok(config) => config,
                Err(_) => return std::ptr::null_mut(),
            }
        }
    };
    let Ok(director) = Director::new(config) else {
        return std::ptr::null_mut();
    };
    Box::into_raw(Box::new(AutoSwitcherHandle { director }))
}

/// Processes one JSON `StreamEvent` and returns a JSON array of outputs. The
/// caller owns the returned string and must release it with
/// `auto_switcher_free_string`.
///
/// # Safety
/// `handle` must be a pointer returned by `auto_switcher_create` that has not
/// been destroyed, and `event_json` must point to a valid, NUL-terminated C
/// string for the duration of this call. Calls using the same handle must be
/// serialized by the caller.
#[no_mangle]
pub unsafe extern "C" fn auto_switcher_process_json(
    handle: *mut AutoSwitcherHandle,
    event_json: *const c_char,
) -> *mut c_char {
    if handle.is_null() || event_json.is_null() {
        return error_json("null FFI argument");
    }
    let Ok(text) = CStr::from_ptr(event_json).to_str() else {
        return error_json("event is not UTF-8");
    };
    let event: StreamEvent = match serde_json::from_str(text) {
        Ok(event) => event,
        Err(error) => return error_json(format!("invalid stream event: {error}")),
    };
    let engine = &mut *handle;
    output_json(engine.director.process_event(event))
}

#[no_mangle]
/// # Safety
/// `value` must be null or a pointer previously returned by one of this
/// library's functions that returns an owned string, and it must be freed at
/// most once.
pub unsafe extern "C" fn auto_switcher_free_string(value: *mut c_char) {
    if !value.is_null() {
        drop(CString::from_raw(value));
    }
}

#[no_mangle]
/// # Safety
/// `handle` must be null or a pointer returned by `auto_switcher_create` that
/// has not already been destroyed.
pub unsafe extern "C" fn auto_switcher_destroy(handle: *mut AutoSwitcherHandle) {
    if !handle.is_null() {
        drop(Box::from_raw(handle));
    }
}

#[no_mangle]
pub extern "C" fn auto_switcher_version() -> *const c_char {
    // The string has static storage and must not be freed by the caller.
    c"0.1.0".as_ptr()
}

/// Stateless interval policy for hosts with an existing frame scheduler.
/// Origin is NaN before the first clock sample. -1 means hold, -2 means
/// the interval elapsed without a healthy alternative. Otherwise return the
/// selected index. The host retains its route/pending state until application.
///
/// # Safety
/// origin must point to writable storage and health must contain count bytes.
#[no_mangle]
pub unsafe extern "C" fn auto_switcher_interval(
    origin: *mut f64,
    now: f64,
    seconds: f64,
    held: bool,
    pending: bool,
    health: *const u8,
    count: usize,
    current: isize,
) -> isize {
    if origin.is_null() || health.is_null() || !now.is_finite() || now < 0.0 {
        return -1;
    }
    if held {
        *origin = now;
        return -1;
    }
    if pending {
        return -1;
    }
    if !(*origin).is_finite() || now < *origin {
        *origin = now;
        return -1;
    }
    if now - *origin < seconds.max(0.001) {
        return -1;
    }
    *origin = now;
    let health = std::slice::from_raw_parts(health, count);
    let first = if current < 0 { 0 } else { current as usize + 1 };
    for offset in 0..count {
        let index = (first + offset) % count;
        if index as isize != current && health[index] != 0 {
            return index as isize;
        }
    }
    -2
}
