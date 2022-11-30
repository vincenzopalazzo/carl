//! Bencoding parser written in rust
use crate::ast::{BEncodingAST, BEncodingToken};
use albert_stream::BasicStream;

pub struct Parser;

/// All data in a metainfo file is bencoded.
///
/// The specification for bencoding is defined in the ast module.
/// The content of a metainfo file (the file ending in ".torrent") is a bencoded
/// dictionary.
///
/// All character string values are UTF-8 encoded.
impl Parser {
    /// core parser function to parse able
    /// to parse the bencode file content.
    ///
    /// FIXME: it is better that the stream is a list
    /// of tokens?
    pub fn parse(&mut self, stream: &mut BasicStream<BEncodingToken>) -> BEncodingAST {
        todo!()
    }

    /// Parsing a integer from an input stream.
    ///
    /// Example: i3e represents the integer "3"
    /// Example: i-3e represents the integer "-3"
    pub fn parse_int(&mut self, stream: &mut BasicStream<BEncodingToken>) -> BEncodingAST {
        todo!()
    }

    /// Parsing a string from an input stream.
    ///
    /// Example: 4: spam represents the string "spam"
    /// Example: 0: represents the empty string ""
    pub fn parse_str(&self, stream: &mut BasicStream<BEncodingToken>) -> BEncodingAST {
        todo!()
    }

    /// Parsing a list of element from a input stream
    ///
    ///
    /// Example: l4:spam4:eggse represents the list of two strings: [ "spam", "eggs" ]
    /// Example: le represents an empty list: []
    pub fn parse_list(&self, stream: &mut BasicStream<BEncodingToken>) -> BEncodingAST {
        todo!()
    }

    /// Parsing a dictionary from an input stream
    ///
    ///
    /// Example: d3:cow3:moo4:spam4:eggse represents the dictionary { "cow" => "moo", "spam" => "eggs" }
    /// Example: d4:spaml1:a1:bee represents the dictionary { "spam" => [ "a", "b" ] }
    /// Example: d9:publisher3:bob17:publisher-webpage15:www.example.com18:publisher.location4:homee represents { "publisher" => "bob", "publisher-webpage" => "www.example.com", "publisher.location" => "home" }
    /// Example: de represents an empty dictionary {}
    pub fn parse_dic(&self, stream: &mut BasicStream<BEncodingToken>) -> BEncodingAST {
        todo!()
    }
}
