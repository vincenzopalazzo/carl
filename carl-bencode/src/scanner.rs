//! Scanner Bencoding format
use std::collections::HashMap;
use std::rc::Rc;
use std::vec::Vec;

use albert_stream::{BasicStream, Stream};

use crate::ast::BEncodingAST;

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
    pub fn scan(&self, stream: &mut BasicStream<char>) -> Result<Vec<BEncodingAST>, ()> {
        let mut tokens = Vec::new();
        while !stream.is_end() {
            let tok = self.parse_types(stream)?;
            tokens.push(tok);
        }
        Ok(tokens)
    }

    fn parse_types(&self, stream: &mut BasicStream<char>) -> Result<BEncodingAST, ()> {
        match stream.peek() {
            'i' => self.parse_int(stream),
            'l' => self.parse_list(stream),
            'd' => self.parse_dic(stream),
            // FIXME: return an error
            otherwise => {
                if otherwise.is_numeric() {
                    self.parse_str(stream)
                } else {
                    panic!("wrong token {}", stream.peek())
                }
            }
        }
    }

    fn match_or_eof(&self, stream: &mut BasicStream<char>, tok: char) -> bool {
        println!("{}", stream.peek());
        stream.peek().to_owned() == tok
    }

    /// Match the current token in the stream and also if the next one is not inside the stream
    /// this is useful to parse stop tok like the `e`.
    fn with_next_match(&self, stream: &mut BasicStream<char>, tok: char, tok_next: char) -> bool {
        let fut = stream.lookup(2).cloned();
        self.match_or_eof(stream, tok)
            || (!stream.is_end() && fut.is_some() && fut.unwrap().to_owned() == tok_next)
    }

    /// Parsing a integer from an input stream.
    ///
    /// Example: i3e represents the integer "3"
    /// Example: i-3e represents the integer "-3"
    pub fn parse_int(&self, stream: &mut BasicStream<char>) -> Result<BEncodingAST, ()> {
        // check if there is the stop words and check if
        // it is the single one.
        let tok = stream.advance().to_owned();
        assert_eq!(tok, 'i', "expected `i` but found {tok}");
        let mut buff = String::new();
        while !stream.match_tok("e") {
            let tok = stream.advance();
            buff += &tok.to_string();
        }
        assert!(
            stream.advance().to_string() == "e",
            "stop token `e` not found"
        );
        // SAFETY: It is safe to unwrap here because
        // because otherwise it is a bug.
        Ok(BEncodingAST::Int(buff.parse().unwrap()))
    }

    /// Parsing a string from an input stream.
    ///
    /// Example: 4: spam represents the string "spam"
    /// Example: 0: represents the empty string ""
    pub fn parse_str(&self, stream: &mut BasicStream<char>) -> Result<BEncodingAST, ()> {
        let ssize = stream.advance().to_owned();
        assert!(
            ssize.is_numeric(),
            "expected a numeric value but found {ssize}"
        );
        let sep = stream.advance().to_owned();
        assert_eq!(sep, ':', "expected a separator `:` but found {sep}");

        // FIXME: add inside albert stream the method to advance by chunk!
        let mut step: i64 = 0;
        let size: i64 = ssize.to_string().parse().unwrap();
        let mut buff = String::new();
        while step < size {
            let tok = stream.advance().to_owned();
            buff += &tok.to_string();
            step += 1;
        }
        Ok(BEncodingAST::Str(buff))
    }

    /// Parsing a list of element from a input stream
    ///
    ///
    /// Example: l4:spam4:eggse represents the list of two strings: [ "spam", "eggs" ]
    /// Example: le represents an empty list: []
    pub fn parse_list(&self, stream: &mut BasicStream<char>) -> Result<BEncodingAST, ()> {
        let tok = stream.advance().to_owned();
        assert_eq!(tok, 'l', "expected `i` but found {tok}");

        let mut elements = Vec::new();
        while !stream.match_tok("e") {
            let elem = self.parse_types(stream)?;
            elements.push(Rc::new(elem));
        }
        assert!(
            stream.advance().to_string() == "e",
            "stop token `e` not found"
        );

        Ok(BEncodingAST::List(elements))
    }

    /// Parsing a dictionary from an input stream
    ///
    ///
    /// Example: d3:cow3:moo4:spam4:eggse represents the dictionary { "cow" => "moo", "spam" => "eggs" }
    /// Example: d4:spaml1:a1:bee represents the dictionary { "spam" => [ "a", "b" ] }
    /// Example: d9:publisher3:bob17:publisher-webpage15:www.example.com18:publisher.location4:homee represents { "publisher" => "bob", "publisher-webpage" => "www.example.com", "publisher.location" => "home" }
    /// Example: de represents an empty dictionary {}
    pub fn parse_dic(&self, stream: &mut BasicStream<char>) -> Result<BEncodingAST, ()> {
        let tok = stream.advance().to_owned();
        assert_eq!(tok, 'd', "expected `d` but found {tok}");

        let mut elements = Vec::new();
        while !stream.match_tok("e") {
            let key = self.parse_types(stream)?;
            let value = self.parse_types(stream)?;
            elements.push((key.into(), value.into()));
        }
        assert!(
            stream.advance().to_string() == "e",
            "stop token `e` not found"
        );

        Ok(BEncodingAST::Dic(elements))
    }
}

#[cfg(test)]
mod tests {
    use crate::scanner::Scanner;

    #[test]
    fn parse_int_test() {
        let input = "i3e";
        let mut stream = Scanner::make_stream(input);
        let scaner = Scanner {};
        let toks = scaner.scan(&mut stream).unwrap();
        assert_eq!(toks.len(), 1);
    }

    #[test]
    fn parse_string_test() {
        let input = "4:spam";
        let mut stream = Scanner::make_stream(input);
        let scaner = Scanner {};
        let toks = scaner.scan(&mut stream).unwrap();
        assert_eq!(toks.len(), 1);
    }

    #[test]
    fn parse_list_test() {
        let input = "l4:spam4:eggse";

        let mut stream = Scanner::make_stream(input);
        let scaner = Scanner {};
        let toks = scaner.scan(&mut stream).unwrap();
        assert_eq!(toks.len(), 1);
    }

    #[test]
    fn parse_dic_test() {
        let input = "d4:spam4:eggse";

        let mut stream = Scanner::make_stream(input);
        let scaner = Scanner {};
        let toks = scaner.scan(&mut stream).unwrap();
        assert_eq!(toks.len(), 1);
    }
}
