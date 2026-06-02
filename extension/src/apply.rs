use std::process::{Command, Stdio};

pub fn split_host_port(addr: &str) -> (String, String) {
    match addr.rsplit_once(':') {
        Some((host, port)) => (host.to_string(), port.to_string()),
        None => (addr.to_string(), String::from("5432")),
    }
}

pub fn parent_dir(path: &str) -> String {
    match path.rsplit_once('/') {
        Some((dir, _)) => dir.to_string(),
        None => String::from("."),
    }
}

pub fn spawn_rejoin(
    script: &str,
    pgbin: &str,
    datadir: &str,
    leader_host: &str,
    leader_port: &str,
    node_id: u64,
) -> bool {
    Command::new("setsid")
        .arg("bash")
        .arg(script)
        .arg(pgbin)
        .arg(datadir)
        .arg(leader_host)
        .arg(leader_port)
        .arg(node_id.to_string())
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .is_ok()
}

pub fn run_sql(psql: &str, host: &str, port: &str, sql: &str) -> Result<String, String> {
    let output = Command::new(psql)
        .args([
            "-h", host,
            "-p", port,
            "-U", "postgres",
            "-d", "postgres",
            "-v", "ON_ERROR_STOP=1",
            "-tAc", sql,
        ])
        .output()
        .map_err(|error| format!("spawn failed: {}", error))?;

    if output.status.success() {
        Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
    } else {
        Err(String::from_utf8_lossy(&output.stderr).trim().to_string())
    }
}
