//! Bencoding format parser written in Rust!
//!
//! Bencoding is a way to specify and organize data in a terse format.
//! It supports the following types: byte strings, integers, lists, and dictionaries.
pub mod ast;
pub mod scanner;

/// Decoder trait that define the interface for
/// a decoder.
pub trait Decoder {
    type Output;

    /// decode the type from a sequence of bytes
    fn decode<T>(self) -> T;

    fn raw_decode(self) -> Self::Output;
}
