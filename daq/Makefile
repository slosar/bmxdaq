#
# Settings mak include things that you might need to make it work,
# eg gcc and NVCC settings, if you want to override
#
GCC=g++
NVCC=nvcc
GCCOPT=-Ofast -Wno-format-security -O3 -std=c++11 -Wno-write-strings -Wno-format-overflow -Wno-format
CUDAOPT=-O3 -std=c++11
FFTWLINK=-lfftw3f
#SPCM DIR (to be set in settings.mak)
#SPCM_DIR= /path/to/spcm/
#SPCMLINK
SPCM_DIR=/opt/spcm
SPCM_LINK=-lspcm
-include settings.mak
SPCM_INCLUDE=-I$(SPCM_DIR)
SPCM_OBJ=$(SPCM_DIR)/spcm_examples/c_cpp//common/ostools/spcm_ostools_linux.o
LJLINK=-lLabJackM

HEADERFILES=settings.h digicard.h digicardalloc.h gpucard.h UDPCommunication.h writer.h terminal.h freqgen.h rs232.h reduction.h ljack.h ringbuffer.h
SOURCES=main.cpp settings.cpp digicard.cpp UDPCommunication.cpp writer.cpp writer_rfi.cpp terminal.cpp freqgen.cpp rs232.cpp ljack.cpp ringbuffer.cpp
CUDASOURCES=digicardalloc.cu gpucard.cu reduction.cu 
OBJS=$(SOURCES:.cpp=.o) $(CUDASOURCES:.cu=.o) 


all: daq.out

%.o: %.cpp $(HEADER_FILES)
	$(GCC) $(GCCOPT) $(SPCM_INCLUDE) -c -o $@ $<

%.o: %.c $(HEADER_FILES)
	$(GCC) $(GCCOPT) $(SPCM_INCLUDE) -c -o $@ $<

%.o: %.cu $(HEADER_FILES)
	$(NVCC) $(CUDAOPT) -c $(SPCM_INCLUDE) -o $@ $<

daq.out: $(OBJS)
	$(NVCC) -o $@ $(OBJS) -L. -lm -lcufft $(SPCM_OBJ) $(SPCM_LINK) $(LJLINK)

clean:
	rm *.o
