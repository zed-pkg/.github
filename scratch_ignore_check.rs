//! Behavioral regression gate for directory-only tmp/ and temp/ ignore rules.
//! Uses isolated Git fixtures under ./tmp; it never cleans or changes the caller's Git state.
use std::{env, fs, io::{Read, Write}, path::{Path, PathBuf}, process::{self, Command, Stdio},
    sync::atomic::{AtomicU64, Ordering}, time::{SystemTime, UNIX_EPOCH}};

static NEXT: AtomicU64 = AtomicU64::new(0);
const PROBES: [&str; 4] = ["tmp", "temp", "nested/tmp", "nested/temp"];

#[derive(Debug, PartialEq, Eq)]
enum Error {
    Filesystem, UnsafeScratchRoot, InvalidIgnoreFile, MissingDirectoryRule(&'static str),
    GitLaunch, GitStatus(Option<i32>), WrongVisibility(&'static str),
}

fn directory_rules(policy: &str) -> Result<(), Error> {
    for rule in ["tmp/", "temp/"] {
        if !policy.lines().any(|line| line.trim() == rule) {
            return Err(Error::MissingDirectoryRule(rule));
        }
    }
    Ok(())
}

fn ignored_status(code: Option<i32>) -> Result<bool, Error> {
    match code {
        Some(0) => Ok(true),
        Some(1) => Ok(false),
        other => Err(Error::GitStatus(other)),
    }
}

fn write_new(path: &Path, bytes: &[u8]) -> Result<(), Error> {
    let mut file = fs::OpenOptions::new().write(true).create_new(true).open(path)
        .map_err(|_| Error::Filesystem)?;
    file.write_all(bytes).map_err(|_| Error::Filesystem)?;
    Ok(())
}

fn fixture_root() -> Result<PathBuf, Error> {
    let scratch = env::current_dir().map_err(|_| Error::Filesystem)?.join("tmp");
    match fs::create_dir(&scratch) {
        Ok(()) => (),
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => (),
        Err(_) => return Err(Error::Filesystem),
    }
    if !fs::symlink_metadata(&scratch).map_err(|_| Error::Filesystem)?.is_dir() {
        return Err(Error::UnsafeScratchRoot);
    }
    let nanos = SystemTime::now().duration_since(UNIX_EPOCH)
        .map_err(|_| Error::Filesystem)?.as_nanos();
    for _ in 0..16 {
        let sequence = NEXT.fetch_add(1, Ordering::Relaxed);
        let path = scratch.join(format!("scratch-ignore-{}-{nanos}-{sequence}", process::id()));
        match fs::create_dir(&path) {
            Ok(()) => return Ok(path),
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => (),
            Err(_) => return Err(Error::Filesystem),
        }
    }
    Err(Error::Filesystem)
}

fn git(fixture: &Path) -> Command {
    let mut command = Command::new("git");
    command.current_dir(fixture).stdin(Stdio::null());
    for (key, _) in env::vars_os() {
        if key.to_string_lossy().starts_with("GIT_") { command.env_remove(key); }
    }
    command.env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_CONFIG_GLOBAL", fixture.join("empty-config"))
        .env("GIT_TERMINAL_PROMPT", "0").env("LC_ALL", "C")
        .arg("-c").arg(format!("core.excludesFile={}", fixture.join("empty-config").display()))
        .arg("-c").arg(format!("core.hooksPath={}", fixture.join("empty-hooks").display()));
    command
}

fn prepare(root: &Path, name: &str, policy: &str) -> Result<PathBuf, Error> {
    let fixture = root.join(name);
    fs::create_dir(&fixture).map_err(|_| Error::Filesystem)?;
    fs::create_dir(fixture.join("empty-hooks")).map_err(|_| Error::Filesystem)?;
    write_new(&fixture.join("empty-config"), b"")?;
    write_new(&fixture.join(".gitignore"), policy.as_bytes())?;
    let output = git(&fixture).arg("-c").arg("init.defaultBranch=main")
        .arg("init").arg("--quiet").arg("--template").arg(fixture.join("empty-hooks"))
        .output().map_err(|_| Error::GitLaunch)?;
    if !output.status.success() { return Err(Error::GitStatus(output.status.code())); }
    Ok(fixture)
}

fn behavior(policy: &str) -> Result<(), Error> {
    directory_rules(policy)?;
    let root = fixture_root()?;
    let directories = prepare(&root, "directories", policy)?;
    let files = prepare(&root, "files", policy)?;
    for relative in PROBES {
        let dir = directories.join(relative);
        fs::create_dir_all(&dir).map_err(|_| Error::Filesystem)?;
        write_new(&dir.join("probe.txt"), b"fixture\n")?;
        let probe = format!("{relative}/probe.txt");
        let result = git(&directories).args(["check-ignore", "--no-index", "--quiet", "--", &probe])
            .output().map_err(|_| Error::GitLaunch)?;
        if !ignored_status(result.status.code())? { return Err(Error::WrongVisibility(relative)); }
        let file = files.join(relative);
        fs::create_dir_all(file.parent().ok_or(Error::Filesystem)?).map_err(|_| Error::Filesystem)?;
        write_new(&file, b"legitimate same-named file fixture\n")?;
        let result = git(&files).args(["check-ignore", "--no-index", "--quiet", "--", relative])
            .output().map_err(|_| Error::GitLaunch)?;
        if ignored_status(result.status.code())? { return Err(Error::WrongVisibility(relative)); }
    }
    Ok(())
}

fn read_policy() -> Result<String, Error> {
    if !fs::symlink_metadata(".gitignore").map_err(|_| Error::InvalidIgnoreFile)?.is_file() {
        return Err(Error::InvalidIgnoreFile);
    }
    let file = fs::File::open(".gitignore").map_err(|_| Error::InvalidIgnoreFile)?;
    let mut text = String::new();
    file.take(1_048_577).read_to_string(&mut text).map_err(|_| Error::InvalidIgnoreFile)?;
    if text.len() > 1_048_576 { return Err(Error::InvalidIgnoreFile); }
    Ok(text)
}

fn main() {
    if env::args_os().len() != 1 {
        eprintln!("scratch-ignore: arguments are not accepted"); process::exit(2);
    }
    match read_policy().and_then(|policy| behavior(&policy)) {
        Ok(()) => println!("scratch-ignore: PASS (4 directory probes ignored; 4 same-named file probes visible)"),
        Err(error) => { eprintln!("scratch-ignore: FAIL {error:?}"); process::exit(1); }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test] fn directory_rules_pass() { assert_eq!(directory_rules("tmp/\ntemp/\n"), Ok(())); }
    #[test] fn bare_rules_do_not_satisfy_directory_contract() {
        assert_eq!(directory_rules("tmp\ntemp\n"), Err(Error::MissingDirectoryRule("tmp/")));
    }
    #[test] fn rooted_only_rules_are_insufficient() {
        assert_eq!(directory_rules("/tmp/\n/temp/\n"), Err(Error::MissingDirectoryRule("tmp/")));
    }
    #[test] fn missing_temp_rule_fails() {
        assert_eq!(directory_rules("tmp/\n"), Err(Error::MissingDirectoryRule("temp/")));
    }
    #[test] fn ignored_exit_is_distinct_from_visible_exit() {
        assert_eq!(ignored_status(Some(0)), Ok(true)); assert_eq!(ignored_status(Some(1)), Ok(false));
    }
    #[test] fn git_errors_do_not_pass_negative_checks() {
        for code in [Some(2), Some(128), None] { assert_eq!(ignored_status(code), Err(Error::GitStatus(code))); }
    }
    #[test] fn actual_git_accepts_directory_only_rules() { assert_eq!(behavior("tmp/\ntemp/\n"), Ok(())); }
    #[test] fn actual_git_rejects_appending_slashes_without_removing_bare_rules() {
        assert_eq!(behavior("tmp\ntemp\ntmp/\ntemp/\n"), Err(Error::WrongVisibility("tmp")));
    }
    #[test] fn actual_git_rejects_later_directory_unignore() {
        assert_eq!(behavior("tmp/\ntemp/\n!tmp/\n"), Err(Error::WrongVisibility("tmp")));
    }
    #[test] fn unrelated_secret_and_build_patterns_remain_compatible() {
        assert_eq!(behavior("tmp/\ntemp/\n.env\n*.pem\nnode_modules/\ntarget/\n"), Ok(()));
    }
}
