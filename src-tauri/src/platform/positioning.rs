//! Popover-clamping helpers. [`position_popover`] (cursor-anchored) is used
//! by Linux and Windows only — macOS positions a freshly opened popover
//! relative to the menu bar via
//! `tauri_plugin_positioner::Position::TrayBottomCenter` instead, so it
//! never calls this. [`clamp_saved_position`] (clamping a user-dragged,
//! persisted position back on-screen), by contrast, is used on every
//! platform: the drag-to-move feature it supports is not
//! macOS/Linux/Windows-specific, unlike the cursor-anchored placement
//! `position_popover` implements.
//!
//! [`clamp_to_work_area`] is the pure arithmetic, unit tested with injected
//! geometry instead of a real window/monitor. [`position_popover`] and
//! [`clamp_saved_position`] are the thin wrappers that do the actual tauri
//! I/O (monitor lookup, window size, cursor position) and hand the pure
//! numbers to [`clamp_to_work_area`].

use tauri::{PhysicalPosition, PhysicalSize};

/// Which corner of the work area to anchor the popover at when the cursor
/// position can't be read. Linux falls back to the top-right corner
/// (closest to a typical top-panel tray); Windows falls back to the
/// bottom-right corner (closest to the notification area, which lives in
/// the taskbar's corner on the overwhelming majority of Windows setups).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FallbackCorner {
    /// The real fallback anchor for Linux's `position_popover` (see
    /// `platform::linux::position_popover`) when the cursor position can't
    /// be read. Also constructed by `clamp_saved_position` on every
    /// platform, but only as a required `clamp_to_work_area` argument that's
    /// never actually consulted there — `clamp_saved_position` always passes
    /// `Some` for `cursor`, and `clamp_to_work_area` only reads `fallback`
    /// when `cursor` is `None` (see `clamp_saved_position`'s doc comment).
    /// That unconditional construction is why this variant needs no
    /// `#[cfg_attr(..., allow(dead_code))]`, unlike `BottomRight` below.
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

/// Pure cursor-anchored, work-area-clamped position calculation. The
/// min/max bounds use `.max(min_x)`/`.max(min_y)` to guard against a window
/// larger than the work area, and the final position is clamped into
/// `[min, max]` on both axes.
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

/// Reduces a `tauri::window::Monitor` to its work area as a plain [`Rect`] —
/// shared by [`position_popover`] and [`clamp_saved_position`].
fn work_area_rect(monitor: &tauri::window::Monitor) -> Rect {
    let work_area = monitor.work_area();
    Rect {
        x: work_area.position.x,
        y: work_area.position.y,
        width: work_area.size.width,
        height: work_area.size.height,
    }
}

/// Positions `window` at the current cursor position, clamped into the
/// current monitor's (or, failing that, the primary monitor's) work area,
/// falling back to `fallback` when the cursor position can't be read. Does
/// the tauri I/O (monitor lookup, `outer_size`, `cursor_position`) and hands
/// the resulting plain numbers to [`clamp_to_work_area`] for the actual
/// arithmetic.
///
/// Only called on Linux and Windows (see the module doc comment); on a
/// macOS-only build nothing calls this, which dead-code analysis on the
/// non-test lib target would otherwise flag.
#[cfg_attr(
    not(any(target_os = "linux", target_os = "windows")),
    allow(dead_code)
)]
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
    let rect = work_area_rect(&monitor);

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

/// Finds the index of the work-area rect in `monitors` that contains
/// `point` — i.e. the rect `point` falls within on both axes. Pure so it's
/// unit-testable with injected geometry, mirroring [`clamp_to_work_area`].
/// Returns `None` when `point` isn't inside any of them (e.g. the monitor it
/// was saved on has since been unplugged, or the monitor layout otherwise
/// changed); callers then fall back to the primary monitor instead.
pub fn monitor_containing(monitors: &[Rect], point: (i32, i32)) -> Option<usize> {
    let (x, y) = point;
    monitors.iter().position(|area| {
        x >= area.x
            && x < area.x + area.width as i32
            && y >= area.y
            && y < area.y + area.height as i32
    })
}

