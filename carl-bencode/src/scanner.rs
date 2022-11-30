//! Scanner Bencoding format
use std::vec::Vec;

use crate::ast::BEncodingToken;

pub struct Scanner;

impl Scanner {
    pub fn scan(&self, stream: Vec<u8>) -> Vec<BEncodingToken> {
        vec![]
    }
}
