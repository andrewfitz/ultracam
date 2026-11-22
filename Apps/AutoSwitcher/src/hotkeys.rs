//! macOS virtual key codes, posted as a single press/release pair.
use anyhow::{ensure, Result};
use serde::Deserialize;
use std::{collections::HashMap, path::Path};

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Shortcut {
    keycode: u16,
    #[serde(default)]
    modifiers: Vec<Modifier>,
}
#[derive(Deserialize)]
#[serde(rename_all = "lowercase")]
enum Modifier {
    Shift,
    Control,
    Option,
    Command,
}
pub type Bindings = HashMap<String, Shortcut>;

pub fn load(path: &Path) -> Result<Bindings> {
    let map: Bindings = serde_json::from_reader(std::fs::File::open(path)?)?;
    ensure!(
        map.values().all(|s| s.keycode <= 127),
        "keycode must be in 0..127"
    );
    #[cfg(target_os = "macos")]
    ensure!(
        unsafe { CGPreflightPostEventAccess() },
        "allow this application in macOS Accessibility settings"
    );
    Ok(map)
}

#[cfg(target_os = "macos")]
#[link(name = "CoreGraphics", kind = "framework")]
extern "C" {
    fn CGPreflightPostEventAccess() -> bool;
    fn CGEventCreateKeyboardEvent(source: *const (), code: u16, down: bool) -> *const ();
    fn CGEventSetFlags(event: *const (), flags: u64);
    fn CGEventPost(tap: u32, event: *const ());
}
#[cfg(target_os = "macos")]
#[link(name = "CoreFoundation", kind = "framework")]
extern "C" {
    fn CFRelease(object: *const ());
}

#[cfg(target_os = "macos")]
impl Shortcut {
    pub fn post(&self) -> Result<()> {
        let flags = self.modifiers.iter().fold(0, |f, m| {
            f | 1
                << match m {
                    Modifier::Shift => 17,
                    Modifier::Control => 18,
                    Modifier::Option => 19,
                    Modifier::Command => 20,
                }
        });
        unsafe {
            ensure!(CGPreflightPostEventAccess(), "hotkey permission revoked");
            let down = CGEventCreateKeyboardEvent(std::ptr::null(), self.keycode, true);
            ensure!(!down.is_null(), "cannot create key down");
            let up = CGEventCreateKeyboardEvent(std::ptr::null(), self.keycode, false);
            if up.is_null() {
                CFRelease(down);
                anyhow::bail!("cannot create key up");
            }
            for event in [down, up] {
                CGEventSetFlags(event, flags);
                CGEventPost(0, event);
                CFRelease(event);
            }
        }
        Ok(())
    }
}

#[cfg(not(target_os = "macos"))]
impl Shortcut {
    pub fn post(&self) -> Result<()> {
        anyhow::bail!("global key output requires macOS")
    }
}
