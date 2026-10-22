# Spectrogram 

Instantaneous Spectrum Analser
Built for the Tang Nano 20K FPGA development board. 

Work in Progress

## Running

**Flash to Tang Nano 20K**
  ```bash
  # flash volatile sram memory
  make flash-sram
  # flash nonvolatile memory
  make flash
  ```

**run isolated builds**
```bash
~/oss-cad-suite/bin/yosys -p "read_verilog -sv src/[FILE_NAME].sv"
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

## Notes

- **Pixel Clock** 74.25 MHz (for 1280×720 @ 60 Hz HDMI video)
- **Serial Clock** 371.25 MHz (5× DDR for 10:1 TMDS bit serialization)

## Source Files

**Clocking and Reset:**
- `src/pll_pixel.sv` 
- `src/reset_sync.sv` 
- `src/cdc_sync.sv` 

**Video Pipeline:**
- `src/video_sync.sv` 
- `src/tmds_encoder.sv` 
- `src/hdmi_tx.sv` 

**Top Level:**
- `src/top.sv` 


1280 x 720 = 201 600
Xbits: 2^11 = 2047 
Ybits: Xbits for consitency
