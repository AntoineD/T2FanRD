//! Terminal output that doesn't get appended to the fan speed status line.

use std::{
    fmt,
    io::{IsTerminal, Write},
    sync::atomic::{AtomicBool, Ordering},
};

/// Whether a status line is on screen with no newline after it yet.
static STATUS_SHOWN: AtomicBool = AtomicBool::new(false);

/// Shows `args` as the status line, replacing the previous one.  Only on a
/// terminal: in a log it would be noise.
pub fn status(args: fmt::Arguments<'_>) {
    let mut stdout = std::io::stdout().lock();
    if stdout.is_terminal() {
        let _ = write!(stdout, "\x1b[2K\r{args}");
        let _ = stdout.flush();
        STATUS_SHOWN.store(true, Ordering::Relaxed);
    }
}

/// `println!`, after erasing the status line.  Use through `log!`.
#[allow(clippy::disallowed_macros)]
pub fn log(args: fmt::Arguments<'_>) {
    clear_status();
    println!("{args}");
}

/// `eprintln!`, after erasing the status line.  Use through `elog!`.
#[allow(clippy::disallowed_macros)]
pub fn elog(args: fmt::Arguments<'_>) {
    clear_status();
    eprintln!("{args}");
}

/// Erases the status line, if one is showing, so the next message starts on
/// a clean line.
fn clear_status() {
    if STATUS_SHOWN.swap(false, Ordering::Relaxed) {
        let mut stdout = std::io::stdout().lock();
        let _ = write!(stdout, "\x1b[2K\r");
        let _ = stdout.flush();
    }
}
