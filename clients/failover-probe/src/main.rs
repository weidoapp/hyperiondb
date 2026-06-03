use std::str::FromStr;
use tokio_postgres::{Config, NoTls};

#[tokio::main]
async fn main() {
    let mut args = std::env::args().skip(1);
    let conninfo = args
        .next()
        .expect("usage: failover-probe <conninfo> <label>");
    let label = args.next().unwrap_or_else(|| "x".to_string());

    let config = match Config::from_str(&conninfo) {
        Ok(config) => config,
        Err(error) => {
            eprintln!("bad conninfo: {error}");
            std::process::exit(2);
        }
    };

    let (client, connection) = match config.connect(NoTls).await {
        Ok(pair) => pair,
        Err(error) => {
            println!("NO_RW_HOST {error}");
            std::process::exit(1);
        }
    };
    tokio::spawn(async move {
        let _ = connection.await;
    });

    let row = client
        .query_one("SELECT inet_server_port(), pg_is_in_recovery()", &[])
        .await
        .expect("probe query failed");
    let port: i32 = row.get(0);
    let in_recovery: bool = row.get(1);

    client
        .execute("INSERT INTO demo VALUES ($1)", &[&format!("routed-{label}")])
        .await
        .expect("write failed");

    println!("OK port={port} in_recovery={in_recovery}");
}
