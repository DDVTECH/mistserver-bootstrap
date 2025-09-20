# syntax=docker/dockerfile:1.6

FROM ubuntu:22.04 AS builder
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       build-essential \
       git \
       python3 \
       python3-pip \
       ninja-build \
       pkg-config \
       libssl-dev \
       libcurl4-openssl-dev \
       libmicrohttpd-dev \
       liblzma-dev \
       libbz2-dev \
       libzstd-dev \
       libxml2-dev \
       libuv1-dev \
       libasio-dev \
       libavcodec-dev \
       libavfilter-dev \
       libavformat-dev \
       libavutil-dev \
       libswscale-dev \
       ca-certificates \
       curl \
    && rm -rf /var/lib/apt/lists/*
RUN python3 -m pip install --no-cache-dir 'meson>=1.3.0'

WORKDIR /src
RUN git clone https://github.com/DDVTECH/mistserver.git mistserver \
    && cd mistserver \
    && git fetch origin development \
    && git checkout development

WORKDIR /src/mistserver
RUN meson setup build --default-library static -DWITH_AV=true \
    && ninja -C build install

FROM ubuntu:22.04 AS runtime
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       ca-certificates \
       curl \
       ffmpeg \
       libavcodec58 \
       libavfilter7 \
       libavformat58 \
       libavutil56 \
       libswresample3 \
       libswscale5 \
       libssl3 \
       libcurl4 \
       libmicrohttpd12 \
       libuv1 \
       libxml2 \
       liblzma5 \
       libbz2-1.0 \
       zlib1g \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /usr/local /usr/local
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

VOLUME ["/video"]
VOLUME ["/var/mist"]

EXPOSE 4242 8080 1935 5554 4200 8889/udp
ENTRYPOINT ["/entrypoint.sh"]
CMD [MistController -c /etc/mistserver.conf]
