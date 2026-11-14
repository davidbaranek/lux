//! Builds the apps' library for Apple platforms: `lux-ffi` (the Rust core, with the Matrix SDK it
//! links) for the iPhone, its simulator and the Mac, as one XCFramework, and its Swift bindings.
//!
//! ```sh
//! cargo xtask apple                         # what the apps ship (all slices), into ../Vendor
//! cargo xtask apple --dev --only macos      # quick, while working: the Mac slice alone
//! cargo xtask apple --dev --only ios-simulator
//! ```
//!
//! The steps follow the SDK's own `xtask swift build-framework` (Apache-2.0): build a static
//! library per target, keep its bundled SQLite private, generate the bindings from the library,
//! gather the headers into one `LuxFFI` module, and pack the XCFramework.

use std::collections::BTreeSet;
use std::fmt::Write as _;
use std::process::Command;
use std::{env, fs};

use camino::{Utf8Path, Utf8PathBuf};
use uniffi_bindgen::bindings::{GenerateOptions, TargetLanguage, generate};

type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;

/// The library each target builds.
const LIBRARY: &str = "liblux_ffi.a";
/// The Clang module the Swift bindings import, and the XCFramework's name.
const MODULE: &str = "LuxFFI";
/// The Swift target of the generated bindings (`Vendor/LuxBindings`).
const BINDINGS: &str = "LuxBindings";
/// The apps' oldest systems.
const DEPLOYMENT_TARGET: &str = "26.0";
/// Symbols kept inside the library: its SQLite (SQLCipher, bundled; the SDK's stores and the
/// app's own share it) would otherwise meet any other SQLite in the app at link time (the
/// system's, a framework's), and one would silently replace the other.
const PRIVATE_SYMBOLS: &[&str] = &["_sqlite3_*", "_sqlcipher*", "_xoshiro_next"];

#[derive(Clone, Copy)]
struct Target {
    triple: &'static str,
    /// The XCFramework slice it goes into: the iPhone, its simulator, the Mac.
    slice: &'static str,
}

const TARGETS: &[Target] = &[
    Target {
        triple: "aarch64-apple-ios",
        slice: "ios",
    },
    Target {
        triple: "aarch64-apple-ios-sim",
        slice: "ios-simulator",
    },
    Target {
        triple: "aarch64-apple-darwin",
        slice: "macos",
    },
];

fn main() -> Result<()> {
    let mut arguments = env::args().skip(1);
    match arguments.next().as_deref() {
        Some("apple") => {
            let mut profile = "distribution".to_owned();
            let mut slices: Vec<String> = Vec::new();
            while let Some(argument) = arguments.next() {
                match argument.as_str() {
                    "--profile" => profile = arguments.next().ok_or("--profile needs a value")?,
                    // quick builds while working: optimized dependencies, lightly optimized core.
                    "--dev" => "dev-apple".clone_into(&mut profile),
                    // only some slices: `--only macos`, `--only ios-simulator` (repeatable).
                    "--only" => slices.push(arguments.next().ok_or("--only needs a slice")?),
                    other => return Err(format!("unknown argument {other}").into()),
                }
            }
            let targets: Vec<Target> = TARGETS
                .iter()
                .copied()
                .filter(|target| slices.is_empty() || slices.iter().any(|slice| slice == target.slice))
                .collect();
            if targets.is_empty() {
                return Err(format!("no slice named {slices:?}: ios, ios-simulator, macos").into());
            }
            build_apple(&profile, &targets)
        }
        _ => Err("usage: cargo xtask apple [--dev | --profile <name>] [--only <ios|ios-simulator|macos>]...".into()),
    }
}

/// The workspace's root (`core/`).
fn workspace() -> Result<Utf8PathBuf> {
    let manifest = Utf8PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    Ok(manifest.parent().ok_or("xtask lives in the workspace")?.to_owned())
}

fn run(command: &mut Command) -> Result<()> {
    let status = command.status()?;
    if status.success() {
        Ok(())
    } else {
        Err(format!("{command:?} failed: {status}").into())
    }
}

fn read(command: &mut Command) -> Result<String> {
    let output = command.output()?;
    if !output.status.success() {
        let error = String::from_utf8_lossy(&output.stderr);
        return Err(format!("{command:?} failed: {}: {}", output.status, error.trim()).into());
    }
    Ok(String::from_utf8(output.stdout)?)
}

