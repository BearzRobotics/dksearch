//! The manual pages as text, for the administration interface's Docs page (the one copy of the documentation).
pub const manual = @embedFile("dksearch.1.md");
pub const api = @embedFile("dksearch-api.7.md");
