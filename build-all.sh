#!/bin/bash

#
# WPSD Repeater FW build script - 2024 Chip Cuccio, W0CHP
#

if [ -d './release' ]; then
    rm -rfv ./release/*
fi

if [ ! -d './release' ]; then
    mkdir ./release
fi

make clean

rm -rfv bin/* release/*

mv Config.h Config.h.dist

# nucleo 64
cp Configs/Config.h.nucleo ./Config.h
make -j$(nproc) nucleo
mv bin/mmdvm_f4.elf release/F446RE.elf
make clean

# nucleo 144
cp Configs/Config.h.nucleo ./Config.h
make -j$(nproc) f767
mv bin/mmdvm_f7.elf release/F767ZI.elf
make clean

# MMDVM_RPT_HAT v0.3 (F0DEI, DB9MAT, DF2ET, et. al)
cp Configs/Config.h.pi ./Config.h
make -j$(nproc) rpt_hat
mv bin/mmdvm_f7.bin release/MMDVM_RPT_Hat_0.3.bin
make clean

# MMDVM_RPT_HAT v0.2 (BG4TGO, BG5HHP et. al)
cp Configs/Config.h.pi ./Config.h
make -j$(nproc) rpt_hat_tgo
mv bin/mmdvm_f4.bin release/MMDVM_RPT_Hat_0.2.bin
make clean

# ZUM MMDVM-Pi v.0.9 (F4)
cp Configs/Config.h.pi-0.9 ./Config.h
make -j$(nproc) pi
mv bin/mmdvm_f4.bin release/ZUM_MMDVM-Pi_0.9-F4.bin
make clean

# ZUM MMDVM-Pi v.1.0 (F4)
cp Configs/Config.h.pi ./Config.h
make -j$(nproc) pi
mv bin/mmdvm_f4.bin release/ZUM_MMDVM-Pi_1.0-F4.bin
make clean

# ZUM MMDVM-Pi v.1.0 (F7)
cp Configs/Config.h.pi ./Config.h
make -j$(nproc) pi-f722
mv bin/mmdvm_f7.bin release/ZUM_MMDVM-Pi_1.0-F7.bin
make clean

# RB v.3
cp Configs/Config.h.rb3 ./Config.h
make -j$(nproc) eda446
mv bin/mmdvm_f4.bin release/Repeater-Builder_v3.bin
make clean

# RB v.4
cp Configs/Config.h.rb4 ./Config.h
make -j$(nproc) dvm
mv bin/mmdvm_f4.bin release/Repeater-Builder_v4.bin
make clean

# RB v.5
cp Configs/Config.h.rb5 ./Config.h
make -j$(nproc) dvm722
mv bin/mmdvm_f7.bin release/Repeater-Builder_v5.bin
make clean

# RB MTR2k v3 446
cp Configs/Config.h.rbMTR2K ./Config.h
make -j$(nproc) eda446
mv bin/mmdvm_f4.bin release/Repeater-Builder_MTR2K_v3-446.bin
make clean

# RB MTR2k v3 405
cp Configs/Config.h.rbMTR2K ./Config.h
make -j$(nproc) eda405
mv bin/mmdvm_f4.bin release/Repeater-Builder_MTR2K_v3-405.bin
make clean

mv Config.h.dist Config.h
