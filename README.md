# Spectrogram Visualiser 

Built for the Tang Nano 20K FPGA development board 

## Running

**Flash to Tang Nano 20K**
  ```bash
  # flash volatile sram memory
  make flash-sram
  # flash nonvolatile memory
  make flash
  ```

**Simulation**
```bash
# Run default top integration test
make sim

# Run a specific testbench 
make sim TB=pll_pixel_tb
make sim TB=sim/top_tb.v

# View simulation waveforms in GTKWave / Surfer
make waves
make waves TB=pll_pixel_tb
```

**Clean Build Files**
```bash
make clean
```

## Set up toolchain

**Check toolchain status**

```bash
make check-tools
```

**Install OSS CAD Suite**

```bash
make setup-toolchain
```

## Microphone (i2c)

SD = Serial Data

MS = Word Select (WS / LRCK) - determines left or right channel

CCK = Serial Clock (SCK / BCLK) - synchronises the bits

L/R = Channel Select (Tie to GND for left, VDD for right)

## Documentation 

Refer to `docs/` folder