//! CDP over a blocking websocket: one short-lived connection per call.
//!
//! Each page handle only carries its target's websocket URL, target id and the
//! browser endpoint; every command below connects, runs its request/response (or
//! event wait) with a deadline and the caller's stop byte, then drops the socket.
//! No pump thread, no shared id map: localhost connects cost ~1 ms, and nothing is
//! shared between concurrent calls on different pages.

use std::time::{Duration, Instant};

use crate::chrome::http;
use crate::{give, guard, live, stopped, text, Handle, Msg};

/// A tab: everything a command needs to reach it.
pub struct Page {
    ws_url: String,
    target_id: String,
    endpoint: String,
}

/// Opens a tab at `url` and answers its handle once the load event fires
/// (`timeout_ms`, default 30 s). Subscribes before navigating, so a fast load
/// cannot slip through.
#[no_mangle]
pub unsafe extern "C" fn tk_cdp_open(
    browser: Handle,
    url: *const u8,
    urllen: usize,
    timeout_ms: u64,
    stop: *const u8,
    out_page: *mut Handle,
) -> i32 {
    guard(|| {
        let _watch = tk_common::watch(stop);
        let endpoint = super::chrome::endpoint_of(browser)?;
        let url = text(url, urllen)?.to_string();
        let page = open(&endpoint, &url, capped_timeout(timeout_ms))?;
        if !out_page.is_null() {
            *out_page = Box::into_raw(Box::new(page)) as Handle;
        }
        Ok(0)
    })
}

/// Navigates the tab at `page` to `url` and waits for the load event
/// (`timeout_ms`, default 30 s).
#[no_mangle]
pub unsafe extern "C" fn tk_cdp_navigate(
    page: Handle,
    url: *const u8,
    urllen: usize,
    timeout_ms: u64,
    stop: *const u8,
) -> i32 {
    guard(|| {
        let _watch = tk_common::watch(stop);
        let page = live::<Page>(page)?;
        let url = text(url, urllen)?.to_string();
        let mut session = Session::connect(&page.ws_url)?;
        session.send("Page.enable", serde_json::json!({}))?;
        stealth(&mut session)?;
        session.send("Page.navigate", serde_json::json!({ "url": url }))?;
        session.wait_event("Page.loadEventFired", capped_timeout(timeout_ms))?;
        Ok(0)
    })
}

/// Evaluates `expr` and hands its JSON value back (`give()`); a JS exception is
/// an error naming what the page said.
#[no_mangle]
pub unsafe extern "C" fn tk_cdp_eval(
    page: Handle,
    expr: *const u8,
    exprlen: usize,
    out: *mut *mut u8,
    outlen: *mut usize,
) -> i32 {
    guard(|| {
        let page = live::<Page>(page)?;
        let expr = text(expr, exprlen)?.to_string();
        let value = eval(&page.ws_url, &expr, deadline_secs(30))?;
        Ok(give(value.to_string().into_bytes(), out, outlen))
    })
}

/// Waits until `selector` matches (polling `querySelector` every 100 ms) or
/// `timeout_ms` passes; a miss is an error naming the selector.
#[no_mangle]
pub unsafe extern "C" fn tk_cdp_wait(
    page: Handle,
    sel: *const u8,
    sellen: usize,
    timeout_ms: u64,
    stop: *const u8,
) -> i32 {
    guard(|| {
        let _watch = tk_common::watch(stop);
        let page = live::<Page>(page)?;
        let sel = text(sel, sellen)?.to_string();
        let script = format!("!!document.querySelector({})", json_string(&sel));
        let start = Instant::now();
        let timeout = Duration::from_millis(timeout_ms);
        loop {
            stopped()?;
            if start.elapsed() >= timeout {
                return Err(format!("Timed out waiting for {}", sel));
            }
            match eval(&page.ws_url, &script, deadline_secs(30))? {
                serde_json::Value::Bool(true) => return Ok(0),
                _ => std::thread::sleep(Duration::from_millis(100)),
            }
        }
    })
}

