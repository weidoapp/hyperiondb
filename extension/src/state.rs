use std::fs;
use std::io::Write;

fn path(node_id: u64) -> String {
    format!("/tmp/pg_replica_{}.state", node_id)
}

pub fn write(node_id: u64, line: &str) {
    let target = path(node_id);
    let tmp = format!("{}.tmp", target);
    if let Ok(mut file) = fs::File::create(&tmp) {
        if file.write_all(line.as_bytes()).is_ok() {
            let _ = fs::rename(&tmp, &target);
        }
    }
}

pub fn read(node_id: u64) -> Option<String> {
    fs::read_to_string(path(node_id))
        .ok()
        .map(|value| value.trim().to_string())
}
