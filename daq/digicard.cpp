#include "settings.h"
#include "digicard.h"
#include "digicardalloc.h"
#include "gpucard.h"
#include "terminal.h"
#include "freqgen.h"

// ----- include standard driver header from library -----
#include "spcm_examples/c_cpp/common/ostools/spcm_oswrap.h"
#include "spcm_examples/c_cpp/common/ostools/spcm_ostools.h"


// ----- standard c include files -----
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <math.h>

#include <algorithm>
#include <chrono>
#include <signal.h>
#include <unistd.h>

/* Ctrl+C hander */

volatile sig_atomic_t stopSignal = 0;

void loop_signal_handler(int sig){ // can be called asynchronously
  stopSignal=1;
}


/*
**************************************************************************
szTypeToName: doing name translation
**************************************************************************
*/


char* szTypeToName (int32 lCardType)
    {
    static char szName[50];
    switch (lCardType & TYP_SERIESMASK)
        {
        case TYP_M2ISERIES:     sprintf (szName, "M2i.%04x", (unsigned int) (lCardType & TYP_VERSIONMASK));      break;
        case TYP_M2IEXPSERIES:  sprintf (szName, "M2i.%04x-Exp", (unsigned int) (lCardType & TYP_VERSIONMASK));  break;
        case TYP_M3ISERIES:     sprintf (szName, "M3i.%04x", (unsigned int) (lCardType & TYP_VERSIONMASK));      break;
        case TYP_M3IEXPSERIES:  sprintf (szName, "M3i.%04x-Exp", (unsigned int) (lCardType & TYP_VERSIONMASK));  break;
        case TYP_M4IEXPSERIES:  sprintf (szName, "M4i.%04x-x8", (unsigned int) (lCardType & TYP_VERSIONMASK));   break;
        case TYP_M4XEXPSERIES:  sprintf (szName, "M4x.%04x-x4", (unsigned int) (lCardType & TYP_VERSIONMASK));   break;
        default:                sprintf (szName, "unknown type");                               break;
        }
    return szName;
    }



void printErrorDie(const char* message, DIGICARD *card,  SETTINGS *set) {
      char szErrorTextBuffer[ERRORTEXTLEN];
      spcm_dwGetErrorInfo_i32 (card->hCard, NULL, NULL, szErrorTextBuffer);
      printf ("Digitizer card fatal error: %s\n",message);
      printf ("Error Text: %s\n", szErrorTextBuffer);
      digiCardCleanUp(card, set);
      exit(1);
}


/*
**************************************************************************
Setup the digitizer card
**************************************************************************
*/


