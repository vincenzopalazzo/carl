//! Scanner Bencoding format
use albert_stream::{BasicStream, Stream};
use std::vec::Vec;

use crate::ast::BEncodingToken;

pub struct Scanner;

impl Scanner {
    /// Helper function to build the stream of chars from
    /// the input string.
    pub fn make_stream(toks: &str) -> BasicStream<char> {
        let toks: Vec<char> = toks.chars().collect();
        BasicStream::new(&toks)
    }

    /// Core function to scan the input in a sequence of tokens.
    ///
    /// In some sense, this function looks like not useful for a simple
    /// data model language to parser. However, it is possible to
    /// simplify a lot the parser logic and make the logic
    /// more readble.
    pub fn scan(&self, stream: BasicStream<char>) -> Vec<BEncodingToken> {
        vec![]
    }

    /// Parsing a integer from an input stream.
    ///
    /// Example: i3e represents the integer "3"
    /// Example: i-3e represents the integer "-3"
    pub fn parse_int(&mut self, stream: &mut BasicStream<char>) -> BEncodingToken {
        todo!()
    }

    /// Parsing a string from an input stream.
    ///
    /// Example: 4: spam represents the string "spam"
    /// Example: 0: represents the empty string ""
    pub fn parse_str(&self, stream: &mut BasicStream<char>) -> BEncodingToken {
        todo!()
    }

    /// Parsing a list of element from a input stream
    ///
    ///
    /// Example: l4:spam4:eggse represents the list of two strings: [ "spam", "eggs" ]
    /// Example: le represents an empty list: []
    pub fn parse_list(&self, stream: &mut BasicStream<char>) -> BEncodingToken {
        todo!()
    }

    /// Parsing a dictionary from an input stream
    ///
    ///
    /// Example: d3:cow3:moo4:spam4:eggse represents the dictionary { "cow" => "moo", "spam" => "eggs" }
    /// Example: d4:spaml1:a1:bee represents the dictionary { "spam" => [ "a", "b" ] }
    /// Example: d9:publisher3:bob17:publisher-webpage15:www.example.com18:publisher.location4:homee represents { "publisher" => "bob", "publisher-webpage" => "www.example.com", "publisher.location" => "home" }
    /// Example: de represents an empty dictionary {}
    pub fn parse_dic(&self, stream: &mut BasicStream<char>) -> BEncodingToken {
        todo!()
    }
}