/// Clamps a previously saved popover position (`saved`, physical pixels —
/// [`crate::core::settings::Settings::popover_position`]) back on-screen:
/// picks whichever currently connected monitor's work area contains
/// `saved` (falling back to the primary monitor when it doesn't — the
/// monitor it was saved on may have been disconnected or the layout
/// otherwise changed since), then reuses [`clamp_to_work_area`] with the
/// window's current `outer_size()` to clamp `saved` into that monitor's
/// work area, the same split [`position_popover`] above uses. Returns
/// `saved` unchanged if no monitor information can be read at all — nothing
/// to clamp into, so guessing would be worse than leaving it alone.
pub fn clamp_saved_position(window: &tauri::WebviewWindow, saved: (i32, i32)) -> (i32, i32) {
    let monitors = window
        .available_monitors()
        .ok()
        .filter(|monitors| !monitors.is_empty())
        .or_else(|| {
            window
                .primary_monitor()
                .ok()
                .flatten()
                .map(|monitor| vec![monitor])
        });

    let Some(monitors) = monitors else {
        return saved;
    };

    let areas: Vec<Rect> = monitors.iter().map(work_area_rect).collect();

    let work_area = monitor_containing(&areas, saved)
        .map(|index| areas[index])
        .or_else(|| {
            window
                .primary_monitor()
                .ok()
                .flatten()
                .map(|monitor| work_area_rect(&monitor))
        })
        .unwrap_or(areas[0]);

    let window_size = window.outer_size().unwrap_or(PhysicalSize::new(400, 300));
    clamp_to_work_area(
        work_area,
        (window_size.width, window_size.height),
        Some(saved),
        // Never actually reached: `Some(saved)` above is always `Some`, and
        // `clamp_to_work_area` only consults `fallback` when it's `None`.
        FallbackCorner::TopRight,
    )
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

    // `monitor_containing` — the pure lookup `clamp_saved_position` uses to
    // find which currently connected monitor a saved position lands on.

    #[test]
    fn monitor_containing_finds_the_monitor_a_point_is_on() {
        let monitors = [area(0, 0, 1920, 1080)];
        assert_eq!(monitor_containing(&monitors, (500, 400)), Some(0));
    }

    #[test]
    fn monitor_containing_returns_none_when_the_point_is_on_no_monitor() {
        let monitors = [area(0, 0, 1920, 1080)];
        // Well past the single monitor's bounds.
        assert_eq!(monitor_containing(&monitors, (5000, 5000)), None);
    }

    #[test]
    fn monitor_containing_finds_the_second_monitor_in_a_multi_monitor_list() {
        let monitors = [
            area(0, 0, 1920, 1080),
            // A monitor positioned to the right of the primary one.
            area(1920, 0, 1920, 1080),
        ];
        assert_eq!(monitor_containing(&monitors, (2500, 500)), Some(1));
    }

    #[test]
    fn monitor_containing_treats_the_far_edge_as_exclusive() {
        // (1920, 0) is one pixel past the first monitor's right edge —
        // i.e. the first pixel of the second monitor, not a shared point.
        let monitors = [area(0, 0, 1920, 1080), area(1920, 0, 1920, 1080)];
        assert_eq!(monitor_containing(&monitors, (1920, 0)), Some(1));
        assert_eq!(monitor_containing(&monitors, (1919, 0)), Some(0));
    }

    // The pure parts of `clamp_saved_position`'s clamp path: given the work
    // areas it would have already enumerated (real I/O untestable without a
    // live `WebviewWindow`), `monitor_containing` picks the target work
    // area and `clamp_to_work_area` does the actual clamping — exactly the
    // composition `clamp_saved_position` runs.

    #[test]
    fn clamp_path_point_on_a_monitor_is_unchanged() {
        let monitors = [area(0, 0, 1920, 1080)];
        let saved = (500, 400);

        let index = monitor_containing(&monitors, saved).expect("point is on a monitor");
        let (x, y) = clamp_to_work_area(monitors[index], (400, 300), Some(saved), FallbackCorner::TopRight);

        assert_eq!((x, y), saved);
    }

    #[test]
    fn clamp_path_point_off_an_edge_is_clamped_into_its_monitor() {
        let monitors = [area(0, 0, 1920, 1080)];
        // Just inside the monitor's bounds but too close to the right edge
        // for a 400-wide window to fit without overflowing it.
        let saved = (1900, 400);

        let index = monitor_containing(&monitors, saved).expect("point is on a monitor");
        let (x, y) = clamp_to_work_area(monitors[index], (400, 300), Some(saved), FallbackCorner::TopRight);

        // max_x = 0 + 1920 - 400 = 1520
        assert_eq!((x, y), (1520, 400));
    }

    #[test]
    fn clamp_path_point_on_a_removed_monitor_falls_back_to_primary() {
        // The position was saved on a second monitor to the right that has
        // since been unplugged — only the primary monitor is left.
        let primary = area(0, 0, 1920, 1080);
        let monitors = [primary];
        let saved_on_removed_monitor = (2500, 500);

        assert_eq!(monitor_containing(&monitors, saved_on_removed_monitor), None);

        // `clamp_saved_position` falls back to the primary monitor's work
        // area in this case, clamping the saved point into it instead of
        // leaving it at its now-meaningless off-screen coordinates.
        let (x, y) = clamp_to_work_area(
            primary,
            (400, 300),
            Some(saved_on_removed_monitor),
            FallbackCorner::TopRight,
        );

        assert_eq!((x, y), (1520, 500));
    }
}
