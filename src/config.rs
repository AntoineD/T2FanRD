use std::{io::ErrorKind, num::NonZeroUsize, path::PathBuf, str::FromStr};

use nonempty::NonEmpty as NonEmptyVec;

use crate::{fan_controller::FanController, Error, Result};

#[cfg(debug_assertions)]
const CONFIG_FILE: &str = "./t2fand.conf";
#[cfg(not(debug_assertions))]
const CONFIG_FILE: &str = "/etc/t2fand.conf";

#[derive(Clone, Copy, Debug)]
pub enum SpeedCurve {
    Linear,
    Exponential,
    Logarithmic,
}

impl std::fmt::Display for SpeedCurve {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Linear => f.write_str("linear"),
            Self::Exponential => f.write_str("exponential"),
            Self::Logarithmic => f.write_str("logarithmic"),
        }
    }
}

impl FromStr for SpeedCurve {
    type Err = ();
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Ok(match s {
            "linear" => Self::Linear,
            "exponential" => Self::Exponential,
            "logarithmic" => Self::Logarithmic,
            _ => return Err(()),
        })
    }
}

#[derive(Clone, Copy, Debug)]
pub struct FanConfig {
    pub low_temp: u8,
    pub high_temp: u8,
    pub speed_curve: SpeedCurve,
    pub always_full_speed: bool,
    /// Overrides the fan's `fanN_min`, if set.
    pub min_speed: Option<u32>,
    /// Overrides the fan's `fanN_max`, if set.  Some SMCs report a lower
    /// maximum than the fan actually runs at (iMac20,2: `fan1_max` reads 2700
    /// on some starts, 3600 on others, and the fan follows 3600 either way).
    pub max_speed: Option<u32>,
}

impl FanConfig {
    fn write_property<'a>(
        self,
        setter: &'a mut ini::SectionSetter<'a>,
    ) -> &'a mut ini::SectionSetter<'a> {
        setter
            .set("low_temp", self.low_temp.to_string())
            .set("high_temp", self.high_temp.to_string())
            .set("speed_curve", self.speed_curve.to_string())
            .set("always_full_speed", self.always_full_speed.to_string())
            // Written empty when unset, so the generated file lists them.
            .set("min_speed", optional_to_string(self.min_speed))
            .set("max_speed", optional_to_string(self.max_speed))
    }
}

fn optional_to_string(value: Option<u32>) -> String {
    value.map_or_else(String::new, |value| value.to_string())
}

impl Default for FanConfig {
    fn default() -> Self {
        Self {
            low_temp: 55,
            high_temp: 75,
            speed_curve: SpeedCurve::Linear,
            always_full_speed: false,
            min_speed: None,
            max_speed: None,
        }
    }
}

impl TryFrom<&ini::Properties> for FanConfig {
    type Error = Error;

    fn try_from(properties: &ini::Properties) -> Result<Self, Self::Error> {
        fn parse_value<V: FromStr>(value_str: &str, key: &'static str) -> Result<V> {
            value_str
                .parse()
                .map_err(|_| Error::InvalidConfigValue(key))
        }

        // `key =` with no value is invalid here: the key is present.
        fn get_value<V: FromStr>(properties: &ini::Properties, key: &'static str) -> Result<V> {
            let value_str = properties.get(key).ok_or(Error::MissingConfigValue(key))?;
            parse_value(value_str, key)
        }

        // `key =` with no value means unset, so an override can be cleared.
        fn get_optional<V: FromStr>(
            properties: &ini::Properties,
            key: &'static str,
        ) -> Result<Option<V>> {
            properties
                .get(key)
                .filter(|value_str| !value_str.is_empty())
                .map(|value_str| parse_value(value_str, key))
                .transpose()
        }

        Ok(Self {
            low_temp: get_value(properties, "low_temp")?,
            high_temp: get_value(properties, "high_temp")?,
            speed_curve: get_value(properties, "speed_curve")?,
            always_full_speed: get_value(properties, "always_full_speed")?,
            min_speed: get_optional(properties, "min_speed")?,
            max_speed: get_optional(properties, "max_speed")?,
        })
    }
}

fn parse_config_file(file_raw: &str, fan_count: NonZeroUsize) -> Result<Vec<FanConfig>> {
    let file = ini::Ini::load_from_str(file_raw)?;
    let mut configs = Vec::with_capacity(fan_count.get());

    for i in 1..=fan_count.get() {
        let section = file
            .section(Some(format!("Fan{i}")))
            .ok_or(Error::MissingFanConfig(i))?;

        configs.push(FanConfig::try_from(section)?);
    }

    Ok(configs)
}

fn generate_config_file(fan_count: NonZeroUsize) -> Result<Vec<FanConfig>> {
    let mut config_file = ini::Ini::new();
    let mut configs = Vec::with_capacity(fan_count.get());
    for i in 1..=fan_count.get() {
        let config = FanConfig::default();
        configs.push(config);

        let mut setter = config_file.with_section(Some(format!("Fan{i}")));
        config.write_property(&mut setter);
    }

    config_file
        .write_to_file(CONFIG_FILE)
        .map_err(Error::ConfigCreate)?;

    Ok(configs)
}

pub fn load_fan_configs(fan_paths: NonEmptyVec<PathBuf>) -> Result<NonEmptyVec<FanController>> {
    let fan_count = fan_paths.len_nonzero();
    let configs = match std::fs::read_to_string(CONFIG_FILE) {
        Ok(file_raw) => parse_config_file(&file_raw, fan_count)?,
        Err(err) if err.kind() == ErrorKind::NotFound => generate_config_file(fan_count)?,
        Err(err) => return Err(Error::ConfigRead(err)),
    };

    let fans = fan_paths
        .into_iter()
        .zip(configs)
        .map(|(path, config)| FanController::new(path, config))
        .collect::<Result<_>>()?;

    Ok(NonEmptyVec::from_vec(fans).unwrap())
}
