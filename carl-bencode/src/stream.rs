//! Customization stream for reading a custom
//! stream of characters.

trait BEncodeTokenStream {
    /// match or check if it is the EOF/
    fn match_or_eof(&mut self) -> bool;
}