/// Clicks the first element matching `sel` with real mouse events at its
/// center (scrolled into view first). A missing element is an error.
#[no_mangle]
pub unsafe extern "C" fn tk_cdp_click(page: Handle, sel: *const u8, sellen: usize) -> i32 {
    guard(|| {
        let page = live::<Page>(page)?;
        let sel = text(sel, sellen)?.to_string();
        let script = format!(
            "(() => {{ const el = document.querySelector({}); if (!el) return null; \
             el.scrollIntoView({{block: 'center', inline: 'center'}}); \
             const r = el.getBoundingClientRect(); \
             return {{x: r.x + r.width / 2, y: r.y + r.height / 2}}; }})()",
            json_string(&sel)
        );
        let at = eval(&page.ws_url, &script, deadline_secs(30))?;
        let (x, y) = match &at {
            serde_json::Value::Object(map) => (map.get("x").and_then(|v| v.as_f64()), map.get("y").and_then(|v| v.as_f64())),
            _ => (None, None),
        };
        let (x, y) = match (x, y) {
            (Some(x), Some(y)) => (x, y),
            _ => return Err(format!("no such element: {}", sel)),
        };
        let mut session = Session::connect(&page.ws_url)?;
        for kind in ["mousePressed", "mouseReleased"] {
            session.send(
                "Input.dispatchMouseEvent",
                serde_json::json!({ "type": kind, "x": x, "y": y, "button": "left", "clickCount": 1 }),
            )?;
        }
        Ok(0)
    })
}

/// Focuses the first match of `sel` and inserts `text` as typed input (trusted
/// `input` events, so framework hooks fire). A missing element is an error.
#[no_mangle]
pub unsafe extern "C" fn tk_cdp_type(
    page: Handle,
    sel: *const u8,
    sellen: usize,
    text_ptr: *const u8,
    textlen: usize,
) -> i32 {
    guard(|| {
        let page = live::<Page>(page)?;
        let sel = text(sel, sellen)?.to_string();
        let script = format!(
            "(() => {{ const el = document.querySelector({}); if (!el) return false; el.focus(); return true; }})()",
            json_string(&sel)
        );
        match eval(&page.ws_url, &script, deadline_secs(30))? {
            serde_json::Value::Bool(true) => {}
            _ => return Err(format!("no such element: {}", sel)),
        }
        let inserted = text(text_ptr, textlen)?.to_string();
        if !inserted.is_empty() {
            let mut session = Session::connect(&page.ws_url)?;
            session.send("Input.insertText", serde_json::json!({ "text": inserted }))?;
        }
        Ok(0)
    })
}

/// Captures a PNG screenshot (`full` captures past the viewport) and hands the
/// bytes back (`give()`).
#[no_mangle]
pub unsafe extern "C" fn tk_cdp_shot(
    page: Handle,
    full: u8,
    stop: *const u8,
    out: *mut *mut u8,
    outlen: *mut usize,
) -> i32 {
    guard(|| {
        let _watch = tk_common::watch(stop);
        let page = live::<Page>(page)?;
        let mut session = Session::connect(&page.ws_url)?;
        let mut params = serde_json::json!({ "format": "png" });
        if full != 0 {
            params["captureBeyondViewport"] = serde_json::json!(true);
        }
        let got = session.send("Page.captureScreenshot", params)?;
        let data = got.get("data").and_then(|v| v.as_str()).ok_or("screenshot answered without data".to_string())?;
        let png = decode_b64(data)?;
        Ok(give(png, out, outlen))
    })
}

