//! MultiMouse is a utility for switching between different sets of mouse settings

const Config = struct {
    const Profile = struct {
        name: []const u8,
        color: []const u8 = "ffffffff",
        hotkey: ?Hotkey = null,
        settings: MouseSettings,
    };

    const Hotkey = struct {
        modifiers: struct {
            alt: bool = false,
            ctrl: bool = false,
            shift: bool = false,
            win: bool = false,
        } = .{},
        // https://learn.microsoft.com/en-us/windows/win32/inputdev/virtual-key-codes
        key_code: u8,
    };

    profiles: []Profile = &.{},
    cycle_hotkey: ?Hotkey = null,
};

const MouseSettings = extern struct {
    mouse_threshold_1: windows.INT,
    mouse_threshold_2: windows.INT,
    // https://learn.microsoft.com/en-us/previous-versions/windows/it-pro/windows-2000-server/cc978664(v=technet.10)
    mouse_speed: windows.INT,
    mouse_sensitivity: windows.INT,

    pub fn get() !MouseSettings {
        var mouse_info: MouseSettings = undefined;
        if (wm.SystemParametersInfo(
            wm.SPI_GETMOUSE,
            0,
            &mouse_info,
            .{},
        ) == 0) {
            return windows.unexpectedError(windows.GetLastError());
        }

        if (wm.SystemParametersInfo(
            wm.SPI_GETMOUSESPEED,
            0,
            &mouse_info.mouse_sensitivity,
            .{},
        ) == 0) {
            return windows.unexpectedError(windows.GetLastError());
        }

        return mouse_info;
    }

    pub fn set(self: MouseSettings) !void {
        if (wm.SystemParametersInfo(
            wm.SPI_SETMOUSE,
            0,
            @constCast(&self),
            wm.SPIF_SENDCHANGE,
        ) == 0) {
            return windows.unexpectedError(windows.GetLastError());
        }

        if (wm.SystemParametersInfo(
            wm.SPI_SETMOUSESPEED,
            0,
            @ptrFromInt(@as(usize, @intCast(self.mouse_sensitivity))),
            wm.SPIF_SENDCHANGE,
        ) == 0) {
            return windows.unexpectedError(windows.GetLastError());
        }
    }
};

fn messageBoxFormatSystemMessage(
    hwnd: ?win32.foundation.HWND,
    comptime caption: []const u8,
    message_id: u32,
    style: wm.MESSAGEBOX_STYLE,
) wm.MESSAGEBOX_RESULT {
    const buf: [*:0]u16 = undefined;
    const len = win32.system.diagnostics.debug.FormatMessageW(
        .{
            .ALLOCATE_BUFFER = 1,
            .FROM_SYSTEM = 1,
        },
        null,
        message_id,
        0,
        buf,
        0,
        null,
    );
    defer _ = win32.system.memory.LocalFree(@bitCast(@intFromPtr(buf)));
    if (len == 0) return .OK;

    return wm.MessageBoxW(hwnd, buf, W(caption), style);
}

fn messageBox(
    hwnd: ?win32.foundation.HWND,
    comptime caption: []const u8,
    comptime msg: []const u8,
    style: wm.MESSAGEBOX_STYLE,
) wm.MESSAGEBOX_RESULT {
    return wm.MessageBoxW(hwnd, W(msg), W(caption), style);
}

fn messageBoxFmt(
    hwnd: ?win32.foundation.HWND,
    allocator: std.mem.Allocator,
    comptime caption: []const u8,
    comptime fmt: []const u8,
    args: anytype,
    style: wm.MESSAGEBOX_STYLE,
) !wm.MESSAGEBOX_RESULT {
    const msg = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(msg);
    const msg_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, msg);
    defer allocator.free(msg_w);
    return wm.MessageBoxW(hwnd, msg_w, W(caption), style);
}

fn configPath(allocator: std.mem.Allocator) known_folders.Error!?[]const u8 {
    const folder = try known_folders.getPath(allocator, .local_configuration) orelse return null;
    defer allocator.free(folder);
    return try std.fs.path.join(allocator, &.{ folder, "multi-mouse.json" });
}

