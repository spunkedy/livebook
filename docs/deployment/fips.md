# FIPS mode

For environments that require security hardening you might need to turn on FIPS mode. Being able to turn on FIPS in general is a complex procedure, this just enables you to be able to turn FIPS on.

To be able to turn on fips mode you will need to have an erlang distribution that has been compiled with [fips enabled](https://www.erlang.org/doc/apps/crypto/fips).


### Error on startup

```bash
export LIVEBOOK_FIPS=true
_build/prod/rel/livebook/bin/livebook start_iex 

ERROR! Config provider Config.Reader failed with:
** (RuntimeError) Requested FIPS mode via LIVEBOOK_FIPS, but this Erlang installation was compiled without FIPS support
    (livebook 0.13.0-dev) lib/livebook.ex:242: Livebook.config_runtime/0
        ...

```

This means that your elixir/erlang environmet was NOT compiled with FIPS enabled.

### Docker example
To do this in docker, you will need to build it a little bit differently. You can see a mini example below. This should be considered psuedo code, you will want to adapt it to your needs. You should consider having a base image for the erlang/elixir portion with FIPS turned on and then overlay with a [multi stage build](https://docs.docker.com/build/building/multi-stage/).


```docker
FROM registry.access.redhat.com/ubi8/ubi-minimal:8.9-1137
# Set environment variables for path and language
ENV PATH /usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin 

# Install system dependencies and clean cache in one layer
RUN microdnf install -y unzip autoconf git ncurses-devel openssl-devel gcc gcc-c++ make automake perl clang wget tar cmake glibc-locale-source glibc-langpack-en && \
    microdnf clean all && \
    rm -rf /var/cache/yum

WORKDIR /install

# Download, configure, and install Erlang/OTP with FIPS enabled
ARG ERLANG_VERSION
RUN wget https://github.com/erlang/otp/archive/OTP-${ERLANG_VERSION}.tar.gz && \
    tar -xzvf OTP-${ERLANG_VERSION}.tar.gz && \
    cd otp-OTP-${ERLANG_VERSION} && \
    ./otp_build autoconf && \
    ./configure --enable-fips && \
    make && make install

# Clone, checkout, and install Elixir
ARG ELIXIR_VERSION
RUN git clone https://github.com/elixir-lang/elixir.git && \
    cd elixir && \
    git checkout v${ELIXIR_VERSION} && \
    make compile && \
    make install

```