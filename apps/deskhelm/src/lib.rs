//! Native DDC/CI volume control for an external LG display.

mod display;
mod ffi;
mod prelude {
	pub use color_eyre::Result;
}

pub use display::{VolumeReading, read_volume, set_volume};

// The package's binary target owns the command-line parser.
use clap as _;
