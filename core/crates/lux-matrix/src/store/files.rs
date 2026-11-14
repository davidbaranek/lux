//! Whether a crypto store is encrypted, and whether a key opens it, read from its SQLite file
//! without the SDK (which has no call for it, and closes the stores it opens only later, on its
//! blocking threads: a folder it failed to open cannot be deleted at once).

use std::path::Path;

use matrix_sdk_store_encryption::StoreCipher;
use rusqlite::{Connection, OpenFlags, OptionalExtension, params};

/// Whether a crypto store's values are encrypted.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Encryption {
    /// Without a key.
    Plain,
    /// With a key.
    Encrypted,
}

/// The value the SDK keeps its own cipher under, encrypted with the key, in an encrypted store's
/// `kv` table; a plain store has none.
const CIPHER: &str = "cipher";

/// Whether the crypto store at `path`, which must exist, is encrypted. The file is opened without
/// a key: the SDK's encryption is in the values, not the file.
pub(super) fn encryption(path: &Path) -> Result<Encryption, rusqlite::Error> {
    Ok(if cipher(path)?.is_some() {
        Encryption::Encrypted
    } else {
        Encryption::Plain
    })
}

/// Whether `key` opens the encrypted crypto store at `path`: it decrypts the SDK's cipher there,
/// as the SDK does when it opens the store.
pub(super) fn key_opens(path: &Path, key: &[u8]) -> Result<bool, rusqlite::Error> {
    Ok(cipher(path)?.is_some_and(|cipher| StoreCipher::import_with_key(key, &cipher).is_ok()))
}

/// The SDK's cipher, encrypted with the key; `None` in a plain store.
fn cipher(path: &Path) -> Result<Option<Vec<u8>>, rusqlite::Error> {
    let connection =
        Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX)?;
    connection
        .query_row("SELECT value FROM kv WHERE key = ?1", params![CIPHER], |row| row.get(0))
        .optional()
}
