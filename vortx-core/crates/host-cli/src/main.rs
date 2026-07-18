//! Thin binary shell: parse argv, run the round, print the document. Exit codes: 0 success,
//! 1 runtime failure, 2 usage error. All diagnostics go to stderr; stdout carries ONLY the JSON
//! document, so the byte-stability contract is a plain stdout comparison.

use std::process::ExitCode;

use vortx_host_cli::args;

fn main() -> ExitCode {
    let argv: Vec<String> = std::env::args().skip(1).collect();
    let cli = match args::parse(&argv) {
        Ok(cli) => cli,
        Err(err) => {
            eprintln!("error: {}\n\n{}", err.0, args::USAGE);
            return ExitCode::from(2);
        }
    };
    match vortx_host_cli::run(&cli) {
        Ok(json) => {
            println!("{json}");
            ExitCode::SUCCESS
        }
        Err(err) => {
            eprintln!("error: {err}");
            ExitCode::FAILURE
        }
    }
}
