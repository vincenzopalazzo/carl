//! Minimal C ABI for Carl (Zig) over the Pubky Rust SDK.
//! Returns JSON strings: {"ok":true,"data":...} or {"ok":false,"error":"..."}.

use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::panic::{catch_unwind, AssertUnwindSafe};

use once_cell::sync::Lazy;
use pubky::{Keypair, Pubky, PublicKey};
use serde_json::json;
use tokio::runtime::Runtime;

static RUNTIME: Lazy<Runtime> =
    Lazy::new(|| Runtime::new().expect("carl_pubky_bridge tokio runtime"));

fn ok_json(data: serde_json::Value) -> *mut c_char {
    to_c_string(&json!({ "ok": true, "data": data }).to_string())
}

fn err_json(msg: &str) -> *mut c_char {
    to_c_string(&json!({ "ok": false, "error": msg }).to_string())
}

fn to_c_string(s: &str) -> *mut c_char {
    CString::new(s).unwrap_or_default().into_raw()
}

unsafe fn cstr<'a>(p: *const c_char) -> Result<&'a str, *mut c_char> {
    if p.is_null() {
        return Err(err_json("null pointer"));
    }
    CStr::from_ptr(p)
        .to_str()
        .map_err(|_| err_json("invalid utf-8"))
}

fn keypair_from_hex(secret: &str) -> Result<Keypair, String> {
    let bytes = hex::decode(secret.trim()).map_err(|_| "invalid hex secret key".to_string())?;
    let arr: [u8; 32] = bytes
        .try_into()
        .map_err(|_| "secret key must be 32 bytes".to_string())?;
    Ok(Keypair::from_secret(&arr))
}

fn parse_homeserver(homeserver: &str) -> Result<PublicKey, String> {
    homeserver
        .parse()
        .map_err(|e| format!("invalid homeserver pubkey: {e}"))
}

fn parse_pubky(key: &str) -> Result<PublicKey, String> {
    key.parse()
        .map_err(|e| format!("invalid pubky public key: {e}"))
}

fn run<F>(f: F) -> *mut c_char
where
    F: FnOnce() -> *mut c_char + std::panic::UnwindSafe,
{
    catch_unwind(f).unwrap_or_else(|_| err_json("panic in pubky bridge"))
}

#[no_mangle]
pub extern "C" fn carl_pubky_free(s: *mut c_char) {
    if s.is_null() {
        return;
    }
    unsafe {
        let _ = CString::from_raw(s);
    }
}

#[no_mangle]
pub extern "C" fn carl_pubky_generate_secret_key() -> *mut c_char {
    run(|| {
        let keypair = Keypair::random();
        let public_key = keypair.public_key();
        ok_json(json!({
            "secret_key": hex::encode(keypair.secret_key()),
            "public_key": public_key.to_string(),
            "uri": public_key.to_uri_string(),
        }))
    })
}

#[no_mangle]
pub extern "C" fn carl_pubky_public_key_from_secret(secret_key: *const c_char) -> *mut c_char {
    run(|| {
        let secret = match unsafe { cstr(secret_key) } {
            Ok(s) => s,
            Err(p) => return p,
        };
        let keypair = match keypair_from_hex(secret) {
            Ok(k) => k,
            Err(e) => return err_json(&e),
        };
        let public_key = keypair.public_key();
        ok_json(json!({
            "public_key": public_key.to_string(),
            "uri": public_key.to_uri_string(),
        }))
    })
}

#[no_mangle]
pub extern "C" fn carl_pubky_signup(
    secret_key: *const c_char,
    homeserver: *const c_char,
    signup_token: *const c_char,
) -> *mut c_char {
    run(|| {
        let secret = match unsafe { cstr(secret_key) } {
            Ok(s) => s,
            Err(p) => return p,
        };
        let hs = match unsafe { cstr(homeserver) } {
            Ok(s) => s,
            Err(p) => return p,
        };
        let token = if signup_token.is_null() {
            None
        } else {
            match unsafe { cstr(signup_token) } {
                Ok(s) => Some(s),
                Err(p) => return p,
            }
        };

        let keypair = match keypair_from_hex(secret) {
            Ok(k) => k,
            Err(e) => return err_json(&e),
        };
        let homeserver_pk = match parse_homeserver(hs) {
            Ok(k) => k,
            Err(e) => return err_json(&e),
        };

        match RUNTIME.block_on(async {
            let client = Pubky::new().map_err(|e| e.to_string())?;
            let signer = client.signer(keypair);
            let _session = signer
                .signup(&homeserver_pk, token)
                .await
                .map_err(|e| e.to_string())?;
            let pk = signer.public_key();
            Ok::<serde_json::Value, String>(json!({
                "public_key": pk.to_string(),
                "uri": pk.to_uri_string(),
                "homeserver": homeserver_pk.to_string(),
            }))
        }) {
            Ok(v) => ok_json(v),
            Err(e) => err_json(&e),
        }
    })
}

