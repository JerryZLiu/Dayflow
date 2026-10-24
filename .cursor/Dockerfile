FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      git \
      build-essential \
      binutils \
      gnupg2 \
      unzip \
      pkg-config \
      libsqlite3-dev \
      sqlite3 \
      python3 \
      libcurl4-openssl-dev \
      libpython3-dev \
      libxml2-dev \
      libncurses-dev \
      libz3-dev \
    && rm -rf /var/lib/apt/lists/*

ENV SWIFTLY_HOME_DIR=/opt/swiftly
ENV SWIFTLY_BIN_DIR=/opt/swiftly/bin
ENV SWIFTLY_TOOLCHAINS_DIR=/opt/swiftly/toolchains
ENV PATH="/opt/swiftly/bin:${PATH}"

RUN curl -fsSL https://download.swift.org/swiftly/linux/swiftly-$(uname -m).tar.gz \
      | tar xz -C /tmp \
    && /tmp/swiftly init --no-modify-profile --skip-install --assume-yes \
    && /opt/swiftly/bin/swiftly install --use 6.3.3 \
    && rm -rf /tmp/swiftly

RUN useradd -m -s /bin/bash ubuntu
USER ubuntu
