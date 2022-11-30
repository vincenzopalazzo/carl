//! Scanner Bencoding format
use albert_stream::BasicStream;
use std::vec::Vec;

use crate::ast::BEncodingToken;

pub struct Scanner;

impl Scanner {
    pub fn scan(&self, stream: BasicStream<char>) -> Vec<BEncodingToken> {
        vec![]
    }
}
