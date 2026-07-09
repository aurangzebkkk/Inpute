//! `update()` is a plain synchronous `fn(model, msg)` (Functional Spec §2:
//! "contains no disk or OS-input code... deterministic and testable"), so
//! it has no `std.Io` parameter to thread through. The handful of call
//! sites inside it that do need one (storage save/load, opening a Settings
//! pane) read it from here instead. Set exactly once, in `main`, before
//! the runtime starts dispatching messages.
const std = @import("std");

pub var io: std.Io = undefined;
pub var env: *std.process.Environ.Map = undefined;
