//! Modal "enable write access" consent dialog.
//!
//! The app ships read-only by default. Before writes can be enabled the user
//! must read the liability notice and operating notes and tick the consent
//! checkbox; the confirm button stays disabled until then. The dialog is a
//! plain popup window painted with GDI so it matches the app surface instead
//! of pulling in the comctl32 v6 TaskDialog dependency.

use std::ffi::c_void;
use std::mem::size_of;

use windows_sys::Win32::Foundation::{
    GetLastError, ERROR_CLASS_ALREADY_EXISTS, HINSTANCE, HWND, LPARAM, LRESULT, RECT, WPARAM,
};
use windows_sys::Win32::Graphics::Gdi::{
    BeginPaint, CreateFontW, CreateSolidBrush, DeleteObject, DrawFocusRect, DrawTextW, EndPaint,
    FillRect, GetMonitorInfoW, GetSysColor, MonitorFromWindow, RoundRect, SelectObject, SetBkColor,
    SetBkMode, SetTextColor, COLOR_BTNFACE, COLOR_BTNTEXT, COLOR_GRAYTEXT, COLOR_HIGHLIGHT,
    COLOR_HIGHLIGHTTEXT, COLOR_WINDOW, COLOR_WINDOWTEXT, DT_CENTER, DT_LEFT, DT_NOPREFIX,
    DT_SINGLELINE, DT_VCENTER, DT_WORDBREAK, FW_BOLD, FW_NORMAL, HBRUSH, HGDIOBJ, MONITORINFO,
    MONITOR_DEFAULTTONEAREST, PAINTSTRUCT, TRANSPARENT,
};
use windows_sys::Win32::System::LibraryLoader::GetModuleHandleW;
use windows_sys::Win32::UI::Controls::{
    DRAWITEMSTRUCT, ODS_DISABLED, ODS_FOCUS, ODS_SELECTED, ODT_BUTTON,
};
use windows_sys::Win32::UI::Input::KeyboardAndMouse::{
    EnableWindow, GetFocus, IsWindowEnabled, SetFocus, VK_ESCAPE, VK_RETURN,
};
use windows_sys::Win32::UI::Shell::{DefSubclassProc, RemoveWindowSubclass, SetWindowSubclass};
use windows_sys::Win32::UI::WindowsAndMessaging::{
    CreateWindowExW, DefWindowProcW, DestroyWindow, DispatchMessageW, GetClientRect, GetMessageW,
    GetParent, GetWindowLongPtrW, GetWindowRect, IsDialogMessageW, LoadCursorW, PeekMessageW,
    RegisterClassExW, SendMessageW, SetCursor, SetForegroundWindow, SetWindowLongPtrW,
    SetWindowPos, ShowWindow, TranslateMessage, GWLP_USERDATA, HMENU, ICON_BIG, ICON_SMALL,
    IDC_ARROW, IDC_HAND, MSG, PM_REMOVE, SWP_NOACTIVATE, SWP_NOZORDER, SW_SHOW, WM_CLOSE,
    WM_COMMAND, WM_CREATE, WM_DESTROY, WM_GETICON, WM_KEYDOWN, WM_NCDESTROY, WM_PAINT,
    WM_SETCURSOR, WM_SETICON, WNDCLASSEXW, WS_CAPTION, WS_CHILD, WS_POPUP, WS_SYSMENU, WS_TABSTOP,
    WS_VISIBLE,
};
use windows_sys::Win32::UI::WindowsAndMessaging::{
    BM_GETCHECK, BS_AUTOCHECKBOX, BS_OWNERDRAW, SWP_NOMOVE, SWP_NOSIZE, WM_CTLCOLORBTN,
    WM_CTLCOLORSTATIC, WM_DRAWITEM,
};

const DIALOG_CLASS: &str = "AmdMobilePower.UnlockConsent.v1";
const ID_CONSENT_CHECKBOX: usize = 401;
const ID_CONFIRM: usize = 402;
const ID_CANCEL: usize = 403;

const LOGICAL_WIDTH: i32 = 660;
const LOGICAL_HEIGHT: i32 = 640;

