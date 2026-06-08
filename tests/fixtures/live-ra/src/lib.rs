#[cfg(feature = "extra")]
pub fn gated() -> u8 {
  1
}

pub fn call() -> u8 {
  gated()
}
