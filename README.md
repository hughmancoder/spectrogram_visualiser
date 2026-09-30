# Spectrogram Visualiser (Tang Nano 20K)

FPGA project targeting the **Sipeed Tang Nano 20K** development board 

## Quick Start Guide

Check Toolchain Status


```bash
make check-tools
```

Install OSS CAD Suite 
Run the automated installer target to download and extract the prebuilt macOS suite into `~/oss-cad-suite`:

```bash
make setup-toolchain
```

## Running

**Flash to Tang Nano 20K**
  ```bash
  # flash volatile sram memory
  make flash-sram
  # flash nonvolatile memory
  make flash
  ```

**Clean Build Files**
```bash
make clean
```


