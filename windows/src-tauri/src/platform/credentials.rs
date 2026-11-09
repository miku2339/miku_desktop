fn target(name: &str) -> Result<Vec<u16>, String> {
    if name.is_empty()
        || name.len() > 80
        || !name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.'))
    {
        return Err("Invalid credential name".into());
    }
    Ok(format!("com.qimake.MikuDesktop/{name}")
        .encode_utf16()
        .chain(Some(0))
        .collect())
}

#[cfg(windows)]
pub fn store_secret(name: &str, value: &str) -> Result<(), String> {
    use windows_sys::Win32::Security::Credentials::*;
    let mut target = target(name)?;
    let mut blob = value.as_bytes().to_vec();
    if blob.len() > CRED_MAX_CREDENTIAL_BLOB_SIZE as usize {
        return Err("Credential exceeds Windows storage limit".into());
    }
    let mut credential: CREDENTIALW = unsafe { std::mem::zeroed() };
    credential.Type = CRED_TYPE_GENERIC;
    credential.TargetName = target.as_mut_ptr();
    credential.CredentialBlobSize = blob.len() as u32;
    credential.CredentialBlob = blob.as_mut_ptr();
    credential.Persist = CRED_PERSIST_LOCAL_MACHINE;
    let success = unsafe { CredWriteW(&credential, 0) };
    let error = std::io::Error::last_os_error();
    for byte in &mut blob {
        unsafe {
            std::ptr::write_volatile(byte, 0);
        }
    }
    if success == 0 {
        Err(format!(
            "Windows Credential Manager could not save the secret: {error}"
        ))
    } else {
        Ok(())
    }
}

#[cfg(windows)]
pub fn load_secret(name: &str) -> Result<Option<String>, String> {
    use windows_sys::Win32::Foundation::{GetLastError, ERROR_NOT_FOUND};
    use windows_sys::Win32::Security::Credentials::*;
    let target = target(name)?;
    let mut credential = std::ptr::null_mut();
    if unsafe { CredReadW(target.as_ptr(), CRED_TYPE_GENERIC, 0, &mut credential) } == 0 {
        let error = unsafe { GetLastError() };
        return if error == ERROR_NOT_FOUND {
            Ok(None)
        } else {
            Err(format!(
                "Windows Credential Manager could not read the secret (code {error})"
            ))
        };
    }
    let result = unsafe {
        if credential.is_null() {
            return Err("Windows Credential Manager returned no credential".into());
        }
        if (*credential).CredentialBlobSize > CRED_MAX_CREDENTIAL_BLOB_SIZE
            || ((*credential).CredentialBlobSize > 0 && (*credential).CredentialBlob.is_null())
        {
            CredFree(credential as _);
            return Err("Stored credential has an invalid size".into());
        }
        let bytes = if (*credential).CredentialBlobSize == 0 {
            &[][..]
        } else {
            std::slice::from_raw_parts(
                (*credential).CredentialBlob,
                (*credential).CredentialBlobSize as usize,
            )
        };
        let result = String::from_utf8(bytes.to_vec())
            .map(Some)
            .map_err(|_| "Stored credential is not valid UTF-8".to_string());
        CredFree(credential as _);
        result
    };
    result
}

#[cfg(windows)]
pub fn delete_secret(name: &str) -> Result<(), String> {
    use windows_sys::Win32::Foundation::{GetLastError, ERROR_NOT_FOUND};
    use windows_sys::Win32::Security::Credentials::{CredDeleteW, CRED_TYPE_GENERIC};
    let target = target(name)?;
    if unsafe { CredDeleteW(target.as_ptr(), CRED_TYPE_GENERIC, 0) } != 0 {
        return Ok(());
    }
    let error = unsafe { GetLastError() };
    if error == ERROR_NOT_FOUND {
        Ok(())
    } else {
        Err(format!(
            "Windows Credential Manager could not delete the secret (code {error})"
        ))
    }
}

#[cfg(not(windows))]
pub fn store_secret(name: &str, _value: &str) -> Result<(), String> {
    target(name)?;
    Err("Windows Credential Manager is unavailable on this platform".into())
}
#[cfg(not(windows))]
pub fn load_secret(name: &str) -> Result<Option<String>, String> {
    target(name)?;
    Err("Windows Credential Manager is unavailable on this platform".into())
}
#[cfg(not(windows))]
pub fn delete_secret(name: &str) -> Result<(), String> {
    target(name)?;
    Err("Windows Credential Manager is unavailable on this platform".into())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn credential_names_are_scoped_and_validated() {
        assert!(target("cloudAI").is_ok());
        assert!(target("aimcp").is_ok());
        for name in ["", "../cloudAI", "a\0b", "other/service"] {
            assert!(target(name).is_err());
        }
    }
}