/// The symbols of each member of `library` (`nm -A -g`), and what `nm` said about the members it
/// could not read. It reads Apple's LLVM; rustc's newer bitcode in the standard library's members
/// makes it fail on those (exit 1) while it lists the others, SQLite's among them.
fn symbols(library: &Utf8Path) -> Result<(String, String)> {
    let output = Command::new("nm").args(["-A", "-g"]).arg(library).output()?;
    let errors = String::from_utf8_lossy(&output.stderr).trim().to_owned();
    if output.stdout.is_empty() && !output.status.success() {
        return Err(format!("nm failed on {library}: {errors}").into());
    }
    Ok((String::from_utf8(output.stdout)?, errors))
}

fn build_apple(profile: &str, targets: &[Target]) -> Result<()> {
    let root = workspace()?;
    let vendor = root.parent().ok_or("core/ lives in the project")?.join("Vendor");
    let generated = root.join("target/apple");
    let _ = fs::remove_dir_all(&generated);
    fs::create_dir_all(&generated)?;

    let mut libraries = Vec::new();
    for target in targets {
        println!("-- Building {} ({profile})", target.triple);
        run(Command::new("cargo")
            .current_dir(&root)
            .args([
                "rustc",
                "--package",
                "lux-ffi",
                "--crate-type",
                "staticlib",
                "--target",
                target.triple,
                "--profile",
                profile,
            ])
            // the SDK's build sets these too: a set SDKROOT breaks the other targets' C code.
            .env_remove("SDKROOT")
            .env("IPHONEOS_DEPLOYMENT_TARGET", DEPLOYMENT_TARGET)
            .env("MACOSX_DEPLOYMENT_TARGET", DEPLOYMENT_TARGET)
            .env("CARGO_TARGET_AARCH64_APPLE_IOS_RUSTFLAGS", "-Clinker=/usr/bin/clang")
            .env("AARCH64_APPLE_IOS_CC", "/usr/bin/clang"))?;
        let directory = if profile == "dev" { "debug" } else { profile };
        let library = root.join("target").join(target.triple).join(directory).join(LIBRARY);
        localize_private_symbols(&library)?;
        let slice = generated.join("lib").join(target.slice);
        fs::create_dir_all(&slice)?;
        fs::copy(&library, slice.join(LIBRARY))?;
        libraries.push(slice.join(LIBRARY));
    }

    println!("-- Generating the Swift bindings");
    let bindings = generated.join("bindings");
    generate(GenerateOptions {
        languages: vec![TargetLanguage::Swift],
        source: libraries[0].clone(),
        out_dir: bindings.clone(),
        ..GenerateOptions::default()
    })?;
    let headers = generated.join("headers");
    let module = headers.join(MODULE);
    let swift = generated.join("swift");
    fs::create_dir_all(&module)?;
    fs::create_dir_all(&swift)?;
    let mut header_names = BTreeSet::new();
    for entry in bindings.read_dir_utf8()? {
        let path = entry?.into_path();
        match path.extension() {
            Some("h") => {
                header_names.insert(path.file_name().ok_or("a header has a name")?.to_owned());
                fs::rename(&path, module.join(path.file_name().ok_or("a header has a name")?))?;
            }
            Some("swift") => {
                let source = fs::read_to_string(&path)?;
                fs::write(
                    swift.join(path.file_name().ok_or("a file has a name")?),
                    import_module(&source),
                )?;
            }
            _ => {}
        }
    }
    // one module for every crate's header, as the bindings import it.
    let mut modulemap = format!("module {MODULE} {{\n");
    for name in &header_names {
        writeln!(modulemap, "    header \"{name}\"")?;
    }
    modulemap.push_str("    export *\n}\n");
    fs::write(module.join("module.modulemap"), modulemap)?;

    println!("-- Packing {MODULE}.xcframework");
    let framework = vendor.join(format!("{MODULE}.xcframework"));
    let _ = fs::remove_dir_all(&framework);
    let mut command = Command::new("xcodebuild");
    command.arg("-create-xcframework");
    for library in &libraries {
        command.arg("-library").arg(library).arg("-headers").arg(&headers);
    }
    run(command.arg("-output").arg(&framework))?;

    let swift_target = vendor.join(BINDINGS);
    let _ = fs::remove_dir_all(&swift_target);
    fs::create_dir_all(&swift_target)?;
    for entry in swift.read_dir_utf8()? {
        let path = entry?.into_path();
        fs::copy(&path, swift_target.join(path.file_name().ok_or("a file has a name")?))?;
    }
    println!("-- Done: {framework} and {swift_target}");
    Ok(())
}

