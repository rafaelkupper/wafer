# Architecture

A reading takes four hops from the sensor to a chart. Each hop can fail on its own, so every stage buffers what it cannot yet deliver.

## Data flow

```mermaid
flowchart LR
    subgraph Station
        direction LR
        S[Sensors] -->|I2C| M(MCU)
        M --> R{{LoRa radio}}
    end
    subgraph Hut
        direction LR
        G[Gateway] -->|MQTT| B[(Database)]
        B --> D[Dashboard]
    end
    Station -.->|915 MHz| Hut
```

## Uplink sequence

```mermaid
sequenceDiagram
    participant St as Station
    participant Gw as Gateway
    participant Db as Database
    St->>Gw: Frame 1042 (6 readings)
    Gw->>Db: Insert batch
    Db-->>Gw: OK
    Gw-->>St: ACK + clock sync
    Note over St: Back to sleep for 58 s
```

## Design rules

1. **Never block on the radio.** Frames queue in flash until the gateway acknowledges them.
2. **Compensate on the device.** Raw values never leave the station, so every consumer sees the same numbers. See [[Calibration]].
3. **Sleep is the default state.** The [[Power Budget]] only works if the MCU is awake less than 2 % of the time.

> [!IMPORTANT]
> The gateway is the only component with a network connection. Stations are radio-only by design.

Back to the [[Overview]].
