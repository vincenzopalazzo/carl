//! Torrent File info implementation
//!
//! Author: Vincenzo Palazzo <vincenzopalazzo@member.fsf.org>
use carl_bencode::Value;

/// All data in a metainfo file is bencoded. The format of a valid
/// torrent file is defined inside this struct.
pub struct TrackerFileInfo {
    /// a dictionary that describes the file(s) of the torrent.
    ///
    /// There are two possible forms: one for the case
    /// of a 'single-file' torrent with no directory
    /// structure, and one for the case of a
    /// 'multi-file' torrent.
    pub info: Value,
    /// The announce URL of the tracker
    pub announce: String,
    /// extention to the official specification, offering
    /// backwards-compatibility.
    ///
    /// The official request for a specification change is
    /// <http://bittorrent.org/beps/bep_0012.html>
    // FIXME: the vec type is a string?
    pub announce_list: Vec<String>,
    /// the creation time of the torrent, in standard UNIX epoch format
    /// (integer, seconds since 1-Jan-1970 00:00:00 UTC).
    pub creation_date: Option<u64>,
    /// free-form textual comments of the author
    pub comment: Option<String>,
    /// name and version of the program used to create the .torrent.
    pub created_by: Option<String>,
    /// The string encoding format used to generate the pieces part of the info dictionary
    /// in the .torrent metafile
    pub encoding: String,
}

/// Dictionary that describes the file(s) of the torrent. There are two possible
/// forms: one for the case of a 'single-file' torrent with no
/// directory structure, and one for the case of a 'multi-file'
/// torrent
pub enum InfoDictionary {
    SignleFile(SignleFileInfo),
    MultipleFile(MultipleFileInfo),
}

pub struct SignleFileInfo {
    /// Filename. This is purely advisory
    pub name: String,
    /// Length of the file in bytes
    pub length: u64,
    /// a 32-character hexadecimal string corresponding to the MD5 sum of the file.
    ///
    /// This is not used by BitTorrent at all, but it is included by
    /// some programs for greater compatibility
    pub md5sum: Option<String>,
}

// FIXME: implement the mutliple file info
pub struct MultipleFileInfo {}