/// The bindings import each crate's own module (`lux_ffiFFI`); they all live in one.
fn import_module(source: &str) -> String {
    let mut out = String::with_capacity(source.len());
    let mut lines = source.lines().peekable();
    while let Some(line) = lines.next() {
        if line.starts_with("#if canImport(") && line.ends_with("FFI)") {
            let _ = write!(out, "#if canImport({MODULE})\nimport {MODULE}\n");
            // the next line is the crate's own import.
            lines.next();
            continue;
        }
        out.push_str(line);
        out.push('\n');
    }
    out
}

/// Binds the library's own references to its private symbols and hides their definitions, so
/// another copy in the app can neither take their place nor clash with them. Only the archive
/// members that define them go through `ld -r`; the rest stays as it is.
fn localize_private_symbols(library: &Utf8Path) -> Result<()> {
    let directory = library.parent().ok_or("the library lives in a directory")?;
    let symbols_list = directory.join("private_symbols.txt");
    let merged = directory.join("lux_ffi_private.o");
    let objects = directory.join("private-objects");
    let remainder = directory.join("lux_ffi_remainder.a");
    fs::write(&symbols_list, PRIVATE_SYMBOLS.join("\n") + "\n")?;

    // the members that define a private symbol, and every member of the same crates (their
    // references must be bound too).
    let prefix = format!("{library}:");
    let (symbols, unreadable) = symbols(library)?;
    let crates: BTreeSet<&str> = symbols
        .lines()
        .filter(|line| {
            line.split_whitespace().next_back().is_some_and(|symbol| {
                PRIVATE_SYMBOLS
                    .iter()
                    .any(|pattern| symbol.starts_with(pattern.trim_end_matches('*')))
            })
        })
        .filter_map(|line| line.strip_prefix(&prefix))
        .filter_map(|line| line.split(':').next())
        .map(crate_of)
        .collect();
    let all_members = read(Command::new("ar").arg("t").arg(library))?;
    let members: Vec<&str> = all_members
        .lines()
        .filter(|member| crates.contains(crate_of(member)))
        .collect();
    if members.is_empty() {
        return Err(format!("no member of {library} defines {PRIVATE_SYMBOLS:?}; nm: {unreadable}").into());
    }

    let _ = fs::remove_dir_all(&objects);
    fs::create_dir_all(&objects)?;
    run(Command::new("ar")
        .current_dir(&objects)
        .arg("x")
        .arg(library)
        .args(&members))?;
    fs::copy(library, &remainder)?;
    run(Command::new("ar").arg("d").arg(&remainder).args(&members))?;
    println!(
        "-- Keeping SQLite private ({} of {} objects)",
        members.len(),
        all_members.lines().count()
    );
    run(Command::new("ld")
        .arg("-r")
        .arg("-unexported_symbols_list")
        .arg(&symbols_list)
        .arg("-o")
        .arg(&merged)
        .args(members.iter().map(|member| objects.join(member))))?;
    fs::remove_file(library)?;
    run(Command::new("libtool")
        .args(["-static", "-no_warning_for_no_symbols", "-o"])
        .arg(library)
        .arg(&merged)
        .arg(&remainder))?;

    fs::remove_dir_all(&objects)?;
    for file in [&merged, &remainder, &symbols_list] {
        fs::remove_file(file)?;
    }
    Ok(())
}

/// The crate an archive member comes from: `libsqlite3_sys-0123456789abcdef.o` → `libsqlite3_sys`.
fn crate_of(member: &str) -> &str {
    member
        .split_once('-')
        .filter(|(_, rest)| {
            rest.len() > 16 && rest.as_bytes()[16] == b'.' && rest[..16].bytes().all(|byte| byte.is_ascii_hexdigit())
        })
        .map_or(member, |(name, _)| name)
}