const TITLE: &str = "启用写入之前";
const LIABILITY_HEADING: &str = "免责声明";
const LIABILITY_BODY: &str = "本程序开源免费，按「原样」提供，不对任何硬件后果作出担保。\
解锁后，程序会向主板发送功耗限制指令；虽然内置回读校验与保守默认值，\
仍请自行判断风险，并从小数值开始试用。";
const MANUAL_HEADING: &str = "操作须知";
const MANUAL_BODY: &str = "1. 输入 5-60 之间的目标功耗，点「应用」，等待状态变为「已应用」。\n\
2. 三个快捷预设可编辑保存，方便一键切换。\n\
3. 托盘菜单和自动策略可以让插电、电池状态自动切换功耗。\n\
4. 出现「固件限制」提示说明主板未完全接受目标值，实际以上限回读为准。\n\
5. 想恢复只读，点右上角的锁形按钮重新锁定即可。";
const CONSENT_LABEL: &str = "我已阅读并同意以上《免责声明》与操作须知";
const CONFIRM_LABEL: &str = "确认并启用写入";
const CANCEL_LABEL: &str = "取消";

struct DialogShared {
    agreed: bool,
    closed: bool,
    checkbox: HWND,
    confirm: HWND,
    cancel: HWND,
    fonts: DialogFonts,
    percent: i32,
    brush: HBRUSH,
    palette: DialogPalette,
}

struct DialogFonts {
    title: HGDIOBJ,
    heading: HGDIOBJ,
    body: HGDIOBJ,
    control: HGDIOBJ,
}

fn wide(value: &str) -> Vec<u16> {
    value.encode_utf16().chain(std::iter::once(0)).collect()
}

fn scale(value: i32, percent: i32) -> i32 {
    ((value as f64) * (percent as f64) / 100.0).round() as i32
}

fn fit_dialog_percent(requested: i32, work_width: i32, work_height: i32) -> i32 {
    let fit_width = work_width.saturating_mul(100) / LOGICAL_WIDTH;
    let fit_height = work_height.saturating_mul(100) / LOGICAL_HEIGHT;
    requested.max(100).min(fit_width).min(fit_height).max(60)
}

#[derive(Clone, Copy)]
struct DialogPalette {
    background: u32,
    title: u32,
    heading: u32,
    body: u32,
    control_text: u32,
    confirm_fill: u32,
    confirm_pressed: u32,
    confirm_text: u32,
    confirm_disabled_fill: u32,
    confirm_disabled_text: u32,
    cancel_fill: u32,
    cancel_pressed: u32,
    cancel_text: u32,
    border: u32,
}

fn normal_palette() -> DialogPalette {
    DialogPalette {
        background: rgb(14, 21, 24),
        title: rgb(241, 247, 244),
        heading: rgb(69, 214, 168),
        body: rgb(200, 214, 208),
        control_text: rgb(230, 238, 234),
        confirm_fill: rgb(20, 118, 101),
        confirm_pressed: rgb(14, 92, 78),
        confirm_text: rgb(255, 255, 255),
        confirm_disabled_fill: rgb(38, 50, 54),
        confirm_disabled_text: rgb(110, 124, 119),
        cancel_fill: rgb(36, 47, 51),
        cancel_pressed: rgb(50, 64, 68),
        cancel_text: rgb(230, 238, 234),
        border: rgb(70, 86, 90),
    }
}

unsafe fn high_contrast_palette() -> DialogPalette {
    let window = GetSysColor(COLOR_WINDOW);
    let window_text = GetSysColor(COLOR_WINDOWTEXT);
    let highlight = GetSysColor(COLOR_HIGHLIGHT);
    let highlight_text = GetSysColor(COLOR_HIGHLIGHTTEXT);
    let button_face = GetSysColor(COLOR_BTNFACE);
    let button_text = GetSysColor(COLOR_BTNTEXT);
    let gray_text = GetSysColor(COLOR_GRAYTEXT);
    DialogPalette {
        background: window,
        title: window_text,
        heading: window_text,
        body: window_text,
        control_text: window_text,
        confirm_fill: highlight,
        confirm_pressed: highlight,
        confirm_text: highlight_text,
        confirm_disabled_fill: button_face,
        confirm_disabled_text: gray_text,
        cancel_fill: button_face,
        cancel_pressed: highlight,
        cancel_text: button_text,
        border: window_text,
    }
}

