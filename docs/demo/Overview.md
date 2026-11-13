---
title: Kestrel weather station
status: field trial
revision: 3
---

# Kestrel weather station

Kestrel is a solar-powered weather station built for ridgelines where nobody wants to change a battery. It samples every ten seconds, sleeps the rest of the time, and reports over LoRa once a minute.

> [!TIP]
> New here? Start with the [[Architecture]] tour, then read [[Calibration]] before trusting a single number.

## What it measures

| Sensor | Quantity | Range | Accuracy |
| --- | --- | --- | --- |
| SHT45 | Temperature | -40 to 125 °C | ±0.1 °C |
| SHT45 | Relative humidity | 0 to 100 % | ±1.0 % |
| BMP390 | Pressure | 300 to 1250 hPa | ±0.03 hPa |
| Davis 6410 | Wind speed | 0.5 to 89 m/s | ±5 % |

## Reading a sample

Every reading passes through the same small pipeline: sample, compensate, smooth, then queue for the radio. The ==whole loop fits in 4 kB of RAM==.

```rust
/// One pass of the sampling loop. Runs every ten seconds.
fn sample(station: &mut Station) -> Result<Reading, SensorError> {
    let raw = station.sensors.read_all()?;
    let reading = Reading {
        temperature: compensate(raw.temperature, &station.calibration),
        humidity: raw.humidity.clamp(0.0, 100.0),
        pressure: raw.pressure,
        dew_point: dew_point(raw.temperature, raw.humidity),
    };
    station.filter.push(reading);
    Ok(station.filter.smoothed())
}
```

## Where to go next

- [[Architecture]] shows how a sample travels from sensor to dashboard.
- [[Calibration]] covers the dew point and smoothing math.
- [[Sampling Loop]] and [[Power Budget]] document the firmware.
- The [[2026-10-04 Ridge Install]] entry records the first field deployment.

> [!NOTE]
> Station time is always UTC. Dashboards convert to local time on display[^utc].

[^utc]: Storing local time breaks twice a year. Storing UTC never does.
