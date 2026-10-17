use std::{
    io::{IsTerminal, Write},
    path::PathBuf,
};

use crate::{
    config::{FanConfig, SpeedCurve},
    error::{Error, Result},
};

#[derive(Debug)]
pub struct FanController {
    manual_file: std::fs::File,
    output_file: std::fs::File,
    config: FanConfig,

    min_speed: u32,
    max_speed: u32,
}

impl FanController {
    pub fn new(path: PathBuf, config: FanConfig) -> Result<Self> {
        fn join_suffix(mut path: PathBuf, suffix: &str) -> PathBuf {
            let file_name = path.file_name().unwrap().to_str().unwrap();
            path.set_file_name(format!("{file_name}{suffix}"));
            path
        }

        fn read_speed(
            path: PathBuf,
            read_err: fn(std::io::Error) -> Error,
            parse_err: fn(std::num::ParseIntError) -> Error,
        ) -> Result<u32> {
            std::fs::read_to_string(path)
                .map_err(read_err)?
                .trim()
                .parse()
                .map_err(parse_err)
        }

        let min_speed = match config.min_speed {
            Some(speed) => speed,
            None => read_speed(
                join_suffix(path.clone(), "_min"),
                Error::MinSpeedRead,
                Error::MinSpeedParse,
            )?,
        };

        let max_speed = match config.max_speed {
            Some(speed) => speed,
            None => read_speed(
                join_suffix(path.clone(), "_max"),
                Error::MaxSpeedRead,
                Error::MaxSpeedParse,
            )?,
        };

        // Equal is fine: the fan just stays at that speed.
        if min_speed > max_speed {
            return Err(Error::InvalidSpeedRange {
                min: min_speed,
                max: max_speed,
            });
        }

        let mut open_options = std::fs::OpenOptions::new();
        open_options.write(true).truncate(true);

        let manual_file = open_options
            .open(join_suffix(path.clone(), "_manual"))
            .map_err(Error::FanOpen)?;

        let output_file = open_options
            .open(join_suffix(path, "_output"))
            .map_err(Error::FanOpen)?;

        let this = Self {
            manual_file,
            output_file,
            config,
            min_speed,
            max_speed,
        };

        println!("Found fan: {this:#?}");
        Ok(this)
    }

    pub fn set_manual(&self, enabled: bool) -> Result<()> {
        (&self.manual_file)
            .write_all(if enabled { b"1" } else { b"0" })
            .map_err(Error::FanWrite)
    }

    pub fn set_speed(&self, speed: u32) -> Result<()> {
        // `new` guarantees min <= max, so this can't panic.
        let speed = speed.clamp(self.min_speed, self.max_speed);

        {
            let mut stdout = std::io::stdout().lock();
            if stdout.is_terminal() {
                print!("\x1b[1K\rSetting fan speed to {speed}");
                let _ = stdout.flush();
            }
        }

        write!(&self.output_file, "{speed}").map_err(Error::FanWrite)?;
        Ok(())
    }

    pub fn calc_speed(&self, temp: u8) -> u32 {
        if self.config.always_full_speed {
            return self.max_speed;
        }

        if temp <= self.config.low_temp {
            return self.min_speed;
        }
        if temp >= self.config.high_temp {
            return self.max_speed;
        }

        let temp = temp as u32;
        let low_temp = self.config.low_temp as u32;
        let high_temp = self.config.high_temp as u32;
        match self.config.speed_curve {
            SpeedCurve::Linear => {
                ((temp - low_temp) as f32 / (high_temp - low_temp) as f32
                    * (self.max_speed - self.min_speed) as f32) as u32
                    + self.min_speed
            }
            SpeedCurve::Exponential => {
                ((temp - low_temp).pow(3) as f32 / (high_temp - low_temp).pow(3) as f32
                    * (self.max_speed - self.min_speed) as f32) as u32
                    + self.min_speed
            }
            SpeedCurve::Logarithmic => {
                (((temp - low_temp) as f32).log((high_temp - low_temp) as f32)
                    * (self.max_speed - self.min_speed) as f32) as u32
                    + self.min_speed
            }
        }
    }
}
