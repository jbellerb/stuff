mod version;

use std::process::ExitCode;

use anyhow::Result;
use clap::{
    CommandFactory, FromArgMatches, Subcommand,
    builder::{Styles, styling::AnsiColor},
};

use crate::version::VERSION;

const STYLES: Styles = Styles::styled()
    .header(AnsiColor::Yellow.on_default().bold())
    .usage(AnsiColor::Yellow.on_default().bold())
    .literal(AnsiColor::Green.on_default().bold())
    .placeholder(AnsiColor::Cyan.on_default());

/// Lesser Copybara
///
/// A small tool to sync code between repositories.
#[derive(clap::Parser, Debug)]
#[command(name = "lesser-copybara", version(VERSION.version()))]
#[command(args_conflicts_with_subcommands = true)]
struct Args {
    #[command(flatten)]
    global_args: GlobalArgs,
}

#[derive(clap::Args, Clone, Debug)]
struct GlobalArgs {}

#[derive(clap::Parser, Clone, Debug)]
#[command(styles = STYLES)]
enum Command {
    Version(VersionCommand),
}

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(err) => {
            eprintln!("Error: {err}");
            ExitCode::FAILURE
        }
    }
}

fn run() -> Result<()> {
    let matches = Command::augment_subcommands(Args::command())
        .arg_required_else_help(true)
        .subcommand_required(true)
        .get_matches();
    let subcommand = Command::from_arg_matches(&matches).unwrap();
    let args = Args::from_arg_matches(&matches).unwrap();

    match &subcommand {
        Command::Version(cmd) => cmd.exec(args.global_args),
    }
}

/// Display version information
#[derive(clap::Parser, Clone, Debug)]
struct VersionCommand {}

impl VersionCommand {
    fn exec(&self, _global_args: GlobalArgs) -> Result<()> {
        println!("lesser-copybara {}", VERSION.version());
        Ok(())
    }
}
