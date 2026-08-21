//! Pure popover-clamping helper shared by Linux and Windows
//! (`platform/mod.rs` gates this module to `#[cfg(any(target_os = "linux",
//! target_os = "windows"))]` — macOS positions the popover relative to the
//! menu bar via `tauri_plugin_positioner::Position::TrayBottomCenter`
//! instead, so it never needs this at all).
//!
//! [`clamp_to_work_area`] is the pure arithmetic, extracted unchanged from
//! the Linux `position_popover` body (spec-11 Slice B) so it can be unit
//! tested with injected geometry instead of a real window/monitor.
//! [`position_popover`] is the thin, platform-shared wrapper that does the
//! actual tauri I/O (monitor lookup, window size, cursor position) and hands
//! the pure numbers to [`clamp_to_work_area`].

use tauri::{PhysicalPosition, PhysicalSize};

/// Which corner of the work area to anchor the popover at when the cursor
/// position can't be read. Linux falls back to the top-right corner
/// (closest to a typical top-panel tray); Windows falls back to the
/// bottom-right corner (closest to the notification area, which lives in
/// the taskbar's corner on the overwhelming majority of Windows setups).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FallbackCorner {
    /// Only constructed by Linux's `position_popover` outside tests (see
    /// `platform::linux::position_popover`); on a Windows-only build (this
    /// module is also compiled there — see `platform/mod.rs`'s `#[cfg]`),
    /// nothing but the unit tests below constructs this variant, which
    /// dead-code analysis on the non-test lib target would otherwise flag.
    #[cfg_attr(not(target_os = "linux"), allow(dead_code))]
    TopRight,
    /// Only constructed by Windows's `position_popover` outside tests — the
    /// same reasoning as `TopRight` above, mirrored for a Linux-only build.
    #[cfg_attr(not(target_os = "windows"), allow(dead_code))]
    BottomRight,
}

/// A monitor's work area: origin plus size, in physical pixels. Excludes
/// any OS-reserved chrome (the Windows taskbar, a GNOME top panel with
/// struts, etc.) — this is `tauri::monitor::Monitor::work_area()`'s
/// contract, reproduced here as a plain struct so the clamp math is
/// testable without constructing a real `Monitor`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Rect {
    pub x: i32,
    pub y: i32,
    pub width: u32,
    pub height: u32,
}

/// Pure cursor-anchored, work-area-clamped position calculation. Bit-
/// identical to the arithmetic the Linux `position_popover` used before this
/// extraction (spec-11 Slice B): the min/max bounds are computed the same
/// way (`.max(min_x)`/`.max(min_y)` guards against a window larger than the
/// work area), and the final position is clamped into `[min, max]` on both
/// axes.
///
/// `cursor` is `None` when the platform couldn't read the current cursor
/// position; in that case the popover anchors at `fallback` instead of
/// guessing. Both fallback corners are themselves clamped through the same
/// `[min, max]` bounds, so a work area smaller than the window still
/// produces an on-screen (if slightly overlapping) position.
pub fn clamp_to_work_area(
    work_area: Rect,
    window_size: (u32, u32),
    cursor: Option<(i32, i32)>,
    fallback: FallbackCorner,
) -> (i32, i32) {
    let (window_width, window_height) = window_size;

    let min_x = work_area.x;
    let min_y = work_area.y;
    let max_x = (min_x + work_area.width as i32 - window_width as i32).max(min_x);
    let max_y = (min_y + work_area.height as i32 - window_height as i32).max(min_y);

    let (x, y) = match cursor {
        Some((cursor_x, cursor_y)) => (cursor_x, cursor_y),
        None => match fallback {
            // Top-right corner of the work area (Linux: closest to a
            // typical top-panel tray).
            FallbackCorner::TopRight => {
                (min_x + work_area.width as i32 - window_width as i32, min_y)
            }
            // Bottom-right corner of the work area (Windows: closest to the
            // notification area).
            FallbackCorner::BottomRight => (
                min_x + work_area.width as i32 - window_width as i32,
                min_y + work_area.height as i32 - window_height as i32,
            ),
        },
    };

    (x.clamp(min_x, max_x), y.clamp(min_y, max_y))
}

