//! Shared types for design-rule checks (ERC, DRC). Before this module, each
//! check file defined its own Severity enum with a different tag name
//! (`@"error"` vs `error_`), forcing every consumer to translate one to the
//! other when emitting JSON. Anything added for new check categories should
//! reuse these types.

const std = @import("std");

/// Severity of a rule violation, ordered from most to least serious. The tag
/// names match the JSON strings emitted by the check endpoints, so @tagName
/// is a safe JSON-wire value.
pub const Severity = enum { @"error", warning, info };