#[no_mangle]
pub extern "C" fn carl_pubky_signin(secret_key: *const c_char) -> *mut c_char {
    run(|| {
        let secret = match unsafe { cstr(secret_key) } {
            Ok(s) => s,
            Err(p) => return p,
        };
        let keypair = match keypair_from_hex(secret) {
            Ok(k) => k,
            Err(e) => return err_json(&e),
        };

        match RUNTIME.block_on(async {
            let client = Pubky::new().map_err(|e| e.to_string())?;
            let signer = client.signer(keypair);
            let _session = signer.signin().await.map_err(|e| e.to_string())?;
            let pk = signer.public_key();
            let hs = client.get_homeserver_of(&pk).await;
            let mut out = json!({
                "public_key": pk.to_string(),
                "uri": pk.to_uri_string(),
            });
            if let Some(h) = hs {
                out["homeserver"] = json!(h.to_string());
            }
            Ok::<serde_json::Value, String>(out)
        }) {
            Ok(v) => ok_json(v),
            Err(e) => err_json(&e),
        }
    })
}

#[no_mangle]
pub extern "C" fn carl_pubky_put(
    secret_key: *const c_char,
    path: *const c_char,
    content: *const c_char,
) -> *mut c_char {
    run(|| {
        let secret = match unsafe { cstr(secret_key) } {
            Ok(s) => s,
            Err(p) => return p,
        };
        let path_str = match unsafe { cstr(path) } {
            Ok(s) => s,
            Err(p) => return p,
        };
        let body = match unsafe { cstr(content) } {
            Ok(s) => s,
            Err(p) => return p,
        };

        if !path_str.starts_with("/pub/") {
            return err_json("path must start with /pub/");
        }

        let keypair = match keypair_from_hex(secret) {
            Ok(k) => k,
            Err(e) => return err_json(&e),
        };

        match RUNTIME.block_on(async {
            let client = Pubky::new().map_err(|e| e.to_string())?;
            let signer = client.signer(keypair);
            let session = signer.signin().await.map_err(|e| e.to_string())?;
            session
                .storage()
                .put(path_str, body.as_bytes())
                .await
                .map_err(|e| e.to_string())?;
            Ok::<serde_json::Value, String>(json!({ "path": path_str }))
        }) {
            Ok(v) => ok_json(v),
            Err(e) => err_json(&e),
        }
    })
}

#[no_mangle]
pub extern "C" fn carl_pubky_get(url: *const c_char) -> *mut c_char {
    run(|| {
        let url_str = match unsafe { cstr(url) } {
            Ok(s) => s,
            Err(p) => return p,
        };

        match RUNTIME.block_on(async {
            let client = Pubky::new().map_err(|e| e.to_string())?;
            let response = client
                .public_storage()
                .get(url_str)
                .await
                .map_err(|e| e.to_string())?;
            let bytes = response.bytes().await.map_err(|e| e.to_string())?;
            let text = String::from_utf8(bytes.to_vec())
                .map_err(|_| "response is not utf-8".to_string())?;
            Ok::<serde_json::Value, String>(json!({ "content": text }))
        }) {
            Ok(v) => ok_json(v),
            Err(e) => err_json(&e),
        }
    })
}

#[no_mangle]
pub extern "C" fn carl_pubky_resolve_homeserver(pubky: *const c_char) -> *mut c_char {
    run(|| {
        let key_str = match unsafe { cstr(pubky) } {
            Ok(s) => s,
            Err(p) => return p,
        };
        let public_key = match parse_pubky(key_str) {
            Ok(k) => k,
            Err(e) => return err_json(&e),
        };

        match RUNTIME.block_on(async {
            let client = Pubky::new().map_err(|e| e.to_string())?;
            let hs = client
                .get_homeserver_of(&public_key)
                .await
                .ok_or_else(|| "no homeserver found for pubky".to_string())?;
            Ok::<serde_json::Value, String>(json!({
                "homeserver": hs.to_string(),
                "uri": hs.to_uri_string(),
            }))
        }) {
            Ok(v) => ok_json(v),
            Err(e) => err_json(&e),
        }
    })
}

#[no_mangle]
pub extern "C" fn carl_pubky_build_file_url(
    pubky_z32: *const c_char,
    path: *const c_char,
) -> *mut c_char {
    run(|| {
        let z32 = match unsafe { cstr(pubky_z32) } {
            Ok(s) => s,
            Err(p) => return p,
        };
        let path_str = match unsafe { cstr(path) } {
            Ok(s) => s,
            Err(p) => return p,
        };
        if !path_str.starts_with("/pub/") {
            return err_json("path must start with /pub/");
        }

        match RUNTIME.block_on(async {
            let client = Pubky::new().map_err(|e| e.to_string())?;
            let user: PublicKey = z32
                .parse()
                .map_err(|e| format!("invalid pubky: {e}"))?;
            let hs = client
                .get_homeserver_of(&user)
                .await
                .ok_or_else(|| "no homeserver for pubky".to_string())?;
            let url = format!("https://{hs}{path_str}");
            Ok::<serde_json::Value, String>(json!({ "url": url, "path": path_str }))
        }) {
            Ok(v) => ok_json(v),
            Err(e) => err_json(&e),
        }
    })
}