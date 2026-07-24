//! DeskHelm command-line entry point.

mod cli;

// The linked library target owns these package-level macOS dependencies.
use clap::Parser;
use color_eyre::Result;
#[cfg(all(target_os = "macos", target_arch = "aarch64"))]
use {core_foundation_sys as _, core_graphics as _, io_kit_sys as _};

use crate::cli::Cli;

fn main() -> Result<()> {
	color_eyre::install()?;
	Cli::parse().run()?;

	Ok(())
}
