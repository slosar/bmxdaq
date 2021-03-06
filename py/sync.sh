#!/usr/bin/env bash

for i in $(seq 1 $1); do
  path=/home/hindy/bmxdaq
  rm $path/data/sync/*
  $path/daq/./daq.out $path/daq/sync.ini
  f=$(ls -Art $path/data/sync/ | tail -n 1) 
  $path/py/./sync_test.py --f $path/data/sync/$f  --delays $path/py/$2 --peaks1 $path/py/$3 --peaks2 $path/py/$4 --nsamples 4
done