/// Prints the page to PDF (`landscape` when non-zero) and hands the bytes back
/// (`give()`). Headless only: headful Chrome refuses to print.
#[no_mangle]
pub unsafe extern "C" fn tk_cdp_pdf(
    page: Handle,
    landscape: u8,
    out: *mut *mut u8,
    outlen: *mut usize,
) -> i32 {
    guard(|| {
        let page = live::<Page>(page)?;
        let mut session = Session::connect(&page.ws_url)?;
        let got = session.send(
            "Page.printToPDF",
            serde_json::json!({ "landscape": landscape != 0, "printBackground": true }),
        )?;
        let data = got.get("data").and_then(|v| v.as_str()).ok_or("printToPDF answered without data".to_string())?;
        let pdf = decode_b64(data)?;
        Ok(give(pdf, out, outlen))
    })
}

/// Sends a raw CDP command (`params` is a JSON object, empty for none) and hands
/// the result object back (`give()`): the escape hatch under the verbs above.
#[no_mangle]
pub unsafe extern "C" fn tk_cdp_send(
    page: Handle,
    method: *const u8,
    methodlen: usize,
    params: *const u8,
    paramslen: usize,
    out: *mut *mut u8,
    outlen: *mut usize,
) -> i32 {
    guard(|| {
        let page = live::<Page>(page)?;
        let method = text(method, methodlen)?.to_string();
        let raw = text(params, paramslen)?;
        let params = if raw.is_empty() { serde_json::json!({}) } else { serde_json::from_str(raw).msg()? };
        let mut session = Session::connect(&page.ws_url)?;
        let got = session.send(&method, params)?;
        Ok(give(got.to_string().into_bytes(), out, outlen))
    })
}

/// Wraps an existing target (from `/json/list`) in a page handle: no tab is
/// opened, nothing navigates.
#[no_mangle]
pub unsafe extern "C" fn tk_cdp_attach_page(
    ws_url: *const u8,
    wslen: usize,
    target_id: *const u8,
    idlen: usize,
    endpoint: *const u8,
    endpointlen: usize,
) -> Handle {
    let page = (|| {
        Ok::<Page, String>(Page {
            ws_url: text(ws_url, wslen)?.to_string(),
            target_id: text(target_id, idlen)?.to_string(),
            endpoint: text(endpoint, endpointlen)?.to_string(),
        })
    })();
    match page {
        Ok(page) => Box::into_raw(Box::new(page)) as Handle,
        Err(message) => {
            tk_common::set_error(&message);
            std::ptr::null_mut()
        }
    }
}

/// Closes the tab server-side and frees the handle.
#[no_mangle]
pub unsafe extern "C" fn tk_cdp_close_page(page: Handle) -> i32 {
    guard(|| {
        let page = live::<Page>(page)?;
        let owned = unsafe { Box::from_raw(page as *mut Page) };
        // Best effort: the tab may already be gone with a dead browser.
        let path = format!("/json/close/{}", owned.target_id);
        let _ = http("PUT", &owned.endpoint, &path);
        Ok(0)
    })
}

/// Best-effort release for the GC finalizer: closes the tab, never fails.
#[no_mangle]
pub unsafe extern "C" fn tk_cdp_release_page(page: Handle) {
    if page.is_null() {
        return;
    }
    let owned = unsafe { Box::from_raw(page as *mut Page) };
    let path = format!("/json/close/{}", owned.target_id);
    let _ = http("PUT", &owned.endpoint, &path);
}

fn open(endpoint: &str, url: &str, timeout: Instant) -> Result<Page, String> {
    let (code, body) = http("PUT", endpoint, "/json/new?about:blank")?;
    if code != 200 {
        return Err(format!("could not open a new page ({})", code));
    }
    let info: serde_json::Value = serde_json::from_slice(&body).msg()?;
    let ws_url = info.get("webSocketDebuggerUrl").and_then(|v| v.as_str()).ok_or("new page answered without a websocket URL".to_string())?;
    let target_id = info.get("id").and_then(|v| v.as_str()).unwrap_or("").to_string();
    let page = Page { ws_url: ws_url.to_string(), target_id, endpoint: endpoint.to_string() };
    let mut session = Session::connect(&page.ws_url)?;
    session.send("Page.enable", serde_json::json!({}))?;
    stealth(&mut session)?;
    session.send("Page.navigate", serde_json::json!({ "url": url }))?;
    session.wait_event("Page.loadEventFired", timeout)?;
    Ok(page)
}

