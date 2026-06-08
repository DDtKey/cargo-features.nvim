#[cfg(feature = "tracing")]
pub fn core_mode() -> &'static str {
  "core tracing enabled"
}

#[cfg(not(feature = "tracing"))]
pub fn core_mode() -> &'static str {
  "core tracing disabled"
}
