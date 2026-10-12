//! Terminal ownership: alt screen, raw mode, event parsing, byte painting.
//!
//! One opaque handle per taken terminal. `stop` restores everything and stays
//! restartable (the ^Z dance); `free` stops and drops. Painting is deliberately
//! dumb — Dart diffs, encodes, and hands over bytes — so layout can never
//! disagree with itself.

use std::io::Write;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use crossterm::event::{
    DisableBracketedPaste, DisableMouseCapture, EnableBracketedPaste, EnableMouseCapture, Event, KeyCode,
    KeyModifiers, MouseEventKind,
};
use crossterm::terminal::{disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen};
use crossterm::{cursor, event, execute, terminal};

use crate::{guard, live, lock, Handle, Msg};

/// One heard event, handed to the Dart listener. Replaces the blocking poll:
/// one way to read.
pub type EventFn = Option<unsafe extern "C" fn(ev: *const TkEvent)>;

/// A listener as stored: a plain function pointer, held across the spawn.
type Listener = unsafe extern "C" fn(ev: *const TkEvent);

/// Key codes past the Unicode range (mirrored in the Dart seam, lib/src/tui/native.dart).
const KEY_UP: i32 = 0x100001;
const KEY_DOWN: i32 = 0x100002;
const KEY_LEFT: i32 = 0x100003;
const KEY_RIGHT: i32 = 0x100004;
const KEY_HOME: i32 = 0x100005;
const KEY_END: i32 = 0x100006;
const KEY_PAGE_UP: i32 = 0x100007;
const KEY_PAGE_DOWN: i32 = 0x100008;
const KEY_INSERT: i32 = 0x100009;
const KEY_DELETE: i32 = 0x10000A;
const KEY_ENTER: i32 = 0x10000B;
const KEY_TAB: i32 = 0x10000C;
const KEY_BACKSPACE: i32 = 0x10000D;
const KEY_ESC: i32 = 0x10000E;
const KEY_F: i32 = 0x100010;

/// Modifier bits (mirrored in the Dart seam, lib/src/tui/native.dart).
const MOD_SHIFT: i32 = 1;
const MOD_CTRL: i32 = 2;
const MOD_ALT: i32 = 4;

/// The event a listener hears: kinds 1 key, 2 resize, 3 pointer, 4 paste,
/// 5 focus, 6 blur, 7 interrupt. For keys, `code` is the printable scalar or
/// a `KEY_*` constant and `mods` the modifier bits; for pointers, `code` is
/// the button, `mods` the key modifiers, `w` the pointer kind (0 press,
/// 1 release, 2 drag, 3 move, 4 scrollUp, 5 scrollDown); for resize, the new
/// width/height travel in `x`/`y`; paste bytes are a heap allocation in
/// `text_ptr`/`text_len`, freed with the event (`tk_tui_event_free`).
#[repr(C)]
pub struct TkEvent {
    kind: i32,
    code: i32,
    mods: i32,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    text_ptr: *mut u8,
    text_len: usize,
}

pub struct Term {
    mouse: bool,
    /// Told to the reader thread: set on stop and free, cleared on listen.
    stop: Arc<AtomicBool>,
    /// The reader thread while one runs.
    reader: Mutex<Option<std::thread::JoinHandle<()>>>,
    /// The listener to restart the reader with after a resume.
    event_fn: Mutex<Option<Listener>>,
}

fn enter(mouse: bool) -> Result<(), String> {
    enable_raw_mode().msg()?;
    let mut out = std::io::stdout();
    execute!(out, EnterAlternateScreen, EnableBracketedPaste).msg()?;
    if mouse {
        execute!(out, EnableMouseCapture).msg()?;
    }
    execute!(out, cursor::Hide).msg()?;
    Ok(())
}

fn leave(mouse: bool) {
    let mut out = std::io::stdout();
    if mouse {
        let _ = execute!(out, DisableMouseCapture);
    }
    let _ = execute!(out, DisableBracketedPaste, LeaveAlternateScreen, cursor::Show);
    let _ = disable_raw_mode();
}