unsafe fn create_font(face: &str, pixel_height: i32, weight: i32) -> HGDIOBJ {
    let face = wide(face);
    CreateFontW(
        -pixel_height,
        0,
        0,
        0,
        weight,
        0,
        0,
        0,
        1,
        0,
        0,
        5,
        0,
        face.as_ptr(),
    )
}

unsafe fn shared(hwnd: HWND) -> *mut DialogShared {
    GetWindowLongPtrW(hwnd, GWLP_USERDATA) as *mut DialogShared
}

unsafe extern "system" fn consent_control_proc(
    hwnd: HWND,
    message: u32,
    wparam: WPARAM,
    lparam: LPARAM,
    subclass_id: usize,
    _reference: usize,
) -> LRESULT {
    match message {
        WM_SETCURSOR if IsWindowEnabled(hwnd) != 0 => {
            SetCursor(LoadCursorW(std::ptr::null_mut(), IDC_HAND));
            return 1;
        }
        WM_NCDESTROY => {
            RemoveWindowSubclass(hwnd, Some(consent_control_proc), subclass_id);
        }
        _ => {}
    }
    DefSubclassProc(hwnd, message, wparam, lparam)
}

unsafe extern "system" fn dialog_proc(
    hwnd: HWND,
    message: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    match message {
        WM_CREATE => {
            let create =
                lparam as *const windows_sys::Win32::UI::WindowsAndMessaging::CREATESTRUCTW;
            let state = if create.is_null() {
                std::ptr::null_mut()
            } else {
                (*create).lpCreateParams as *mut DialogShared
            };
            if state.is_null() {
                return -1;
            }
            SetWindowLongPtrW(hwnd, GWLP_USERDATA, state as isize);
            let s = &(*state);
            let instance = GetModuleHandleW(std::ptr::null());
            let checkbox_text = wide(CONSENT_LABEL);
            let checkbox = CreateWindowExW(
                0,
                wide("BUTTON").as_ptr(),
                checkbox_text.as_ptr(),
                WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_AUTOCHECKBOX as u32,
                scale(36, s.percent),
                scale(494, s.percent),
                scale(588, s.percent),
                scale(28, s.percent),
                hwnd,
                ID_CONSENT_CHECKBOX as HMENU,
                instance,
                std::ptr::null(),
            );
            (*state).checkbox = checkbox;
            let cancel_text = wide(CANCEL_LABEL);
            let cancel = CreateWindowExW(
                0,
                wide("BUTTON").as_ptr(),
                cancel_text.as_ptr(),
                WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_OWNERDRAW as u32,
                scale(356, s.percent),
                scale(548, s.percent),
                scale(120, s.percent),
                scale(40, s.percent),
                hwnd,
                ID_CANCEL as HMENU,
                instance,
                std::ptr::null(),
            );
            let confirm_text = wide(CONFIRM_LABEL);
            let confirm = CreateWindowExW(
                0,
                wide("BUTTON").as_ptr(),
                confirm_text.as_ptr(),
                WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_OWNERDRAW as u32,
                scale(492, s.percent),
                scale(548, s.percent),
                scale(132, s.percent),
                scale(40, s.percent),
                hwnd,
                ID_CONFIRM as HMENU,
                instance,
                std::ptr::null(),
            );
            (*state).confirm = confirm;
            (*state).cancel = cancel;
            EnableWindow(confirm, 0);
            for control in [checkbox, cancel, confirm] {
                if !control.is_null() {
                    SendMessageW(control, 0x0030, s.fonts.control as usize, 1);
                    SetWindowSubclass(control, Some(consent_control_proc), 0, 0);
                }
            }
            let parent = GetParent(hwnd);
            if !parent.is_null() {
                for icon_type in [ICON_SMALL, ICON_BIG] {
                    let icon = SendMessageW(parent, WM_GETICON, icon_type as usize, 0);
                    if icon != 0 {
                        SendMessageW(hwnd, WM_SETICON, icon_type as usize, icon);
                    }
                }
            }
            SetFocus(checkbox);
            0
        }
        WM_PAINT => {
            let state = shared(hwnd);
            if state.is_null() {
                return DefWindowProcW(hwnd, message, wparam, lparam);
            }
            let s = &(*state);
            let mut paint = PAINTSTRUCT::default();
            let hdc = BeginPaint(hwnd, &mut paint);
            if hdc.is_null() {
                return 0;
            }
            let mut client = RECT::default();
            GetClientRect(hwnd, &mut client);
            FillRect(hdc, &client, s.brush);
            SetBkMode(hdc, TRANSPARENT as i32);
            let palette = s.palette;
            let draw = |text: &str, font: HGDIOBJ, color: u32, x: i32, y: i32, w: i32, h: i32| {
                let value = wide(text);
                let old = windows_sys::Win32::Graphics::Gdi::SelectObject(hdc, font);
                SetTextColor(hdc, color);
                SetBkColor(hdc, palette.background);
                let mut rect = RECT {
                    left: scale(x, s.percent),
                    top: scale(y, s.percent),
                    right: scale(x + w, s.percent),
                    bottom: scale(y + h, s.percent),
                };
                DrawTextW(
                    hdc,
                    value.as_ptr(),
                    -1,
                    &mut rect,
                    DT_LEFT | DT_WORDBREAK | DT_NOPREFIX,
                );
                windows_sys::Win32::Graphics::Gdi::SelectObject(hdc, old);
            };
            draw(TITLE, s.fonts.title, palette.title, 36, 26, 588, 46);
            draw(
                LIABILITY_HEADING,
                s.fonts.heading,
                palette.heading,
                36,
                86,
                588,
                30,
            );
            draw(
                LIABILITY_BODY,
                s.fonts.body,
                palette.body,
                36,
                122,
                588,
                140,
            );
            draw(
                MANUAL_HEADING,
                s.fonts.heading,
                palette.heading,
                36,
                268,
                588,
                30,
            );
            draw(MANUAL_BODY, s.fonts.body, palette.body, 36, 304, 588, 176);
            EndPaint(hwnd, &paint);
            0
        }
        WM_COMMAND => {
            let id = wparam & 0xFFFF;
            let state = shared(hwnd);
            if state.is_null() {
                return 0;
            }
            let s = &mut (*state);
            match id {
                ID_CONSENT_CHECKBOX => {
                    let checked = SendMessageW(s.checkbox, BM_GETCHECK, 0, 0) == 1;
                    EnableWindow(s.confirm, i32::from(checked));
                    0
                }
                ID_CONFIRM => {
                    let checked = SendMessageW(s.checkbox, BM_GETCHECK, 0, 0) == 1;
                    if checked {
                        s.agreed = true;
                        DestroyWindow(hwnd);
                    }
                    0
                }
                ID_CANCEL => {
                    DestroyWindow(hwnd);
                    0
                }
                _ => DefWindowProcW(hwnd, message, wparam, lparam),
            }
        }
        WM_KEYDOWN => match wparam as u16 {
            VK_ESCAPE => {
                DestroyWindow(hwnd);
                0
            }
            VK_RETURN => {
                let state = shared(hwnd);
                if !state.is_null() {
                    let s = &(*state);
                    let checked = SendMessageW(s.checkbox, BM_GETCHECK, 0, 0) == 1;
                    let focus = GetFocus();
                    if focus == s.confirm && checked {
                        (*state).agreed = true;
                        DestroyWindow(hwnd);
                    } else if focus == s.cancel {
                        DestroyWindow(hwnd);
                    }
                }
                0
            }
            _ => DefWindowProcW(hwnd, message, wparam, lparam),
        },
        WM_CLOSE => {
            DestroyWindow(hwnd);
            0
        }
        WM_DESTROY => {
            let state = shared(hwnd);
            if !state.is_null() {
                (*state).closed = true;
            }
            0
        }
        WM_CTLCOLORBTN => {
            let hdc = wparam as windows_sys::Win32::Graphics::Gdi::HDC;
            let state = shared(hwnd);
            if state.is_null() {
                0
            } else {
                SetBkColor(hdc, (*state).palette.background);
                SetTextColor(hdc, (*state).palette.control_text);
                (*state).brush as LRESULT
            }
        }
        WM_CTLCOLORSTATIC => {
            let hdc = wparam as windows_sys::Win32::Graphics::Gdi::HDC;
            SetBkMode(hdc, TRANSPARENT as i32);
            let state = shared(hwnd);
            if state.is_null() {
                0
            } else {
                SetTextColor(hdc, (*state).palette.body);
                (*state).brush as LRESULT
            }
        }
        WM_DRAWITEM => {
            let draw = lparam as *const DRAWITEMSTRUCT;
            let state = shared(hwnd);
            if draw.is_null() || state.is_null() || (*draw).CtlType != ODT_BUTTON {
                return 0;
            }
            let s = &(*state);
            let draw = &*draw;
            let disabled = draw.itemState & ODS_DISABLED != 0;
            let pressed = draw.itemState & ODS_SELECTED != 0;
            let focused = draw.itemState & ODS_FOCUS != 0;
            let palette = s.palette;
            let (fill, text_color) = if draw.CtlID as usize == ID_CONFIRM {
                if disabled {
                    (palette.confirm_disabled_fill, palette.confirm_disabled_text)
                } else if pressed {
                    (palette.confirm_pressed, palette.confirm_text)
                } else {
                    (palette.confirm_fill, palette.confirm_text)
                }
            } else {
                if pressed {
                    (palette.cancel_pressed, palette.cancel_text)
                } else {
                    (palette.cancel_fill, palette.cancel_text)
                }
            };
            let brush = CreateSolidBrush(fill);
            let pen = windows_sys::Win32::Graphics::Gdi::CreatePen(0, 1, palette.border);
            let old_brush = SelectObject(draw.hDC, brush);
            let old_pen = SelectObject(draw.hDC, pen);
            RoundRect(
                draw.hDC,
                draw.rcItem.left,
                draw.rcItem.top,
                draw.rcItem.right,
                draw.rcItem.bottom,
                10,
                10,
            );
            SelectObject(draw.hDC, old_brush);
            SelectObject(draw.hDC, old_pen);
            DeleteObject(brush);
            DeleteObject(pen);
            SetBkMode(draw.hDC, TRANSPARENT as i32);
            SetTextColor(draw.hDC, text_color);
            let label = if draw.CtlID as usize == ID_CONFIRM {
                CONFIRM_LABEL
            } else {
                CANCEL_LABEL
            };
            let mut text = wide(label);
            let mut rect = draw.rcItem;
            let old_font = SelectObject(draw.hDC, s.fonts.control);
            DrawTextW(
                draw.hDC,
                text.as_mut_ptr(),
                -1,
                &mut rect,
                DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX,
            );
            SelectObject(draw.hDC, old_font);
            if focused && !disabled {
                let mut focus = draw.rcItem;
                focus.left += 3;
                focus.top += 3;
                focus.right -= 3;
                focus.bottom -= 3;
                DrawFocusRect(draw.hDC, &focus);
            }
            1
        }
        _ => DefWindowProcW(hwnd, message, wparam, lparam),
    }
}

