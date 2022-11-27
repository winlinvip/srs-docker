#------------------------------------------------------------------------------------
#--------------------------build-----------------------------------------------------
#------------------------------------------------------------------------------------
FROM centos:7 as build

ARG JOBS=2
RUN echo "JOBS: $JOBS"

RUN yum install -y gcc gcc-c++ make patch sudo unzip perl zlib automake libtool \
    zlib-devel bzip2 bzip2-devel tcl

# Libs path for app which depends on ssl, such as libsrt.
ENV PKG_CONFIG_PATH=$PKG_CONFIG_PATH:/usr/local/ssl/lib/pkgconfig

# Libs path for FFmpeg(depends on serval libs), or it fail with:
#       ERROR: speex not found using pkg-config
ENV PKG_CONFIG_PATH=$PKG_CONFIG_PATH:/usr/local/lib/pkgconfig:/usr/local/lib64/pkgconfig

# Openssl 1.1.* for SRS.
ADD openssl-1.1.1j.tar.bz2 /tmp
RUN cd /tmp/openssl-1.1.1j && \
   ./config -no-shared -no-threads --prefix=/usr/local/ssl && make -j${JOBS} && make install_sw

# Openssl 1.0.* for SRS.
#ADD openssl-OpenSSL_1_0_2u.tar.gz /tmp
#RUN cd /tmp/openssl-OpenSSL_1_0_2u && \
#    ./config -no-shared -no-threads --prefix=/usr/local/ssl && make -j${JOBS} && make install_sw

# Build cmake for openssl, libsrt and libx265.
ADD CMake-3.22.5.tar.gz /tmp
RUN cd /tmp/CMake-3.22.5 && ./bootstrap && make -j${JOBS} && make install
ENV PATH=$PATH:/usr/local/bin

# For FFMPEG
ADD nasm-2.14.tar.bz2 /tmp
RUN cd /tmp/nasm-2.14 && ./configure && make -j${JOBS} && make install
# For aac
ADD fdk-aac-2.0.2.tar.gz /tmp
RUN cd /tmp/fdk-aac-2.0.2 && bash autogen.sh && ./configure --disable-shared && make -j${JOBS} && make install
# For mp3, see https://sourceforge.net/projects/lame/
ADD lame-3.100.tar.gz /tmp
RUN cd /tmp/lame-3.100 && ./configure --disable-shared && make -j${JOBS} && make install
# For libx264
ADD x264-snapshot-20181116-2245.tar.bz2 /tmp
RUN cd /tmp/x264-snapshot-20181116-2245 && ./configure --disable-cli --disable-shared --enable-static && make -j${JOBS} && make install
# The libsrt for SRS, which depends on openssl and cmake.
ADD srt-1.4.1.tar.gz /tmp
RUN cd /tmp/srt-1.4.1 && ./configure --disable-shared --enable-static && make -j${JOBS} && make install
# For libxml2.
RUN yum install -y python-devel
ADD libxml2-2.9.12.tar.gz /tmp
RUN cd /tmp/libxml2-2.9.12 && ./autogen.sh && ./configure --disable-shared --enable-static && make -j${JOBS} && make install

# Build FFmpeg, static link libraries.
ADD ffmpeg-4.2.1.tar.bz2 /tmp
RUN cd /tmp/ffmpeg-4.2.1 && ./configure --enable-pthreads --extra-libs=-lpthread \
        --enable-gpl --enable-nonfree \
        --enable-postproc --enable-bzlib --enable-zlib \
        --enable-libx264 --enable-libmp3lame --enable-libfdk-aac \
        --enable-libxml2 --enable-demuxer=dash \
        --enable-libsrt --pkg-config-flags='--static' && \
	make -j${JOBS} && make install && echo "FFMPEG4 build and install successfully"
RUN cp /usr/local/bin/ffmpeg /usr/local/bin/ffmpeg4

# For libx265. Note that we force to generate the x265.pc by replace X265_LATEST_TAG.
#     if(X265_LATEST_TAG)
#         configure_file("x265.pc.in" "x265.pc" @ONLY)
ADD x265-3.5_RC2.tar.bz2 /tmp
RUN cd /tmp/x265-3.5_RC2/build/linux && \
    sed -i 's/^if(X265_LATEST_TAG)/if(TRUE)/g' ../../source/CMakeLists.txt && \
    cmake -DENABLE_SHARED=OFF ../../source && make -j${JOBS} && make install