fn configurationError(allocator: std.mem.Allocator, path: []const u8, err: anyerror) !void {
    _ = try messageBoxFmt(
        null,
        allocator,
        "Configuration error",
        "Error reading configuration file ({s}): {}",
        .{ path, err },
        .{},
    );
}

fn loadConfig(arena: std.mem.Allocator, path: []const u8) !?Config {
    const buf = std.fs.cwd().readFileAlloc(
        arena,
        path,
        std.math.maxInt(u16),
    ) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => {
            try configurationError(arena, path, err);
            return error.InvalidConfiguration;
        },
    };
    defer arena.free(buf);

    const parse_options = std.json.ParseOptions{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    };

    var config = std.json.parseFromSliceLeaky(Config, arena, buf, parse_options) catch |err| {
        try configurationError(arena, path, err);
        return error.InvalidConfiguration;
    };

    config.profiles.len = @min(config.profiles.len, max_profiles);
    return config;
}

fn createIcon(hwnd: win32.foundation.HWND, default_icon: ?wm.HICON, color_rgba: u32, number: u8) ?wm.HICON {
    const dimension = 16;

    const dc = gdi.GetDC(hwnd);
    const dc_icon = gdi.CreateCompatibleDC(dc);
    defer _ = gdi.DeleteDC(dc_icon);
    const dc_text = gdi.CreateCompatibleDC(dc);
    defer _ = gdi.DeleteDC(dc_text);
    _ = gdi.ReleaseDC(hwnd, dc);

    const mask_bitmap = gdi.CreateBitmap(dimension, dimension, 1, 1, null);
    defer _ = gdi.DeleteObject(mask_bitmap);

    const bitmap_header = std.mem.zeroInit(gdi.BITMAPV5HEADER, .{
        .bV5Size = @sizeOf(gdi.BITMAPV5HEADER),
        .bV5Width = dimension,
        .bV5Height = dimension,
        .bV5Planes = 1,
        .bV5BitCount = 32,
        .bV5Compression = gdi.BI_RGB,
    });

    var color_bits: ?*anyopaque = undefined;
    const color_bitmap = gdi.CreateDIBSection(
        dc_icon,
        @ptrCast(&bitmap_header),
        gdi.DIB_RGB_COLORS,
        &color_bits,
        null,
        0,
    );
    defer _ = gdi.DeleteObject(color_bitmap);

    var text_bits: ?*anyopaque = undefined;
    const text_bitmap = gdi.CreateDIBSection(
        dc_text,
        @ptrCast(&bitmap_header),
        gdi.DIB_RGB_COLORS,
        &text_bits,
        null,
        0,
    );
    defer _ = gdi.DeleteObject(text_bitmap);

    const font = gdi.CreateFont(
        dimension,
        0,
        0,
        0,
        700,
        0,
        0,
        0,
        0,
        .DEFAULT_PRECIS,
        .{},
        .CLEARTYPE_QUALITY,
        .DONTCARE,
        W("Terminal"),
    );
    defer _ = gdi.DeleteObject(font);

    var buf: [3]u8 = undefined;
    var buf_w: [3]u16 = undefined;
    const str = std.fmt.bufPrintZ(buf[0..], "{d}", .{number}) catch return null;
    const len = std.unicode.utf8ToUtf16Le(buf_w[0..], str) catch return null;

    _ = gdi.SelectObject(dc_text, font);
    _ = gdi.SelectObject(dc_text, text_bitmap);
    _ = gdi.SetTextColor(dc_text, 0x00ffffff);
    _ = gdi.SetBkColor(dc_text, 0x00000000);
    _ = gdi.SetBkMode(dc_text, .OPAQUE);
    var rect: win32.foundation.RECT = .{ .top = 0, .left = 10, .bottom = dimension, .right = dimension };
    _ = gdi.DrawTextW(dc_text, @ptrCast(&buf_w), @intCast(len), &rect, .{});

    const Pixel = extern struct {
        b: u8,
        g: u8,
        r: u8,
        a: u8,
    };

    const text_pixels: *align(1) [dimension * dimension]Pixel = @ptrCast(text_bits.?);
    const src_r = (color_rgba & 0xff000000) >> 24;
    const src_g = (color_rgba & 0x00ff0000) >> 16;
    const src_b = (color_rgba & 0x0000ff00) >> 8;
    for (text_pixels) |*pixel| {
        const a: u32 = pixel.b;
        pixel.r = @truncate((@as(u32, src_r) * a) >> 8);
        pixel.g = @truncate((@as(u32, src_g) * a) >> 8);
        pixel.b = @truncate((@as(u32, src_b) * a) >> 8);
        pixel.a = @truncate(a);
    }

    _ = gdi.SelectObject(dc_icon, color_bitmap);
    _ = wm.DrawIconEx(
        dc_icon,
        0,
        0,
        default_icon,
        dimension,
        dimension,
        0,
        null,
        .{
            .IMAGE = 1,
            .MASK = 1,
        },
    );

    _ = gdi.AlphaBlend(
        dc_icon,
        0,
        0,
        dimension,
        dimension,
        dc_text,
        0,
        0,
        dimension,
        dimension,
        .{
            .BlendOp = gdi.AC_SRC_OVER,
            .BlendFlags = 0,
            .SourceConstantAlpha = 0xff,
            .AlphaFormat = gdi.AC_SRC_ALPHA,
        },
    );

    var icon_info: wm.ICONINFO = .{
        .fIcon = 1,
        .xHotspot = 0,
        .yHotspot = 0,
        .hbmMask = mask_bitmap,
        .hbmColor = color_bitmap,
    };

    return wm.CreateIconIndirect(&icon_info);
}

