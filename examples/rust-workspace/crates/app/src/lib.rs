pub fn app_summary() -> String {
  format!("app={} core={}", serialization_mode(), example_core::core_mode())
}

#[cfg(feature = "serde")]
pub fn serialization_mode() -> &'static str {
  "serde feature enabled"
}

#[cfg(not(feature = "serde"))]
pub fn serialization_mode() -> &'static str {
  "serde feature disabled"
}

#[cfg(feature = "metrics")]
pub fn record_metric(name: &str, value: u64) -> String {
  format!("{name}={value}")
}

#[cfg(not(feature = "metrics"))]
pub fn metrics_status() -> &'static str {
  "metrics feature disabled"
}

#[cfg(feature = "unstable")]
pub fn unstable_probe() -> u32 {
  "unstable intentionally returns the wrong type"
}

#[cfg(not(feature = "unstable"))]
pub fn unstable_probe() -> u32 {
  7
}