/// Takes the terminal: alt screen, raw mode, bracketed paste, hidden cursor,
/// mouse capture when `mouse` is non-zero.
#[no_mangle]
pub unsafe extern "C" fn tk_tui_start(mouse: u8) -> Handle {
    match enter(mouse != 0) {
        Ok(()) => {
            Box::into_raw(
                Box::new(Term {
                    mouse: mouse != 0,
                    stop: Arc::new(AtomicBool::new(true)),
                    reader: Mutex::new(None),
                    event_fn: Mutex::new(None),
                }),
            ) as Handle
        }
        Err(message) => {
            tk_common::set_error(&message);
            std::ptr::null_mut()
        }
    }
}

/// Restores modes, leaves the alt screen and stops the reader; restartable via
/// `tk_tui_resume`.
#[no_mangle]
pub unsafe extern "C" fn tk_tui_stop(handle: Handle) {
    if handle.is_null() {
        return;
    }
    // SAFETY: null checked; the caller holds the handle.
    let term = unsafe { &*(handle as *mut Term) };
    stop_reader(term);
    leave(term.mouse);
}

/// Re-enters after `tk_tui_stop` (the ^Z dance) and restarts the reader with
/// the listener it had (none when `tk_tui_listen` never ran: then no thread).
#[no_mangle]
pub unsafe extern "C" fn tk_tui_resume(handle: Handle) -> i32 {
    guard(|| {
        let term = live::<Term>(handle)?;
        enter(term.mouse)?;
        if let Some(f) = *lock(&term.event_fn) {
            start_reader(term, f);
        }
        Ok(0)
    })
}

/// Restores, stops the reader and frees the handle. Best effort; never fails.
/// Joins the reader first (bounded by its poll), so no event arrives past this.
#[no_mangle]
pub unsafe extern "C" fn tk_tui_free(handle: Handle) {
    if handle.is_null() {
        return;
    }
    // SAFETY: null checked; frees exactly once (the caller detaches first).
    let term = unsafe { Box::from_raw(handle as *mut Term) };
    stop_reader(&term);
    leave(term.mouse);
}

/// Measures the terminal in columns × rows.
#[no_mangle]
pub unsafe extern "C" fn tk_tui_size(handle: Handle, out_cols: *mut u16, out_rows: *mut u16) -> i32 {
    guard(|| {
        let _term = live::<Term>(handle)?;
        let (cols, rows) = terminal::size().msg()?;
        if !out_cols.is_null() {
            *out_cols = cols;
        }
        if !out_rows.is_null() {
            *out_rows = rows;
        }
        Ok(0)
    })
}

/// Starts the reader thread for `handle`: every crossterm event is decoded and
/// handed to `f` as a heap event the listener frees (`tk_tui_event_free`).
/// Replaces the blocking `tk_tui_poll`: one way to read. Answers 0, or
/// negative without its callback. A second call replaces the first reader.
#[no_mangle]
pub unsafe extern "C" fn tk_tui_listen(handle: Handle, f: EventFn) -> i32 {
    guard(|| {
        let term = live::<Term>(handle)?;
        let f = f.ok_or("a listener needs its event callback")?;
        *lock(&term.event_fn) = Some(f);
        start_reader(term, f);
        Ok(0)
    })
}

/// Frees an event a listener heard (its paste bytes with it).
#[no_mangle]
pub unsafe extern "C" fn tk_tui_event_free(ev: *mut TkEvent) {
    if ev.is_null() {
        return;
    }
    let boxed = Box::from_raw(ev);
    if !boxed.text_ptr.is_null() && boxed.text_len > 0 {
        drop(Vec::from_raw_parts(boxed.text_ptr, boxed.text_len, boxed.text_len));
    }
}

/// (Re)starts the reader: the old thread, if any, is stopped and joined first
/// (bounded by its poll), so at most one reader hands events to Dart.
fn start_reader(term: &Term, f: Listener) {
    stop_reader(term);
    term.stop.store(false, Ordering::Relaxed);
    let stop = term.stop.clone();
    *lock(&term.reader) = Some(std::thread::spawn(move || read_loop(&stop, f)));
}

