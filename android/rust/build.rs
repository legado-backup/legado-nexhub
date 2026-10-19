fn main() {
    println!("cargo::rustc-check-cfg=cfg(has_ech)");
    println!("cargo::rustc-check-cfg=cfg(no_ech)");
    // 交叉编译时 OPENSSL_INCLUDE_DIR 随安装目录变化；不声明会导致沿用上一次
    // 的 no_ech 指纹，产物静默失去 ECH 能力。
    println!("cargo:rerun-if-env-changed=OPENSSL_INCLUDE_DIR");

    // 从环境变量获取 OpenSSL 路径
    let openssl_include = std::env::var("OPENSSL_INCLUDE_DIR")
        .unwrap_or_else(|_| "/usr/include".to_string());

    // 检查 ECH 支持
    let ech_available = std::path::Path::new(&format!("{openssl_include}/openssl/ech.h")).exists();

    if ech_available {
        cc::Build::new()
            .file("ech_helper.c")
            .include(&openssl_include)
            .compile("ech_helper");
        println!("cargo:rustc-cfg=has_ech");
        println!("[build] ECH helper compiled");
    } else {
        println!("cargo:rustc-cfg=no_ech");
        println!("[build] WARNING: ECH not available");
    }
}
