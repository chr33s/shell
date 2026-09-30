//! ripgrep_ios — cdylib wrapper for ripgrep, integrated with ios_system.
//!
//! Uses dup2() to redirect process FDs 0/1 to ios_system's thread-local
//! FDs for the duration of the rg command. This enables full pipe and file
//! redirection support without modifying ripgrep's internal I/O paths.
//!
//! FD 2 (stderr) is NOT redirected because dup2 is process-wide: redirecting
//! stderr would capture ALL app output (os.log, Swift Logger, etc.) from every
//! thread into the terminal. ripgrep error messages go to the system log
//! instead, which is an acceptable tradeoff.

use std::ffi::{c_char, c_int, CStr, OsString};
use std::os::unix::ffi::OsStringExt;

unsafe extern "C" {
    fn ios_stdin() -> *mut libc::FILE;
    fn ios_stdout() -> *mut libc::FILE;
}

#[unsafe(no_mangle)]
pub extern "C" fn rg_main(argc: c_int, argv: *const *const c_char) -> c_int {
    // Convert C argv to Rust OsStrings, skip argv[0] (command name).
    let args: Vec<OsString> = (1..argc)
        .map(|i| unsafe {
            let ptr = *argv.offset(i as isize);
            let bytes = CStr::from_ptr(ptr).to_bytes().to_vec();
            OsString::from_vec(bytes)
        })
        .collect();

    // Get ios_system's thread-local FDs for stdin/stdout only.
    // stderr is left alone to avoid capturing process-wide os.log output.
    let ios_in = unsafe { libc::fileno(ios_stdin()) };
    let ios_out = unsafe { libc::fileno(ios_stdout()) };

    // Save original FDs.
    let saved_in = unsafe { libc::dup(0) };
    let saved_out = unsafe { libc::dup(1) };

    // Redirect FD 0/1 to ios_system's FDs.
    unsafe {
        libc::dup2(ios_in, 0);
        libc::dup2(ios_out, 1);
    }

    // Run ripgrep.
    let exit_code = ripgrep_core::run_with_args(args);

    // Restore original FDs.
    unsafe {
        libc::dup2(saved_in, 0);
        libc::dup2(saved_out, 1);
        libc::close(saved_in);
        libc::close(saved_out);
    }

    exit_code
}
