
// Fleet's only SDK addition: free a C response with the allocator that created it.
// The SDK's public run_command returns CString::into_raw but has no matching free.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn fleet_free_string(value: *mut std::os::raw::c_char) {
    if !value.is_null() {
        let mut bytes = unsafe { std::ffi::CString::from_raw(value) }.into_bytes_with_nul();
        for byte in &mut bytes {
            unsafe { std::ptr::write_volatile(byte, 0) };
        }
    }
}
