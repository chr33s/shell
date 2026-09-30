fn main() {
    if let Ok(path) = std::env::var("IOS_SYSTEM_FRAMEWORK_PATH") {
        println!("cargo:rustc-cdylib-link-arg=-F{path}");
    }
    println!("cargo:rustc-cdylib-link-arg=-framework");
    println!("cargo:rustc-cdylib-link-arg=ios_system");
    println!("cargo:rerun-if-env-changed=IOS_SYSTEM_FRAMEWORK_PATH");
}
