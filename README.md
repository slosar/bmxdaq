# bmxdaq

Streams data from Signal M4 digitizer cards into CUDA capable GPUs, performs full FFTs, power and cross-spectrum calculation, averaging and excision and saves reduced stream to disk. 

# Compile

Go to `bmxdaq/src`, change settings.mak, make

# Run

Set up an ini file. Take `default.ini` as an example, also copied below

```
## sampling rate in Msamples/second
sample_rate= 1100
## do we supply this externally
ext_clock_mode= 1
## what we tell the digi card
## software will do internal conversions
## based on sample_rate above
## Don't change things below, unless you
## know what are you doing.
spc_sample_rate= 1250
spc_ref_clock= 1250

## FFT size = 2**FFT_power.
## this also sets the output rate
FFT_power= 27
## We allocate memory for this many FFT size array
buf_mult= 2

## number of cuts
## each cut is a separate averaging of spectra
## They can be overlapping, etc.
n_cuts= 2
## min and max frequency in Mhz, -1 sets max to Nyquist
## Since 16384=2^14, we get 2^{27-14-1}=4096 channels.
## (minus 1 because number of freq is # samples/2)
nu_min0= 0.
nu_max0= -1 
fft_avg0= 16384;
## Second cut catches tone around 1GHz
nu_min1= 1399.9950
nu_max1= 1400.0050
fft_avg1= 1;

## CUDA settings, don't touch unless you know
## what you are doung
cuda_streams= 1
cuda_threads= 1024
## Channel mask 1 = CH1, 2 = CH1, 3 = CH1+CH2 
## (note that single channel taking hasn't really been tested)
channel_mask= 3

## ADC range in mV
## possible values: 200,500,1000,2500
ADC_range= 200

## If one, don't acutally run the digitizer
simulate_digitizer= 0
## If one, don't run the GPU
dont_process= 0

## We open a new file every this many minutes
## (execept the first one, for 60 we open so that 
## mins==0)
save_every= 60
## output patter will save this YYMMDD_HHMM.data
output_pattern= ../data/%02d%02d%02d_%02d%02d.data

## interactive output 

# print mean and variance
print_meanvar= 1
# print max power freq for each channel
print_maxp= 1

## tone frequency generation
## if >0 it will try
## to drive the tone generator
fg_nfreq= 0
## port baud rate for talking to FG
fg_port= ttyS0
fg_baudrate= 115200
## switch every this many packets (determined by FFTSIZE and sampling
## rate)
fg_switchevery= 10
## frequencies 0..fg_nfreq-1
fg_freq0= 1200
fg_freq1= 1400
fg_freq2= 1500
## amplitudes in Vpp
fg_ampl0= 0.2
fg_ampl1= 0.2
fg_ampl2= 0.2
```

