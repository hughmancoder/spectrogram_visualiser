# Spectrogram Visualiser 

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

**Clocks**
System has two clocks running at different frequencies: 
system lock: 64.8 MHz, needed for SDRAM
Display clock (pix_clk): 74.25 MHz for HDMI protocol

A full 1280×720 frame at 16-bit colour (RGB565) is 1280 × 720 × 2 bytes ≈ 1.84 MB. The Tang Nano 20K only has ~82 KB of internal Block SRAM (BSRAM), so the 8Mb of avialable SDRAM will can be used to store fft frames.


## Design

**clk/**
- `pll_pixel.sv`
- `pll_sys.sv`

**clock domain crossing/**
- `cdc_sync.sv`
- `reset_sync.sv`

**video/**
- `fb_pkg.sv`
- `hdmi_tx.sv`
- `pattern_gen.sv`
- `tmds_encoder.sv`
- `video_sync.sv`

**top/**
- `top.sv`