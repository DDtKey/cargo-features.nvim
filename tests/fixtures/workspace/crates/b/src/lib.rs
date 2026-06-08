#[cfg(feature = "bar")]
pub fn answer() -> u8 {
  43
}

#[cfg(not(feature = "bar"))]
pub fn answer() -> u8 {
  42
}