fn showContextMenu(hwnd: win32.foundation.HWND, point: win32.foundation.POINT) !void {
    if (wm.CreatePopupMenu()) |menu| {
        _ = wm.SetForegroundWindow(hwnd);

        var arena: std.heap.ArenaAllocator = .init(app.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        for (app.config.profiles, 0..) |state, ix| {
            _ = wm.AppendMenu(
                menu,
                .{
                    .CHECKED = @intFromBool(app.selected_profile == @as(u8, @intCast(ix))),
                },
                @intFromEnum(ContextMenuCommand.profile_start) + ix,
                try std.unicode.utf8ToUtf16LeAllocZ(allocator, state.name),
            );
        }

        _ = wm.AppendMenu(menu, .{ .SEPARATOR = 1 }, 0, null);
        _ = wm.AppendMenu(
            menu,
            .{},
            @intFromEnum(ContextMenuCommand.edit_config),
            W("Edit configuration..."),
        );
        _ = wm.AppendMenu(
            menu,
            .{},
            @intFromEnum(ContextMenuCommand.reload_config),
            W("Reload configuration"),
        );

        _ = wm.AppendMenu(menu, .{ .SEPARATOR = 1 }, 0, null);
        _ = wm.AppendMenu(
            menu,
            .{
                .CHECKED = @intFromBool(app.launch_on_startup),
            },
            @intFromEnum(ContextMenuCommand.launch_on_startup),
            W("Launch on startup"),
        );
        _ = wm.AppendMenu(
            menu,
            .{},
            @intFromEnum(ContextMenuCommand.about),
            W("About..."),
        );

        _ = wm.AppendMenu(menu, .{ .SEPARATOR = 1 }, 0, null);
        _ = wm.AppendMenu(
            menu,
            .{},
            @intFromEnum(ContextMenuCommand.exit),
            W("Exit"),
        );

        _ = wm.TrackPopupMenuEx(menu, @bitCast(wm.TRACK_POPUP_MENU_FLAGS{
            .RIGHTBUTTON = 1,
            .RIGHTALIGN = @intFromBool(wm.GetSystemMetrics(wm.SM_MENUDROPALIGNMENT) != 0),
        }), point.x, point.y, hwnd, null);
        _ = wm.DestroyMenu(menu);
    }
}

fn aboutProc(
    hwnd: win32.foundation.HWND,
    message: windows.UINT,
    wParam: windows.WPARAM,
    lParam: windows.LPARAM,
) callconv(windows.WINAPI) isize {
    _ = lParam;
    switch (message) {
        wm.WM_INITDIALOG => {
            const about_text_fmt = "MultiMouse\r\n\r\nBuild mode: {s}\r\nBuilt with: zig {s}\r\n\r\n© 2024 Casey Banner. All rights reserved.";
            const about_text = W(std.fmt.comptimePrint(about_text_fmt, .{
                @tagName(builtin.mode),
                builtin.zig_version_string,
            }));
            _ = wm.SetDlgItemTextW(hwnd, resource.IDC_ABOUT_TEXT, about_text);
            const text_edit = wm.GetDlgItem(hwnd, resource.IDC_ABOUT_TEXT);
            var style: wm.WINDOW_STYLE = @bitCast(@as(i32, @truncate(wm.GetWindowLongPtrW(text_edit, wm.GWL_STYLE))));
            var ex_style: wm.WINDOW_EX_STYLE = @bitCast(@as(i32, @truncate(wm.GetWindowLongPtrW(text_edit, wm.GWL_EXSTYLE))));

            style.BORDER = 0;
            ex_style.CLIENTEDGE = 0;
            ex_style.STATICEDGE = 0;
            ex_style.WINDOWEDGE = 0;

            _ = wm.SetWindowLongPtrW(text_edit, wm.GWL_STYLE, @as(u32, @bitCast(style)));
            _ = wm.SetWindowLongPtrW(text_edit, wm.GWL_EXSTYLE, @as(u32, @bitCast(ex_style)));
            _ = wm.SetWindowPos(text_edit, null, 0, 0, 0, 0, .{
                .NOMOVE = 1,
                .NOSIZE = 1,
                .NOZORDER = 1,
                .DRAWFRAME = 1,
            });

            return 1;
        },
        wm.WM_COMMAND => {
            switch (@as(u16, @truncate(wParam))) {
                @intFromEnum(wm.IDOK) => {
                    app.about_dialog = null;
                    _ = wm.DestroyWindow(hwnd);
                },
                resource.IDC_ABOUT_GITHUB => {
                    _ = shell.ShellExecuteW(
                        hwnd,
                        W("open"),
                        W("https://github.com/kcbanner/multi-mouse"),
                        null,
                        null,
                        @bitCast(wm.SW_SHOWDEFAULT),
                    );
                },
                else => {},
            }
        },
        wm.WM_CLOSE => {
            app.about_dialog = null;
            _ = wm.DestroyWindow(hwnd);
        },
        else => {},
    }

    return 0;
}

fn wndProc(
    hwnd: win32.foundation.HWND,
    message: windows.UINT,
    wParam: windows.WPARAM,
    lParam: windows.LPARAM,
) callconv(windows.WINAPI) windows.LRESULT {
    switch (message) {
        wm.WM_CREATE => {},
        wm.WM_DESTROY => {
            app.deleteNotificationIcon();
            wm.PostQuitMessage(0);
        },
        wm.WM_COMMAND => {
            switch (@as(u16, @truncate(wParam))) {
                @intFromEnum(ContextMenuCommand.profile_start)...@intFromEnum(ContextMenuCommand.profile_end) - 1 => {
                    const profile_index: u8 = @intCast(wParam - @intFromEnum(ContextMenuCommand.profile_start));
                    app.activateProfile(profile_index);
                },
                @intFromEnum(ContextMenuCommand.reload_config) => app.reloadConfig() catch return -1,
                @intFromEnum(ContextMenuCommand.edit_config) => {
                    const path_w = std.unicode.utf8ToUtf16LeAllocZ(app.allocator, app.config_path) catch return -1;
                    defer app.allocator.free(path_w);
                    _ = shell.ShellExecuteW(
                        hwnd,
                        W("open"),
                        path_w,
                        null,
                        null,
                        @bitCast(wm.SW_SHOW),
                    );
                },
                @intFromEnum(ContextMenuCommand.launch_on_startup) => {
                    app.toggleLaunchOnStartup();
                },
                @intFromEnum(ContextMenuCommand.about) => {
                    if (app.about_dialog == null) {
                        app.about_dialog = wm.CreateDialogParam(
                            app.hinstance,
                            @ptrFromInt(resource.IDD_ABOUT),
                            null,
                            aboutProc,
                            0,
                        );
                    }

                    if (app.about_dialog) |dialog| {
                        _ = wm.ShowWindow(dialog, wm.SW_SHOWNORMAL);
                        _ = wm.SetForegroundWindow(dialog);
                        _ = wm.SetWindowPos(dialog, wm.HWND_TOPMOST, 0, 0, 0, 0, .{
                            .NOMOVE = 1,
                            .NOSIZE = 1,
                            .SHOWWINDOW = 1,
                        });
                    }
                },
                @intFromEnum(ContextMenuCommand.exit) => {
                    _ = wm.DestroyWindow(hwnd);
                },
                else => {},
            }
        },
        wm.WM_HOTKEY => {
            switch (wParam) {
                @intFromEnum(HotkeyId.cycle) => {
                    if (app.config.profiles.len > 0) {
                        const index = if (app.selected_profile) |current_profile| blk: {
                            var index = current_profile + 1;
                            if (index >= app.config.profiles.len) index = 0;
                            break :blk index;
                        } else 0;
                        app.activateProfile(index);
                    }
                },
                @intFromEnum(HotkeyId.profile_start)...@intFromEnum(HotkeyId.profile_end) - 1 => {
                    const index: u8 = @intCast(wParam - @intFromEnum(HotkeyId.profile_start));
                    if (index < app.config.profiles.len) {
                        app.activateProfile(index);
                    }
                },
                else => {},
            }
        },
        @intFromEnum(Messages.notification_callback) => {
            switch (@as(u32, @truncate(@as(usize, @bitCast(lParam))))) {
                wm.WM_CONTEXTMENU => {
                    const point: win32.foundation.POINT = .{
                        .x = @intCast(@as(u16, @truncate(wParam))),
                        .y = @intCast(@as(u16, @truncate(wParam >> 16))),
                    };
                    showContextMenu(hwnd, point) catch return -1;
                },
                else => {},
            }
        },
        else => return wm.DefWindowProc(hwnd, message, wParam, lParam),
    }

    return 0;
}

fn handleError(allocator: std.mem.Allocator, err: anyerror) void {
    switch (err) {
        // Functions that return this error report it themselves
        error.InvalidConfiguration => {},
        error.Unexpected => _ = messageBoxFormatSystemMessage(
            null,
            "Error",
            @intFromEnum(windows.GetLastError()),
            .{},
        ),
        else => {
            _ = messageBoxFmt(
                null,
                allocator,
                "Error",
                "Unexpected error: {}",
                .{err},
                .{},
            ) catch unreachable;
        },
    }
}

pub export fn wWinMain(
    hInstance: windows.HINSTANCE,
    hPrevInstance: ?windows.HINSTANCE,
    pCmdLine: windows.PWSTR,
    nCmdShow: u16,
) callconv(windows.WINAPI) windows.INT {
    _ = hPrevInstance;
    _ = pCmdLine;
    _ = nCmdShow;

    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Exit if there is already another running instance
    var event_security_attributes: win32.security.SECURITY_ATTRIBUTES = .{
        .nLength = @sizeOf(win32.security.SECURITY_ATTRIBUTES),
        .lpSecurityDescriptor = null,
        .bInheritHandle = 0,
    };

    const event = if (win32.system.threading.CreateEventW(
        &event_security_attributes,
        0,
        0,
        W("Local\\MultiMouse"),
    )) |event| blk: {
        if (windows.GetLastError() == .ALREADY_EXISTS) return 0;
        break :blk event;
    } else {
        _ = messageBoxFormatSystemMessage(
            null,
            "Error checking for existing process",
            @intFromEnum(windows.GetLastError()),
            .{},
        );
        return 1;
    };
    defer _ = windows.CloseHandle(event);

    app = App.init(allocator, hInstance) catch |err| {
        handleError(allocator, err);
        return 1;
    };
    defer app.deinit();

    app.createWindow() catch |err| {
        handleError(allocator, err);
        return 1;
    };

    app.registerHotkeys();

    var msg: wm.MSG = undefined;
    while (wm.GetMessage(&msg, null, 0, 0) != 0) {
        _ = wm.TranslateMessage(&msg);
        _ = wm.DispatchMessage(&msg);
    }

    return 0;
}

const App = struct {
    allocator: std.mem.Allocator,
    hinstance: windows.HINSTANCE,
    hwnd: ?win32.foundation.HWND = null,
    config_path: []const u8,
    config_arena: std.heap.ArenaAllocator,
    config: Config,
    launch_on_startup: bool,
    selected_profile: ?u8,

    default_icon: ?wm.HICON,
    custom_icon: ?wm.HICON = null,
    icon_added: bool = false,

    about_dialog: ?win32.foundation.HWND = null,

    fn init(allocator: std.mem.Allocator, hinstance: windows.HINSTANCE) !App {
        const config_path = (try configPath(allocator)) orelse {
            _ = messageBox(
                null,
                "Error",
                "Error determining configuration path",
                .{},
            );
            return error.InvalidConfiguration;
        };

        var config_arena: std.heap.ArenaAllocator = .init(allocator);
        const config = try loadConfig(config_arena.allocator(), config_path) orelse blk: {
            const profiles = try config_arena.allocator().alloc(Config.Profile, 2);
            const initial_settings = try MouseSettings.get();
            profiles[0] = .{
                .name = "Initial Settings",
                .color = "00ff00",
                .settings = initial_settings,
            };
            profiles[1] = .{
                .name = "Initial Settings (Copy)",
                .color = "00ffff",
                .settings = initial_settings,
            };

            const default_config: Config = .{
                .profiles = profiles,
                .cycle_hotkey = .{
                    .modifiers = .{
                        .win = true,
                    },
                    // F1
                    .key_code = 0x70,
                },
            };
            const file = try std.fs.cwd().createFile(config_path, .{ .exclusive = true });
            defer file.close();

            try std.json.stringify(
                default_config,
                .{ .whitespace = .indent_4 },
                file.writer(),
            );

            _ = messageBoxFmt(
                null,
                allocator,
                "Initial Configuration",
                "A default configuration file ({s}), has been generated from your current mouse settings.\r\n\r\n" ++
                    "Use the tray icon context menu to edit and reload it.",
                .{config_path},
                .{},
            ) catch {};

            break :blk default_config;
        };

        var default_icon: ?wm.HICON = undefined;
        _ = win32.ui.controls.LoadIconMetric(
            hinstance,
            @ptrFromInt(resource.IDI_NOTIFICATION_ICON),
            .SMALL,
            &default_icon,
        );

        var path_buf: [windows.MAX_PATH]u16 = undefined;
        var path_len: u32 = undefined;
        const launch_on_startup = win32.system.registry.RegGetValueW(
            win32.system.registry.HKEY_CURRENT_USER,
            startup_reg_key,
            startup_reg_value,
            .{ .REG_SZ = 1 },
            null,
            &path_buf,
            &path_len,
        ) == win32.foundation.ERROR_SUCCESS;

        return .{
            .allocator = allocator,
            .hinstance = hinstance,
            .config_path = config_path,
            .config_arena = config_arena,
            .config = config,
            .selected_profile = if (config.profiles.len > 0) 0 else null,
            .default_icon = default_icon,
            .launch_on_startup = launch_on_startup,
        };
    }

    fn deinit(self: *App) void {
        self.config_arena.deinit();
        self.allocator.free(self.config_path);
        _ = wm.DestroyIcon(self.default_icon);
    }

    fn createWindow(self: *App) !void {
        const window_class_name = W("MultiMouse");
        const wcex: wm.WNDCLASSEX = .{
            .cbSize = @sizeOf(wm.WNDCLASSEX),
            .style = .{},
            .lpfnWndProc = wndProc,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = self.hinstance,
            .hIcon = self.default_icon,
            .hCursor = null,
            .hbrBackground = null,
            .lpszMenuName = null,
            .lpszClassName = window_class_name,
            .hIconSm = null,
        };

        _ = wm.RegisterClassEx(&wcex);

        self.hwnd = wm.CreateWindowEx(
            .{},
            window_class_name,
            null,
            .{},
            0,
            0,
            0,
            0,
            null,
            null,
            self.hinstance,
            null,
        );

        if (self.hwnd == null) {
            return windows.unexpectedError(windows.GetLastError());
        }

        if (!self.ensureNotificationIcon()) {
            _ = messageBox(self.hwnd, "Error", "Error creating tray icon", .{});
            return error.InitializationFailed;
        }
    }

    fn registerHotkey(self: *App, id: HotkeyId, hotkey: Config.Hotkey) void {
        _ = input.keyboard_and_mouse.RegisterHotKey(
            self.hwnd,
            @intCast(@intFromEnum(id)),
            .{
                .ALT = @intFromBool(hotkey.modifiers.alt),
                .CONTROL = @intFromBool(hotkey.modifiers.ctrl),
                .SHIFT = @intFromBool(hotkey.modifiers.shift),
                .WIN = @intFromBool(hotkey.modifiers.win),
                .NOREPEAT = 1,
            },
            hotkey.key_code,
        );
    }

    fn registerHotkeys(self: *App) void {
        if (self.config.cycle_hotkey) |cycle_hotkey| {
            self.registerHotkey(HotkeyId.cycle, cycle_hotkey);
        }

        for (self.config.profiles, 0..) |profile, ix| {
            if (profile.hotkey) |hotkey| {
                self.registerHotkey(@enumFromInt(@intFromEnum(HotkeyId.profile_start) + ix), hotkey);
            }
        }
    }

    fn unregisterHotkeys(self: *App) void {
        _ = input.keyboard_and_mouse.UnregisterHotKey(
            self.hwnd,
            @intFromEnum(HotkeyId.cycle),
        );

        for (0..max_profiles) |ix| {
            _ = input.keyboard_and_mouse.UnregisterHotKey(
                self.hwnd,
                @intCast(@intFromEnum(HotkeyId.profile_start) + @as(u8, @intCast(ix))),
            );
        }
    }

    fn reloadConfig(self: *App) !void {
        var config_arena: std.heap.ArenaAllocator = .init(self.allocator);
        errdefer config_arena.deinit();

        self.unregisterHotkeys();

        const prev_selected_profile = self.selected_profile;
        if (try loadConfig(config_arena.allocator(), self.config_path)) |config| {
            self.config_arena.deinit();
            self.config_arena = config_arena;
            self.config = config;
            self.selected_profile = null;
        }

        if (prev_selected_profile) |prev| {
            if (prev < self.config.profiles.len) self.activateProfile(prev);
        }

        self.registerHotkeys();
    }

    fn activateProfile(self: *App, profile_index: u8) void {
        self.config.profiles[profile_index].settings.set() catch |err| {
            _ = messageBoxFmt(
                null,
                self.allocator,
                "Error activating profile",
                "Unable to activate profile: {}",
                .{err},
                .{},
            ) catch return;
            return;
        };

        self.selected_profile = profile_index;
        _ = self.ensureNotificationIcon();
    }

    fn ensureNotificationIcon(self: *App) bool {
        if (!self.icon_added) {
            // If a previous instance did not exit cleanly, then there may still be an icon in the tray
            self.deleteNotificationIcon();
        }

        var nid = std.mem.zeroInit(shell.NOTIFYICONDATA, .{
            .cbSize = @sizeOf(shell.NOTIFYICONDATA),
        });

        nid.hWnd = self.hwnd;
        nid.uFlags = .{
            .MESSAGE = 1,
            .ICON = 1,
            .GUID = 1,
            .TIP = 1,
            .SHOWTIP = 1,
        };
        nid.uCallbackMessage = @intFromEnum(Messages.notification_callback);

        if (self.selected_profile) |profile_index| {
            const prev_custom_icon = self.custom_icon;
            const color_rgb = std.fmt.parseUnsigned(
                u32,
                self.config.profiles[profile_index].color,
                16,
            ) catch 0xffffff;

            self.custom_icon = createIcon(
                self.hwnd.?,
                self.default_icon,
                color_rgb << 8,
                profile_index + 1,
            );
            nid.hIcon = self.custom_icon;
            if (prev_custom_icon) |icon| _ = wm.DestroyIcon(icon);
        }

        if (nid.hIcon == null) nid.hIcon = self.default_icon;

        std.mem.copyForwards(u16, nid.szTip[0..], W("MultiMouse"));
        nid.guidItem = guids.icon;
        const result = shell.Shell_NotifyIconW(if (self.icon_added) .MODIFY else .ADD, &nid);

        nid.Anonymous.uVersion = shell.NOTIFYICON_VERSION_4;
        _ = shell.Shell_NotifyIconW(.SETVERSION, &nid) != 0;

        const success = result != 0;
        if (success) self.icon_added = true;
        return success;
    }

    fn deleteNotificationIcon(self: *App) void {
        _ = self;
        var nid = std.mem.zeroInit(shell.NOTIFYICONDATA, .{
            .cbSize = @sizeOf(shell.NOTIFYICONDATA),
        });
        nid.uFlags.GUID = 1;
        nid.guidItem = guids.icon;
        _ = shell.Shell_NotifyIconW(.DELETE, &nid) != 0;
    }

    fn toggleLaunchOnStartup(self: *App) void {
        var hkey: ?win32.system.registry.HKEY = undefined;
        if (win32.system.registry.RegOpenKeyExW(
            win32.system.registry.HKEY_CURRENT_USER,
            startup_reg_key,
            0,
            .{ .SET_VALUE = 1 },
            &hkey,
        ) != win32.foundation.ERROR_SUCCESS) {
            _ = messageBoxFormatSystemMessage(
                self.hwnd,
                "Error opening registry key",
                @intFromEnum(windows.GetLastError()),
                .{},
            );

            return;
        }
        defer _ = win32.system.registry.RegCloseKey(hkey);

        if (self.launch_on_startup) {
            if (win32.system.registry.RegDeleteValueW(
                hkey.?,
                startup_reg_value,
            ) == win32.foundation.ERROR_SUCCESS) {
                self.launch_on_startup = false;
            } else {
                _ = messageBoxFormatSystemMessage(
                    self.hwnd,
                    "Error deleting registry value",
                    @intFromEnum(windows.GetLastError()),
                    .{},
                );
            }
        } else {
            var exe_path_buf: [windows.MAX_PATH + 3]u16 = undefined;
            const exe_path_len = win32.system.library_loader.GetModuleFileNameW(
                null,
                @ptrCast(exe_path_buf[1..].ptr),
                windows.MAX_PATH,
            );
            if (exe_path_len == 0 or exe_path_len >= windows.MAX_PATH) return;

            exe_path_buf[0] = W("\"")[0];
            exe_path_buf[exe_path_len + 1] = exe_path_buf[0];
            exe_path_buf[exe_path_len + 2] = 0;
            if (win32.system.registry.RegSetValueExW(
                hkey.?,
                startup_reg_value,
                0,
                .SZ,
                @ptrCast(&exe_path_buf),
                (exe_path_len + 3) * @sizeOf(u16),
            ) == win32.foundation.ERROR_SUCCESS) {
                self.launch_on_startup = true;
            } else {
                _ = messageBoxFormatSystemMessage(
                    self.hwnd,
                    "Error setting registry value",
                    @intFromEnum(windows.GetLastError()),
                    .{},
                );
            }
        }
    }
};

const builtin = @import("builtin");
const std = @import("std");
const known_folders = @import("known-folders");
const win32 = @import("win32");
const resource = @import("resource");
const windows = std.os.windows;
const W = std.unicode.utf8ToUtf16LeStringLiteral;
const wm = win32.ui.windows_and_messaging;
const gdi = win32.graphics.gdi;
const input = win32.ui.input;
const shell = win32.ui.shell;
const logger = std.log.scoped(.multi_mouse);

/// zigwin32 configuration
pub const UNICODE = true;

/// Custom message IDs
const Messages = enum(u32) {
    notification_callback = wm.WM_APP + 1,
};

const startup_reg_key = W("SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Run");
const startup_reg_value = W("MultiMouse");

/// Maximum number of supported profiles.
/// THe limiting factor is space for the single-digit number in the icon.
const max_profiles = 9;

const HotkeyId = enum(usize) {
    cycle = 1,

    profile_start = 2,
    profile_end = 2 + max_profiles,

    _,
};

const ContextMenuCommand = enum(u16) {
    exit,
    edit_config,
    reload_config,
    launch_on_startup,
    about,

    profile_start = 0xff,
    profile_end = 0xff + max_profiles,

    _,
};

const guids = struct {
    const icon = win32.zig.Guid.initString("a3a0eac8-0267-4e09-9fcc-2a99dbef52ef");
};

var app: App = undefined;