/// Positions `window` at the current cursor position, clamped into the
/// current monitor's (or, failing that, the primary monitor's) work area,
/// falling back to `fallback` when the cursor position can't be read. Does
/// the tauri I/O (monitor lookup, `outer_size`, `cursor_position`) and hands
/// the resulting plain numbers to [`clamp_to_work_area`] for the actual
/// arithmetic.
pub fn position_popover(window: &tauri::WebviewWindow, fallback: FallbackCorner) {
    let Some(monitor) = window
        .current_monitor()
        .ok()
        .flatten()
        .or_else(|| window.primary_monitor().ok().flatten())
    else {
        return;
    };

    let window_size = window.outer_size().unwrap_or(PhysicalSize::new(400, 300));
    let work_area = monitor.work_area();
    let rect = Rect {
        x: work_area.position.x,
        y: work_area.position.y,
        width: work_area.size.width,
        height: work_area.size.height,
    };

    let cursor = window
        .cursor_position()
        .ok()
        .map(|cursor| (cursor.x as i32, cursor.y as i32));

    let (x, y) = clamp_to_work_area(
        rect,
        (window_size.width, window_size.height),
        cursor,
        fallback,
    );
    let _ = window.set_position(PhysicalPosition::new(x, y));
}

#[cfg(test)]
mod tests {
    use super::*;

    fn area(x: i32, y: i32, width: u32, height: u32) -> Rect {
        Rect {
            x,
            y,
            width,
            height,
        }
    }

    #[test]
    fn cursor_inside_area_is_unchanged() {
        let work_area = area(0, 0, 1920, 1080);
        let (x, y) = clamp_to_work_area(
            work_area,
            (400, 300),
            Some((500, 400)),
            FallbackCorner::TopRight,
        );
        assert_eq!((x, y), (500, 400));
    }

    #[test]
    fn cursor_near_right_edge_is_clamped() {
        let work_area = area(0, 0, 1920, 1080);
        let (x, y) = clamp_to_work_area(
            work_area,
            (400, 300),
            Some((1900, 400)),
            FallbackCorner::TopRight,
        );
        // max_x = 0 + 1920 - 400 = 1520
        assert_eq!((x, y), (1520, 400));
    }

    #[test]
    fn cursor_near_bottom_edge_is_clamped() {
        let work_area = area(0, 0, 1920, 1080);
        let (x, y) = clamp_to_work_area(
            work_area,
            (400, 300),
            Some((500, 1070)),
            FallbackCorner::TopRight,
        );
        // max_y = 0 + 1080 - 300 = 780
        assert_eq!((x, y), (500, 780));
    }

    #[test]
    fn cursor_outside_area_is_clamped_into_it() {
        let work_area = area(0, 0, 1920, 1080);
        let (x, y) = clamp_to_work_area(
            work_area,
            (400, 300),
            Some((-50, -50)),
            FallbackCorner::TopRight,
        );
        assert_eq!((x, y), (0, 0));

        let (x, y) = clamp_to_work_area(
            work_area,
            (400, 300),
            Some((5000, 5000)),
            FallbackCorner::TopRight,
        );
        assert_eq!((x, y), (1520, 780));
    }

    #[test]
    fn window_larger_than_area_stays_at_min() {
        let work_area = area(0, 0, 300, 200);
        let (x, y) = clamp_to_work_area(
            work_area,
            (400, 300),
            Some((100, 100)),
            FallbackCorner::TopRight,
        );
        // max_x/max_y would go negative without the `.max(min_x/min_y)`
        // guard; they must clamp back to the origin instead.
        assert_eq!((x, y), (0, 0));
    }

    #[test]
    fn top_right_fallback_when_cursor_unreadable() {
        let work_area = area(0, 0, 1920, 1080);
        let (x, y) = clamp_to_work_area(work_area, (400, 300), None, FallbackCorner::TopRight);
        assert_eq!((x, y), (1520, 0));
    }

    #[test]
    fn bottom_right_fallback_when_cursor_unreadable() {
        let work_area = area(0, 0, 1920, 1080);
        let (x, y) = clamp_to_work_area(work_area, (400, 300), None, FallbackCorner::BottomRight);
        assert_eq!((x, y), (1520, 780));
    }

    #[test]
    fn non_zero_origin_second_monitor() {
        // A monitor positioned to the right of the primary one.
        let work_area = area(1920, 0, 1920, 1080);
        let (x, y) = clamp_to_work_area(
            work_area,
            (400, 300),
            Some((3800, 900)),
            FallbackCorner::TopRight,
        );
        // max_x = 1920 + 1920 - 400 = 3440; max_y = 0 + 1080 - 300 = 780
        assert_eq!((x, y), (3440, 780));

        let (x, y) = clamp_to_work_area(work_area, (400, 300), None, FallbackCorner::BottomRight);
        assert_eq!((x, y), (3440, 780));
    }
}
