# MultiMouse

MultiMouse is a utility for swapping between different sets of mouse sensitivity settings on Windows.

It was created because I use both a mouse and a trackball for different tasks, and prefer different sensitivity and acceleration profiles for each one.

## Features

- Define up to 9 sensitivity profiles, which include:
  - Mouse sensitivity and acceleration settings
  - A hotkey which activates the profile
- Cycle between profiles using a hotkey
- The currently selected profile is displayed on the tray icon

MultiMouse is accessed via an icon in the system tray.

## Building

Building requires [zig](https://ziglang.org/download/):

```
zig build -Doptimize=ReleaseSafe
```

The binary will be located at `zig-out\bin\multimouse.exe`

## Configuration

The configuration is stored in `%LOCALAPPDATA%\multi-mouse.json`. If this file doesn't exist, a default configuration will be written using your current mouse settings.

The definition of the configuration is as follows:

```
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
        key_code: u8,
    };

    profiles: []Profile = &.{},
    cycle_hotkey: ?Hotkey = null,
};

const MouseSettings = extern struct {
    mouse_threshold_1: windows.INT,
    mouse_threshold_2: windows.INT,
    mouse_speed: windows.INT,
    mouse_sensitivity: windows.INT,
}
```

`mouse_sensitivity` corresponds to the pointer speed set in the "Mouse Properties" dialog.

`mouse_speed` corresponds to the "Enhance pointer precision" option, and is defined in more detail, along with the threshold values [here](https://learn.microsoft.com/en-us/previous-versions/windows/it-pro/windows-2000-server/cc978664(v=technet.10)).

`key_code` is virtual-key code as defined [here](https://learn.microsoft.com/en-us/windows/win32/inputdev/virtual-key-codes).

The tray icon has an `Edit configuration` option which will open the configuration in your default text editor. Use `Reload configuration` to reload the configuration.

### Example configuration

```
{
    "profiles": [
        {
            "name": "Mouse",
            "color": "00ff00",
            "settings": {
                "mouse_threshold_1": 0,
                "mouse_threshold_2": 0,
                "mouse_speed": 0,
                "mouse_sensitivity": 10
            },
            "hotkey": {
                "modifiers": {
                    "shift": true,
                    "win": true
                },
                "key_code": 112
            }
        },
        {
            "name": "Trackball",
            "color": "00ffff",
            "hotkey": null,
            "settings": {
                "mouse_threshold_1": 4,
                "mouse_threshold_2": 10,
                "mouse_speed": 2,
                "mouse_sensitivity": 15
            }
        }
    ],
    "cycle_hotkey": {
        "modifiers": {
            "win": true
        },
        "key_code": 112
    }
}
```


## Support

If you found this software useful, you can support me via [Ko-fi](https://ko-fi.com/I3I1132TAI).