/// Tells the reader to end and waits for it (bounded by its poll).
fn stop_reader(term: &Term) {
    term.stop.store(true, Ordering::Relaxed);
    if let Some(w) = lock(&term.reader).take() {
        let _ = w.join();
    }
}

/// Reads crossterm events until told to stop or stdin goes away, handing each
/// decoded one to `f`. A failed decode is skipped; a dead stdin ends the loop.
fn read_loop(stop: &AtomicBool, f: Listener) {
    while !stop.load(Ordering::Relaxed) {
        match event::poll(Duration::from_millis(50)) {
            Ok(true) => match event::read() {
                Ok(ev) => match decode(ev) {
                    Ok(Some(tk)) => unsafe {
                        f(Box::into_raw(Box::new(tk)) as *const TkEvent);
                    },
                    _ => {}
                },
                Err(_) => break,
            },
            Ok(false) => {}
            Err(_) => break,
        }
    }
}

fn mods_of(mods: KeyModifiers) -> i32 {
    let mut bits = 0;
    if mods.contains(KeyModifiers::SHIFT) {
        bits |= MOD_SHIFT;
    }
    if mods.contains(KeyModifiers::CONTROL) {
        bits |= MOD_CTRL;
    }
    if mods.contains(KeyModifiers::ALT) {
        bits |= MOD_ALT;
    }
    bits
}

fn blank() -> TkEvent {
    TkEvent { kind: 0, code: 0, mods: 0, x: 0, y: 0, w: 0, h: 0, text_ptr: std::ptr::null_mut(), text_len: 0 }
}

/// A crossterm event as a `TkEvent`, or `None` for keys with no Dart noun
/// (media, lone modifiers): the poll loop skips those inside its budget.
fn decode(ev: Event) -> Result<Option<TkEvent>, String> {
    match ev {
        Event::Key(key) => {
            let mods = mods_of(key.modifiers);
            // ^C arrives as an event, never as a signal, while raw.
            if key.modifiers.contains(KeyModifiers::CONTROL) {
                if let KeyCode::Char(c) = key.code {
                    if c == 'c' || c == 'C' {
                        return Ok(Some(TkEvent { kind: 7, ..blank() }));
                    }
                }
            }
            let code = match key.code {
                KeyCode::Char(c) => c as i32,
                KeyCode::Enter => KEY_ENTER,
                KeyCode::Tab => KEY_TAB,
                KeyCode::Backspace => KEY_BACKSPACE,
                KeyCode::Delete => KEY_DELETE,
                KeyCode::Insert => KEY_INSERT,
                KeyCode::Home => KEY_HOME,
                KeyCode::End => KEY_END,
                KeyCode::PageUp => KEY_PAGE_UP,
                KeyCode::PageDown => KEY_PAGE_DOWN,
                KeyCode::Up => KEY_UP,
                KeyCode::Down => KEY_DOWN,
                KeyCode::Left => KEY_LEFT,
                KeyCode::Right => KEY_RIGHT,
                KeyCode::Esc => KEY_ESC,
                KeyCode::F(n) if (1..=24).contains(&n) => KEY_F + (n as i32 - 1),
                _ => return Ok(None),
            };
            Ok(Some(TkEvent { kind: 1, code, mods, ..blank() }))
        }
        Event::Resize(w, h) => Ok(Some(TkEvent { kind: 2, x: w as i32, y: h as i32, ..blank() })),
        Event::Mouse(mouse) => {
            let kind = match mouse.kind {
                MouseEventKind::Down(_) => 0,
                MouseEventKind::Up(_) => 1,
                MouseEventKind::Drag(_) => 2,
                MouseEventKind::Moved => 3,
                MouseEventKind::ScrollUp => 4,
                MouseEventKind::ScrollDown => 5,
                // Horizontal scroll has no Dart noun: skipped.
                _ => return Ok(None),
            };
            let button = match mouse.kind {
                MouseEventKind::Down(b) | MouseEventKind::Up(b) | MouseEventKind::Drag(b) => match b {
                    crossterm::event::MouseButton::Left => 0,
                    crossterm::event::MouseButton::Middle => 1,
                    crossterm::event::MouseButton::Right => 2,
                },
                _ => 0,
            };
            Ok(Some(TkEvent {
                kind: 3,
                code: button,
                mods: mods_of(mouse.modifiers),
                x: mouse.column as i32,
                y: mouse.row as i32,
                w: kind,
                ..blank()
            }))
        }
        Event::Paste(text) => {
            let bytes = text.into_bytes();
            let len = bytes.len();
            let mut boxed = bytes.into_boxed_slice();
            let (ptr, _) = (boxed.as_mut_ptr(), boxed.len());
            std::mem::forget(boxed);
            Ok(Some(TkEvent { kind: 4, text_ptr: ptr, text_len: len, ..blank() }))
        }
        Event::FocusGained => Ok(Some(TkEvent { kind: 5, ..blank() })),
        Event::FocusLost => Ok(Some(TkEvent { kind: 6, ..blank() })),
    }
}