# Build FFmpeg, static link libraries.
ADD ffmpeg-5.0.2.tar.bz2 /tmp
RUN cd /tmp/ffmpeg-5.0.2 && ./configure --enable-pthreads --extra-libs=-lpthread \
        --pkg-config-flags='--static' \
        --enable-gpl --enable-nonfree \
        --enable-postproc --enable-bzlib --enable-zlib \
        --enable-libx264 --enable-libx265 --enable-libmp3lame --enable-libfdk-aac \
        --enable-libxml2 --enable-demuxer=dash \
        --enable-libsrt && \
    make -j${JOBS} && make install && echo "FFMPEG5 build and install successfully"
RUN cp /usr/local/bin/ffmpeg /usr/local/bin/ffmpeg5

# Build FFmpeg, static link libraries.
ADD ffmpeg_rtmp_h265-5.0.tar.bz2 /tmp
RUN cp -f /tmp/ffmpeg_rtmp_h265-5.0/*.h /tmp/ffmpeg_rtmp_h265-5.0/*.c /tmp/ffmpeg-5.0.2/libavformat
RUN cd /tmp/ffmpeg-5.0.2 && ./configure --enable-pthreads --extra-libs=-lpthread \
        --pkg-config-flags='--static' \
        --enable-gpl --enable-nonfree \
        --enable-postproc --enable-bzlib --enable-zlib \
        --enable-libx264 --enable-libx265 --enable-libmp3lame --enable-libfdk-aac \
        --enable-libxml2 --enable-demuxer=dash \
        --enable-libsrt && \
    make -j${JOBS} && make install && echo "FFMPEG5(HEVC over RTMP) build and install successfully"
RUN cp /usr/local/bin/ffmpeg /usr/local/bin/ffmpeg5-hevc-over-rtmp

#------------------------------------------------------------------------------------
#--------------------------dist------------------------------------------------------
#------------------------------------------------------------------------------------
FROM centos:7 as dist

ARG JOBS=2
ARG NO_GO
RUN echo "NO_GO: $NO_GO, JOBS: $JOBS"

WORKDIR /tmp/srs

# Note that we can't do condional copy, because cmake has bin, docs and share files, so we copy the whole /usr/local
# directory or cmake will fail.
COPY --from=build /usr/local /usr/local
# Note that for armv7, the ffmpeg5-hevc-over-rtmp is actually ffmpeg5.
RUN ln -sf /usr/local/bin/ffmpeg5-hevc-over-rtmp /usr/local/bin/ffmpeg
# Note that the PATH has /usr/local/bin by default in ubuntu:focal.
#ENV PATH=$PATH:/usr/local/bin

# Note that git is very important for codecov to discover the .codecov.yml
RUN yum install -y gcc gcc-c++ make net-tools gdb lsof tree dstat redhat-lsb unzip zip git \
    nasm yasm perf strace sysstat ethtool libtool \
    tcl

# The cmake should be ready in base image. Use hash to clear cache for cmake,
# see https://stackoverflow.com/a/46805870/17679565
RUN hash -r && which cmake && cmake --version

# For GCP/pprof/gperf, see https://winlin.blog.csdn.net/article/details/53503869
RUN yum install -y graphviz

# For https://github.com/google/sanitizers
RUN yum install -y libasan

# Install cherrypy for HTTP hooks.
#ADD CherryPy-3.2.4.tar.gz2 /tmp
#RUN cd /tmp/CherryPy-3.2.4 && python setup.py install

ENV PATH $PATH:/usr/local/go/bin
RUN if [[ -z $NO_GO ]]; then \
      cd /usr/local && \
      curl -L -O https://go.dev/dl/go1.16.12.linux-amd64.tar.gz && \
      tar xf go1.16.12.linux-amd64.tar.gz && \
      rm -f go1.16.12.linux-amd64.tar.gz; \
    fi

# For utest, the gtest.
ADD googletest-release-1.6.0.tar.gz /usr/local
RUN ln -sf /usr/local/googletest-release-1.6.0 /usr/local/gtest

