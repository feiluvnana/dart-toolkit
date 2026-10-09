// A macOS dylib names itself by its install name, and without this that is the absolute path
// it was linked at on the build machine. `@rpath/` plus header padding lets a host rename it.
fn main() {
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("macos") {
        println!("cargo:rustc-cdylib-link-arg=-Wl,-headerpad_max_install_names");
        println!("cargo:rustc-cdylib-link-arg=-Wl,-install_name,@rpath/libdart_toolkit_native.dylib");
    }
}
