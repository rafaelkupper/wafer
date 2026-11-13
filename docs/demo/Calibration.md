# Calibration

Raw sensor values are not readings. This note records the math that turns one into the other, as implemented in the [[Sampling Loop]].

## Dew point

Kestrel uses the Magnus approximation. With temperature *T* in °C and relative humidity *RH* in percent:

```math
\gamma(T, RH) = \ln\!\left(\frac{RH}{100}\right) + \frac{b\,T}{c + T}
\quad
T_{dp} = \frac{c\,\gamma(T, RH)}{b - \gamma(T, RH)}
```

The constants are *b* = 17.62 and *c* = 243.12 °C, valid from -45 to 60 °C.

## Smoothing

Wind is noisy, so each channel runs through an exponential moving average before it is reported:

```math
s_t = \alpha\,x_t + (1 - \alpha)\,s_{t-1},
\quad
\alpha = 1 - e^{-\Delta t / \tau}
```

| Channel | Time constant τ | α at 10 s |
| --- | --- | --- |
| Temperature | 60 s | 0.154 |
| Humidity | 60 s | 0.154 |
| Pressure | 300 s | 0.033 |
| Wind speed | 20 s | 0.393 |

> [!WARNING]
> Recalibrate after any firmware change that touches the ADC reference. A 1 % reference drift shifts temperature by about 0.3 °C.

## Sea level pressure

Stations report absolute pressure. Dashboards reduce it to sea level with the barometric formula:

```math
p_0 = p \left(1 - \frac{0.0065\,h}{T + 0.0065\,h + 273.15}\right)^{-5.257}
```

See [[Architecture]] for where this runs.
