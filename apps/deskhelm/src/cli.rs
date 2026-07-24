use clap::{
	Parser, Subcommand,
	builder::{
		Styles,
		styling::{AnsiColor, Effects},
	},
};
use color_eyre::Result;

use deskhelm::{self};

/// Control an external LG display from the command line.
#[derive(Debug, Parser)]
#[command(
	version,
	rename_all = "kebab",
	styles = styles(),
)]
pub struct Cli {
	#[command(subcommand)]
	command: Command,
}
impl Cli {
	pub(crate) fn run(&self) -> Result<()> {
		match self.command {
			Command::Volume { level } => {
				let reading = match level {
					Some(level) => deskhelm::set_volume(level)?,
					None => deskhelm::read_volume()?,
				};

				println!("{}: {}/{}", reading.display(), reading.current(), reading.maximum());
			},
		}

		Ok(())
	}
}

#[derive(Debug, Subcommand)]
enum Command {
	/// Read or set the external LG display volume.
	Volume {
		/// New volume level. Omit it to read the current level.
		#[arg(value_name = "LEVEL", value_parser = clap::value_parser!(u8).range(0..=100))]
		level: Option<u8>,
	},
}

fn styles() -> Styles {
	Styles::styled()
		.header(AnsiColor::Red.on_default() | Effects::BOLD)
		.usage(AnsiColor::Red.on_default() | Effects::BOLD)
		.literal(AnsiColor::Blue.on_default() | Effects::BOLD)
		.placeholder(AnsiColor::Green.on_default())
}

#[cfg(test)]
mod tests {
	use clap::Parser;

	use crate::cli::{Cli, Command};

	#[test]
	fn volume_command_parses() {
		assert!(matches!(
			Cli::parse_from(["deskhelm", "volume"]).command,
			Command::Volume { level: None }
		));
	}

	#[test]
	fn volume_boundaries_parse() {
		assert!(matches!(
			Cli::parse_from(["deskhelm", "volume", "0"]).command,
			Command::Volume { level: Some(0) }
		));
		assert!(matches!(
			Cli::parse_from(["deskhelm", "volume", "100"]).command,
			Command::Volume { level: Some(100) }
		));
	}

	#[test]
	fn volume_above_one_hundred_is_rejected() {
		assert!(Cli::try_parse_from(["deskhelm", "volume", "101"]).is_err());
	}

	#[test]
	fn a_subcommand_is_required() {
		assert!(Cli::try_parse_from(["deskhelm"]).is_err());
	}
}