/// What `--remote-debugging-port` leaves visible to a page's scripts, hidden before the
/// page's first line runs in every document (bot checks such as DDoS-Guard look for these).
const STEALTH: &str = r#"
Object.defineProperty(navigator, 'webdriver', {get: () => undefined});
if (!window.chrome) window.chrome = {runtime: {}, loadTimes: () => {}, csi: () => {}};
if (navigator.plugins && navigator.plugins.length === 0) {
  Object.defineProperty(navigator, 'plugins', {get: () => [1, 2, 3, 4, 5]});
}
if (navigator.languages && navigator.languages.length === 0) {
  Object.defineProperty(navigator, 'languages', {get: () => ['en-US', 'en']});
}
const query = window.navigator.permissions && window.navigator.permissions.query;
if (query) {
  window.navigator.permissions.query = (p) =>
    p && p.name === 'notifications'
      ? Promise.resolve({state: Notification.permission})
      : query.call(window.navigator.permissions, p);
}
"#;

/// Hides automation for the navigation that follows on `session`: Chrome's own user agent
/// without `HeadlessChrome`, and [STEALTH] on every new document. Both are session-scoped
/// in CDP (dropped when the socket closes), so they go on the session that navigates.
fn stealth(session: &mut Session) -> Result<(), String> {
    if let Ok(version) = session.send("Browser.getVersion", serde_json::json!({})) {
        if let Some(agent) = version.get("userAgent").and_then(|a| a.as_str()) {
            let agent = agent.replacen("HeadlessChrome", "Chrome", 1);
            // An older Chrome without the override still navigates: the agent stays as it is.
            let _ = session.send("Emulation.setUserAgentOverride", serde_json::json!({ "userAgent": agent }));
        }
    }
    session.send("Page.addScriptToEvaluateOnNewDocument", serde_json::json!({ "source": STEALTH }))?;
    Ok(())
}

fn eval(ws_url: &str, expr: &str, deadline: Instant) -> Result<serde_json::Value, String> {
    let mut session = Session::connect(ws_url)?;
    let got = session.send(
        "Runtime.evaluate",
        serde_json::json!({ "expression": expr, "returnByValue": true, "awaitPromise": true }),
    )?;
    let _ = deadline;
    if let Some(details) = got.get("exceptionDetails") {
        return Err(format!("evaluation failed: {}", details));
    }
    Ok(got.get("result").and_then(|r| r.get("value")).cloned().unwrap_or(serde_json::Value::Null))
}

fn deadline_secs(secs: u64) -> Instant {
    Instant::now() + Duration::from_secs(secs)
}

/// A caller timeout in ms, defaulting to 30 s; absurd values are capped at an
/// hour rather than overflowing the deadline.
fn capped_timeout(timeout_ms: u64) -> Instant {
    let ms = if timeout_ms == 0 { 30_000 } else { timeout_ms.min(3_600_000) };
    Instant::now() + Duration::from_millis(ms)
}

fn json_string(text: &str) -> String {
    serde_json::Value::String(text.to_string()).to_string()
}

fn decode_b64(data: &str) -> Result<Vec<u8>, String> {
    use base64::Engine;
    base64::engine::general_purpose::STANDARD.decode(data.trim()).msg()
}

/// One websocket conversation: sends carry incrementing ids, reads route by id;
/// events nobody is holding for wait in the buffer (a fast load fires between
/// the navigate reply and the wait that follows it).
struct Session {
    ws: tungstenite::WebSocket<tungstenite::stream::MaybeTlsStream<std::net::TcpStream>>,
    next_id: u32,
    events: Vec<serde_json::Value>,
}

