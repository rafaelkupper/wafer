# Power budget

The station must survive ten sunless days on a single 18650 cell. This page tracks whether it still does.

## Daily energy

| Consumer | Average current | Per day |
| --- | --- | --- |
| MCU sleep | 4 µA | 0.10 mAh |
| Sampling | 17 µA | 0.41 mAh |
| Radio | 76 µA | 1.82 mAh |
| Regulator loss | 9 µA | 0.22 mAh |
| **Total** | **106 µA** | **2.55 mAh** |

A 3000 mAh cell derated to 60 % for cold gives roughly 700 days without sun, far beyond the ten-day target.

## Open items

- [x] Measure sleep current on revision 3 boards
- [x] Move the radio to spreading factor 9
- [ ] Characterize the solar panel under snow cover
- [ ] Add a brown-out counter to the uplink frame

Timing figures come from the [[Sampling Loop]]. Field results are in [[2026-10-04 Ridge Install]].