void digiCardInit (DIGICARD *card, SETTINGS *set) {
  // open card

  printf ("\n\nInitializing digitizer\n");
  printf ("==========================\n");

  if (!set->simulate_digitizer) {
  card->hCard = spcm_hOpen ((char*)"/dev/spcm1");
  if (!card->hCard) printErrorDie("Can't open digitizer card.",card,set);
  
  int32       lCardType, lSerialNumber, lFncType;
  // read type, function and sn and check for A/D card
  spcm_dwGetParam_i32 (card->hCard, SPC_PCITYP,         &lCardType);
  spcm_dwGetParam_i32 (card->hCard, SPC_PCISERIALNO,    &lSerialNumber);
  spcm_dwGetParam_i32 (card->hCard, SPC_FNCTYPE,        &lFncType);

  switch (lFncType)
    {
    case SPCM_TYPE_AI:  
      printf ("Found: %s sn %05d\n", szTypeToName (lCardType), lSerialNumber);
      break;

    default:
      printf ("Card: %s sn %05d not supported. \n", szTypeToName (lCardType), lSerialNumber);            
      exit(1);
    }


  // do a simple standard setup
  // always do two channels
  spcm_dwSetParam_i32 (card->hCard, SPC_CHENABLE,       set->channel_mask);                     // just 1 channel enabled
  spcm_dwSetParam_i32 (card->hCard, SPC_PRETRIGGER,     1024);                  // 1k of pretrigger data at start of FIFO mode
  spcm_dwSetParam_i32 (card->hCard, SPC_CARDMODE,       SPC_REC_FIFO_SINGLE);   // single FIFO mode
  spcm_dwSetParam_i32 (card->hCard, SPC_TIMEOUT,        5000);                 // timeout 5 s
  spcm_dwSetParam_i32 (card->hCard, SPC_TRIG_ORMASK,    SPC_TMASK_SOFTWARE);    // trigger set to software
  spcm_dwSetParam_i32 (card->hCard, SPC_TRIG_ANDMASK,   0);                     // ...
  if (set->ext_clock_mode) 
    spcm_dwSetParam_i32 (card->hCard, SPC_CLOCKMODE,      SPC_CM_EXTREFCLOCK);
  else
    spcm_dwSetParam_i32 (card->hCard, SPC_CLOCKMODE,      SPC_CM_INTPLL);         // clock mode internal PLL

  spcm_dwSetParam_i64 (card->hCard, SPC_REFERENCECLOCK, set->spc_sample_rate);
  spcm_dwSetParam_i64 (card->hCard, SPC_SAMPLERATE, set->spc_ref_clock);

  spcm_dwSetParam_i32 (card->hCard, SPC_CLOCKOUT,       0);                     // no clock output

  spcm_dwSetParam_i32 (card->hCard, SPC_AMP0,  set->ADC_range  );
  spcm_dwSetParam_i32 (card->hCard, SPC_AMP1,  set->ADC_range  );
  int32_t range1, range2;
  spcm_dwGetParam_i32 (card->hCard, SPC_AMP0,  &range1 );
  spcm_dwGetParam_i32 (card->hCard, SPC_AMP1,  &range2 );
  printf ("ADC ranges for CH1/2: %i/%i mV\n",range1,range2);
  long long int srate;
  spcm_dwGetParam_i64 (card->hCard, SPC_SAMPLERATE, &srate);
  printf ("Sampling rate set to %.1lf MHz\n", srate/1000000.);
  } else {
    printf ("**Not using real card, simulating...**\n");
  }

  printf ("Allocating digitizer buffer...\n");
  /// now set the memory
  card->two_channel = (set->channel_mask==3);
  card->lNotifySize = set->fft_size*(1+card->two_channel);
  card->lBufferSize = card->lNotifySize*set->buf_mult;
    
  /// alocate buffer
  digiCardAlloc(card->pnData, card->lBufferSize);
  if (!card->pnData)
    {
      printf ("memory allocation failed\n");
      spcm_vClose (card->hCard);
      exit(1);
    }

  if (!set->simulate_digitizer) {
  // define transfer
  spcm_dwDefTransfer_i64 (card->hCard, SPCM_BUF_DATA, SPCM_DIR_CARDTOPC,
			  card->lNotifySize, card->pnData, 0, card->lBufferSize);
  } else {
    // Filling buffer
    printf ("Filling Fake buffer...\n");
    int8_t * sh = (int8_t *)malloc(set->fft_size);
    //int8_t ch1lu[64], ch2lu[64];
    /*for(int i=0; i<64; i++) {
      ch1lu[i]=-1;//int(20*cos(2*2*M_PI*i/64)+10*sin(2*M_PI*i/64));
      ch2lu[i]=-i;//31+i;
    }*/

    for(int32_t i =0; i < set->fft_size/2; i++){
	sh[i] = 0;
	sh[set->fft_size/2 + i] = 127; 
    }

    unsigned seed = std::chrono::system_clock::now().time_since_epoch().count();
    shuffle (sh, sh + set->fft_size, std::default_random_engine(seed));
    for( int i =0; i < 20; i++){
	printf("%d ", sh[i]);
    }
    int i=0;
    int32_t s=card->lBufferSize;
    int8_t *data=(int8_t*) card->pnData;
    printf ("buffer size=%i\n",s);
    /*for (int32_t k=0; k<s-1; k+=2) {
      data[k]=ch1lu[i];
      data[k+1]=ch2lu[i];
      i+=1;
      if (i==64) i=0;
    }*/
    for(int32_t k =0; k<s-1; k+=2){
	data[k] = sh[i];
	i+=1;
	if (i==set->fft_size) i=0;
    }

    seed = std::chrono::system_clock::now().time_since_epoch().count();
    shuffle (sh, sh + set->fft_size, std::default_random_engine(seed));
    

    for(int32_t k =0; k<s-1; k+=2){
	data[k+1] = sh[i];
	i+=1;
	if (i==set->fft_size) i=0;
    }


  }
 
  printf ("Digitizer card and buffer ready.\n");

}

float deltaT (timespec t1,timespec t2) {
  return ( t2.tv_sec - t1.tv_sec )
	  + ( t2.tv_nsec - t1.tv_nsec )/ 1e9;
}