impl Session {
    fn connect(url: &str) -> Result<Self, String> {
        let (ws, _) = tungstenite::connect(url).map_err(|e| e.to_string())?;
        let mut session = Session { ws, next_id: 0, events: Vec::new() };
        // Short reads: every loop turn re-checks the deadline and the stop byte.
        match session.ws.get_mut() {
            tungstenite::stream::MaybeTlsStream::Plain(stream) => stream.set_read_timeout(Some(Duration::from_millis(500))).msg()?,
            _ => return Err("unexpected websocket transport".to_string()),
        }
        Ok(session)
    }

    fn send(&mut self, method: &str, params: serde_json::Value) -> Result<serde_json::Value, String> {
        self.next_id += 1;
        let id = self.next_id;
        let text = serde_json::json!({ "id": id, "method": method, "params": params }).to_string();
        self.ws.send(tungstenite::Message::Text(text.into())).map_err(|e| e.to_string())?;
        self.wait_reply(id, Instant::now() + Duration::from_secs(30))
    }

    fn wait_reply(&mut self, id: u32, deadline: Instant) -> Result<serde_json::Value, String> {
        loop {
            stopped()?;
            if Instant::now() >= deadline {
                return Err("DevTools command timed out".to_string());
            }
            match self.ws.read() {
                Ok(tungstenite::Message::Text(text)) => {
                    let msg: serde_json::Value = serde_json::from_str(text.as_str()).msg()?;
                    if msg.get("id").and_then(|v| v.as_u64()) == Some(id as u64) {
                        if let Some(error) = msg.get("error") {
                            return Err(format!("CDP error: {}", error));
                        }
                        return Ok(msg.get("result").cloned().unwrap_or(serde_json::Value::Null));
                    }
                    // An event for a later waiter: buffered, not dropped.
                    if msg.get("method").and_then(|v| v.as_str()).is_some() {
                        self.events.push(msg);
                    }
                }
                Ok(_) => {}
                Err(tungstenite::Error::Io(e)) if e.kind() == std::io::ErrorKind::TimedOut || e.kind() == std::io::ErrorKind::WouldBlock => {}
                Err(tungstenite::Error::ConnectionClosed) | Err(tungstenite::Error::AlreadyClosed) => {
                    return Err("DevTools websocket closed".to_string())
                }
                Err(e) => return Err(e.to_string()),
            }
        }
    }

    fn wait_event(&mut self, method: &str, deadline: Instant) -> Result<(), String> {
        if self.events.iter().any(|e| e.get("method").and_then(|v| v.as_str()) == Some(method)) {
            return Ok(());
        }
        loop {
            stopped()?;
            if Instant::now() >= deadline {
                return Err(format!("timed out waiting for {}", method));
            }
            match self.ws.read() {
                Ok(tungstenite::Message::Text(text)) => {
                    let msg: serde_json::Value = serde_json::from_str(text.as_str()).msg()?;
                    if msg.get("method").and_then(|v| v.as_str()) == Some(method) {
                        return Ok(());
                    }
                    if msg.get("method").and_then(|v| v.as_str()).is_some() {
                        self.events.push(msg);
                    }
                }
                Ok(_) => {}
                Err(tungstenite::Error::Io(e)) if e.kind() == std::io::ErrorKind::TimedOut || e.kind() == std::io::ErrorKind::WouldBlock => {}
                Err(tungstenite::Error::ConnectionClosed) | Err(tungstenite::Error::AlreadyClosed) => {
                    return Err("DevTools websocket closed".to_string())
                }
                Err(e) => return Err(e.to_string()),
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn selector_text_is_json_quoted() {
        assert_eq!(json_string("#a'b\"c"), "\"#a'b\\\"c\"");
    }

    #[test]
    fn missing_id_is_not_a_match() {
        let msg: serde_json::Value = serde_json::from_str(r#"{"method":"Page.loadEventFired"}"#).unwrap();
        assert_ne!(msg.get("id").and_then(|v| v.as_u64()), Some(1));
    }
}
