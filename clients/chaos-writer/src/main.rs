use std::path::Path;
use std::str::FromStr;
use std::time::Duration;
use tokio_postgres::{Config, NoTls};

// Jepsen-style safety oracle: write monotonic ids through a multi-host read-write
// connection while faults are injected. Every COMMITTED (acked) id is printed to
// stdout; the harness later checks that every printed id survived. An insert that
// errors is never reused, so printed ids are unique and represent genuine acks.
#[tokio::main]
async fn main() {
    let mut args = std::env::args().skip(1);
    let conninfo = args
        .next()
        .expect("usage: chaos-writer <conninfo> <stop_file>");
    let stop_file = args.next().expect("usage: chaos-writer <conninfo> <stop_file>");
    let config = Config::from_str(&conninfo).expect("bad conninfo");

    let mut id: i64 = 0;
    while !Path::new(&stop_file).exists() {
        let (client, connection) = match config.connect(NoTls).await {
            Ok(pair) => pair,
            Err(_) => {
                tokio::time::sleep(Duration::from_millis(150)).await;
                continue;
            }
        };
        let conn = tokio::spawn(async move {
            let _ = connection.await;
        });

        while !Path::new(&stop_file).exists() {
            id += 1;
            match client
                .execute("INSERT INTO chaos (id) VALUES ($1)", &[&id])
                .await
            {
                Ok(_) => println!("{id}"),
                Err(_) => break,
            }
            tokio::time::sleep(Duration::from_millis(3)).await;
        }
        conn.abort();
    }
}
