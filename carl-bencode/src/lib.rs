//! Bencoding format parser written in Rust!
//!
//! Bencoding is a way to specify and organize data in a terse format.
//! It supports the following types: byte strings, integers, lists, and dictionaries.
pub mod ast;
pub mod scanner;

// Realiasing in a more readble type.
pub use ast::BEncodingAST as Value;

/// Decoder trait that define the interface for
/// a decoder.
pub trait Decoder {
    /// decode the type from a sequence of bytes
    fn decode(self) -> Result<Value, ()>;
}