/// Paints Dart-encoded bytes (positioned ANSI for the frame diff).
#[no_mangle]
pub unsafe extern "C" fn tk_tui_write(handle: Handle, bytes: *const u8, len: usize) -> i32 {
    guard(|| {
        live::<Term>(handle)?;
        let data = if bytes.is_null() || len == 0 { &[][..] } else { unsafe { std::slice::from_raw_parts(bytes, len) } };
        let mut out = std::io::stdout().lock();
        out.write_all(data).msg()?;
        out.flush().msg()?;
        Ok(0)
    })
}

/// Positions (`col`, `row` ≥ 0) or hides the hardware cursor.
#[no_mangle]
pub unsafe extern "C" fn tk_tui_cursor(handle: Handle, col: i32, row: i32) {
    if handle.is_null() {
        return;
    }
    let mut out = std::io::stdout();
    if col >= 0 && row >= 0 {
        let _ = execute!(out, cursor::Show, cursor::MoveTo(col as u16, row as u16));
    } else {
        let _ = execute!(out, cursor::Hide);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ctrl_c_decodes_to_interrupt() {
        let ev = decode(Event::Key(crossterm::event::KeyEvent::new(KeyCode::Char('c'), KeyModifiers::CONTROL))).unwrap();
        assert_eq!(ev.unwrap().kind, 7);
    }

    #[test]
    fn arrows_and_function_keys_map() {
        let up = decode(Event::Key(crossterm::event::KeyEvent::new(KeyCode::Up, KeyModifiers::NONE))).unwrap().unwrap();
        assert_eq!((up.kind, up.code), (1, KEY_UP));
        let f5 = decode(Event::Key(crossterm::event::KeyEvent::new(KeyCode::F(5), KeyModifiers::NONE))).unwrap().unwrap();
        assert_eq!(f5.code, KEY_F + 4);
        let plain = decode(Event::Key(crossterm::event::KeyEvent::new(KeyCode::Char('q'), KeyModifiers::NONE)))
            .unwrap()
            .unwrap();
        assert_eq!(plain.code, 'q' as i32);
    }

    #[test]
    fn media_keys_are_skipped() {
        let none = decode(Event::Key(crossterm::event::KeyEvent::new(KeyCode::Media(crossterm::event::MediaKeyCode::Play), KeyModifiers::NONE))).unwrap();
        assert!(none.is_none());
    }

    #[test]
    fn sgr_wheel_up_is_scroll_up() {
        // `\e[<64;11;21M`: button 64 is the wheel turning up.
        let up = decode(Event::Mouse(crossterm::event::MouseEvent {
            kind: MouseEventKind::ScrollUp,
            column: 10,
            row: 20,
            modifiers: KeyModifiers::NONE,
        }))
        .unwrap()
        .unwrap();
        assert_eq!((up.kind, up.w), (3, 4));
        let down = decode(Event::Mouse(crossterm::event::MouseEvent {
            kind: MouseEventKind::ScrollDown,
            column: 10,
            row: 20,
            modifiers: KeyModifiers::NONE,
        }))
        .unwrap()
        .unwrap();
        assert_eq!((down.kind, down.w), (3, 5));
    }
}