fn rgb(red: u8, green: u8, blue: u8) -> u32 {
    (red as u32) | ((green as u32) << 8) | ((blue as u32) << 16)
}

unsafe fn ensure_class(instance: HINSTANCE) -> bool {
    let class_name = wide(DIALOG_CLASS);
    let mut class: WNDCLASSEXW = std::mem::zeroed();
    class.cbSize = size_of::<WNDCLASSEXW>() as u32;
    class.lpfnWndProc = Some(dialog_proc);
    class.hInstance = instance;
    class.hCursor = LoadCursorW(std::ptr::null_mut(), IDC_ARROW);
    class.hbrBackground = std::ptr::null_mut();
    class.lpszClassName = class_name.as_ptr();
    let atom = RegisterClassExW(&class);
    if atom != 0 {
        return true;
    }
    GetLastError() == ERROR_CLASS_ALREADY_EXISTS
}

/// Shows the modal consent dialog.
///
/// # Safety
///
/// `parent` must be a live window handle owned by the calling UI thread.
/// `percent` must be a positive DPI scale percentage used for dialog metrics.
pub unsafe fn show_unlock_dialog(parent: HWND, percent: i32, high_contrast: bool) -> bool {
    let instance = GetModuleHandleW(std::ptr::null());
    if instance.is_null() || !ensure_class(instance) {
        return false;
    }
    let mut work = RECT::default();
    let mut monitor_info: MONITORINFO = std::mem::zeroed();
    monitor_info.cbSize = size_of::<MONITORINFO>() as u32;
    let monitor = MonitorFromWindow(parent, MONITOR_DEFAULTTONEAREST);
    if GetMonitorInfoW(monitor, &mut monitor_info) != 0 {
        work = monitor_info.rcWork;
    } else {
        GetWindowRect(parent, &mut work);
    }
    let percent = fit_dialog_percent(percent, work.right - work.left, work.bottom - work.top);
    let palette = if high_contrast {
        high_contrast_palette()
    } else {
        normal_palette()
    };
    let fonts = DialogFonts {
        title: create_font("Microsoft YaHei UI", scale(28, percent), FW_BOLD as i32),
        heading: create_font("Microsoft YaHei UI", scale(18, percent), FW_BOLD as i32),
        body: create_font("Microsoft YaHei UI", scale(15, percent), FW_NORMAL as i32),
        control: create_font("Microsoft YaHei UI", scale(15, percent), FW_NORMAL as i32),
    };
    let mut state = Box::new(DialogShared {
        agreed: false,
        closed: false,
        checkbox: std::ptr::null_mut(),
        confirm: std::ptr::null_mut(),
        cancel: std::ptr::null_mut(),
        fonts,
        percent,
        brush: CreateSolidBrush(palette.background),
        palette,
    });
    let width = scale(LOGICAL_WIDTH, percent);
    let height = scale(LOGICAL_HEIGHT, percent);
    let x = (work.left + (work.right - work.left - width) / 2).max(work.left);
    let y = (work.top + (work.bottom - work.top - height) / 2).max(work.top);
    let dialog = CreateWindowExW(
        0,
        wide(DIALOG_CLASS).as_ptr(),
        wide(TITLE).as_ptr(),
        WS_POPUP | WS_CAPTION | WS_SYSMENU,
        x,
        y,
        width,
        height,
        parent,
        std::ptr::null_mut(),
        instance,
        &mut *state as *mut DialogShared as *const c_void,
    );
    if dialog.is_null() {
        for font in [
            state.fonts.title,
            state.fonts.heading,
            state.fonts.body,
            state.fonts.control,
        ] {
            if !font.is_null() {
                DeleteObject(font);
            }
        }
        if !state.brush.is_null() {
            DeleteObject(state.brush);
        }
        return false;
    }
    EnableWindow(parent, 0);
    ShowWindow(dialog, SW_SHOW);
    SetForegroundWindow(dialog);
    SetWindowPos(
        dialog,
        std::ptr::null_mut(),
        0,
        0,
        0,
        0,
        SWP_NOZORDER | SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE,
    );
    let mut message = MSG::default();
    loop {
        if state.closed {
            break;
        }
        let result = GetMessageW(&mut message, std::ptr::null_mut(), 0, 0);
        if result == 0 || result == -1 {
            break;
        }
        if IsDialogMessageW(dialog, &message) != 0 {
            continue;
        }
        TranslateMessage(&message);
        DispatchMessageW(&message);
    }
    if !dialog.is_null() && windows_sys::Win32::UI::WindowsAndMessaging::IsWindow(dialog) != 0 {
        DestroyWindow(dialog);
    }
    while PeekMessageW(&mut message, std::ptr::null_mut(), 0, 0, PM_REMOVE) != 0 {
        TranslateMessage(&message);
        DispatchMessageW(&message);
    }
    EnableWindow(parent, 1);
    let agreed = state.agreed;
    let fonts = [
        state.fonts.title,
        state.fonts.heading,
        state.fonts.body,
        state.fonts.control,
    ];
    let brush = state.brush;
    drop(state);
    for font in fonts {
        if !font.is_null() {
            DeleteObject(font);
        }
    }
    if !brush.is_null() {
        DeleteObject(brush);
    }
    agreed
}

#[cfg(test)]
mod tests {
    use super::fit_dialog_percent;

    #[test]
    fn consent_dialog_fits_short_work_area() {
        assert_eq!(fit_dialog_percent(200, 1366, 728), 113);
        assert_eq!(fit_dialog_percent(100, 660, 640), 100);
        assert_eq!(fit_dialog_percent(150, 600, 500), 78);
        assert_eq!(fit_dialog_percent(100, 320, 240), 60);
    }
}