void  digiWorkLoop(DIGICARD *dc, GPUCARD *gc, SETTINGS *set, FREQGEN *fgen, LJACK *lj,
		   WRITER *w, TWRITER *t, RFI *rfi) {


  printf ("\n\nStarting main loop\n");
  printf ("==========================\n");
  
  uint32      dwError;
  int32       lStatus, lAvailUser, lPCPos, fill;
  int stream; //which stream was used to proccess data
  int8_t * bufstart;

  // start everything
  dwError = set->simulate_digitizer ? ERR_OK :
    spcm_dwSetParam_i32 (dc->hCard, SPC_M2CMD, M2CMD_CARD_START | 
		   M2CMD_CARD_ENABLETRIGGER | M2CMD_DATA_STARTDMA);


  // check for error
  if (dwError != ERR_OK) printErrorDie("Cannot start FIFO\n",dc,set);

  struct timespec timeStart, timeNow, tSim, t1;
  int sim_ofs=0;
  clock_gettime(CLOCK_REALTIME, &timeStart);
  tSim=timeStart;
  fill=69;
  float towait=set->fft_size/set->sample_rate;
  long int sample_count=0;
  signal(SIGINT, loop_signal_handler);

  // terminal writer init
  terminalWriterInit(t, set->print_every);

  while (!stopSignal) {
    clock_gettime(CLOCK_REALTIME, &t1);
    float dt=deltaT(tSim,t1);
    if (set->simulate_digitizer) {
      lPCPos = dc->lNotifySize*sim_ofs;
      sim_ofs = (sim_ofs+1)%set->buf_mult;
      lAvailUser=dc->lNotifySize;
      if (deltaT(tSim,t1)>towait) {
	fill+=30;
      } else {
	do {
	  clock_gettime(CLOCK_REALTIME, &t1);
	  if (fill>69) fill-=30;
	} while (deltaT(tSim,t1)<towait);
      }
    } else {
      dwError = spcm_dwSetParam_i32 (dc->hCard, SPC_M2CMD, M2CMD_DATA_WAITDMA);
      if (dwError != ERR_OK)
	printErrorDie ("DMA wait fail\n",dc,set);
      spcm_dwGetParam_i32 (dc->hCard, SPC_M2STATUS,             &lStatus);
      spcm_dwGetParam_i32 (dc->hCard, SPC_DATA_AVAIL_USER_LEN,  &lAvailUser);
      spcm_dwGetParam_i32 (dc->hCard, SPC_DATA_AVAIL_USER_POS,  &lPCPos);
      spcm_dwGetParam_i32 (dc->hCard, SPC_FILLSIZEPROMILLE,  &fill);
    }
    t1=tSim;
    clock_gettime(CLOCK_REALTIME, &tSim);
    float dtDigi=deltaT(t1,tSim); //time for digicard to return a packet
    if (lAvailUser >= dc->lNotifySize)
      {
	clock_gettime(CLOCK_REALTIME, &timeNow);
	double accum = deltaT(timeStart, timeNow);

	bufstart=((int8_t*)dc->pnData+lPCPos);
	if (set->dont_process) 
	  printf (" ** no GPU processing");
	else{
	    stream = gpuProcessBuffer(gc,bufstart, w, t, rfi, set);
            tprintfn(t, 1, " ");
	    tprintfn(t, 1, "Cycle statistics, Last Stream: %i    ",stream);
	    tprintfn (t, 1, "Cycle taking %5.3fs, hope for < %5.3fs",dt, towait);
            tprintfn (t, 1, "Measured dt: %3.1f ms, rate=%4.1f MHz",dtDigi*1e3, set->fft_size/dtDigi/1e6);
	    tprintfn(t, 1, "Time: %6.2fs; Status:%i; Pos:%08x; digitizer buffer fill %i/1000   ", 
	       accum, lStatus, lPCPos,fill);
	}

	// tell driver we're done
	if (!set->simulate_digitizer)
	  spcm_dwSetParam_i32 (dc->hCard, SPC_DATA_AVAIL_CARD_LEN, dc->lNotifySize);
      
	// drive frequency generator if needed
	if (set->fg_nfreq) freqGenLoop(fgen, w, t);
	// drive labjack
	if (set->lj_Non) LJLoop(lj,w, t);

  // write waveform if requested
	struct timespec begin, end;
        clock_gettime(CLOCK_REALTIME, &begin);
	if (set->wave_nbytes>0) {
	  FILE *fw=fopen(set->wave_fname,"wb");
	  if (fw!=NULL) {
	    fwrite(bufstart,sizeof(int8_t),set->wave_nbytes,fw);
	    fclose(fw);
	  }
	}
	clock_gettime(CLOCK_REALTIME, &end);
	//tprintfn(t, 1, "time to print waveform: %f", deltaT(begin, end));
	// break if sufficient number of samples
	if ((++sample_count) == set->nsamples) break;
      }
    tflush(t);
  }   

  terminalWriterCleanup(t);
  
  printf("\n\n\n\n\n\n\n\n\n");
  if (stopSignal) printf ("Ctrl-C detected. Stopping.\n");
  if (sample_count==set->nsamples) printf ("Reached required number of samples.\n");
  //Write last digitizer bufer to a file 
  if(set->print_last_buffer){
  	printf("Printing last digitizer buffer to a file...\n");
  	writerWriteLastBuffer(w, bufstart,dc->lNotifySize);
  }
  printf ("Stoping digitizer FIFO...\n");
  // send the stop command
  dwError = set->simulate_digitizer ? ERR_OK :
    spcm_dwSetParam_i32 (dc->hCard, SPC_M2CMD, M2CMD_CARD_STOP | 
			 M2CMD_DATA_STOPDMA);
  if (dwError != ERR_OK) printErrorDie("Error stopping card.\n",dc,set);
}


void digiCardCleanUp(DIGICARD *card, SETTINGS *set) {
  printf ("Closing digitizer... \n");
  digiCardFree(card->pnData);
  if (!set->simulate_digitizer) spcm_vClose (card->hCard);
}
