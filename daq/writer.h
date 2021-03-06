#pragma once
#include "terminal.h"
#include "settings.h"
#include "stdio.h"
#include <stdint.h>
#include <thread>


// character lengths
#define MAXFNLEN 512
// version of BMXHEADER structure to implement
// in python readers, etc.
// CHANGES:
//     v2 -- save float with cur tone freq every time you save
//     v3 -- save MJD double
//     v4 -- save labjack voltage float and diode
//     v5 -- changed localtime to gmtime in filename -- header hasn't changed
//     v6 -- two digitizers 
//     v7 -- delays in header
//     v8 -- ??
//     v9 -- added record num in header -- a basic counter since recording started.
//     v10 -- saving 4 voltages + temperatures
#define HEADERVERSION 10
#define RFIHEADERVERSION 2

struct BMXHEADER {
  const char magic[8]=">>BMX<<"; // magic header char to recogize files *BMX*
  int version=HEADERVERSION;
  int daqNum;
  char wires[8]; // whcih wires go where from captain sailor, etc 
  int cardMask;
  int nChannels;
  float sample_rate;
  uint32_t fft_size; 
  uint32_t average_recs;
  int ncuts;
  float nu_min[MAXCUTS], nu_max[MAXCUTS];
  uint32_t fft_avg[MAXCUTS];
  int pssize[MAXCUTS];
  int bufdelay[2];
  int delay[2];
  uint32_t rec_num;
};

struct RFIHEADER {
  const char magic[8]=">>RFI2<";
  int version=RFIHEADERVERSION;
  float nSigma;    //number of sigma away from mean
};

struct auxinfo {
  int lj_diode;
  float temp_fgpa[2];
  float temp_adc[2];
  float temp_frontend[2];
  float lj_voltage[4];
};

struct WRITER {
  bool enabled;
  uint32_t sample_counter; 
  char fnamePS[MAXFNLEN], fnameRFI[MAXFNLEN]; //file names, from settings
  char afnamePS[MAXFNLEN], afnameRFI[MAXFNLEN];  //current file names
  char tafnamePS[MAXFNLEN], tafnameRFI[MAXFNLEN];  //temporary current file names //(with ".new")
  bool rfiOn;
  uint32_t lenPS; // full length of PS info
  uint32_t lenRFI; //length of outlier chunk
  int new_file_every; // how many minutes we save.
  int average_recs; // how many records to average over
  int rfi_sigma;
  int crec;
  bool totick, writing;
  std::thread savethread;
  float *psbuftick, *psbuftock, *cleanps, *badps;
  int ctemp_fgpa[2], ctemp_adc[2], ctemp_frontend[2];
  int lj_diode;
  auxinfo auxtick, auxtock;
  int *numbad;
  float fbad; //fraction bad last time
  
 
  FILE* fPS, *fRFI;
  bool reopen;
  BMXHEADER headerPS;  //header for power spectra files
  RFIHEADER headerRFI; //header for rfi files
  float tone_freq;
  float lj_voltage[4];
};



void writerInit(WRITER *writer, SETTINGS *set);

float rfimean (float arr[], int n, int nsigma, float *cleanmean, float *outliermean, int *numbad);

void zeroaux (auxinfo *aux);
void auxadd (auxinfo *aux, WRITER *writer);
void auxmean (auxinfo *aux, int nrec);

void writerWritePS (WRITER *writer, float* ps, auxinfo *aux, SETTINGS *set);
void writerWriteRFI (WRITER *writer, float* ps, int* numbad, int totbad);

void writerAccumulatePS (WRITER *writer, float* ps, TWRITER *twr, SETTINGS *set);

void enableWriter(WRITER *wr, SETTINGS *set);
void disableWriter(WRITER *wr);




void writerCleanUp(WRITER *writer);

void closeAndRename(WRITER *writer);

