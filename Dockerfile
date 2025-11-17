# docker build --no-cache \
#   --build-arg OPENMS_TAG=3.4.1 \
#   --build-arg MAKE_JOBS=8 \
#   --build-arg ARYCAL_URL=https://github.com/singjc/arycal/releases/download/v0.1.10/arycal-.v0.1.10.-arycal-x86_64-unknown-linux-musl.tar.gz \
#   --build-arg SAGE_URL=https://github.com/lazear/sage/releases/download/v0.14.7/sage-v0.14.7-x86_64-unknown-linux-musl.tar.gz \
#   -t openswath/openswath:0.3.0 .
#
# Optional: Build OpenMS from source (dev branch):
#   docker build --build-arg OPENMS_GIT_REF=develop --target runtime-built -t openswath/openswath:dev .
#
# Optional: Build Sage from source (to get unreleased features):
#   docker build --build-arg USE_SAGE_SOURCE=true --build-arg SAGE_GIT_REF=master -t openswath/openswath:latest .
#
# Optional: Build easypqp from source (to get unreleased features):
#   docker build --build-arg USE_EASYPQP_SOURCE=true --build-arg EASYPQP_GIT_REF=master -t openswath/openswath:latest .

ARG OPENMS_TAG=3.4.1
ARG MAKE_JOBS=8
ARG PYPROPHET_VERSION=3.0.2
ARG EASYPQP_VERSION=0.1.53
ARG DIAPYSEF_VERSION=1.0.10
ARG OPENMS_GIT_REF=develop
ARG CMAKE_VERSION=3.27.6
ARG SAGE_GIT_REF=master
ARG USE_SAGE_SOURCE=false
ARG EASYPQP_GIT_REF=master
ARG USE_EASYPQP_SOURCE=false
# --- Added: URLs and optional SHA256 checksums for arycal & sage ---
# ARG ARYCAL_URL="https://github.com/singjc/arycal/releases/download/v0.1.10/arycal-.v0.1.10.-arycal-x86_64-unknown-linux-musl.tar.gz"
ARG ARYCAL_URL="https://github.com/singjc/arycal/releases/download/v0.2.1/arycal-v0.2.1-x86_64-linux-musl.zip"
ARG ARYCAL_SHA256=""
ARG SAGE_URL="https://github.com/lazear/sage/releases/download/v0.14.7/sage-v0.14.7-x86_64-unknown-linux-musl.tar.gz"
ARG SAGE_SHA256=""

# -----------------------------
# mapDIA (needs Ubuntu 16.04)
# -----------------------------
FROM buildpack-deps:xenial AS mapdia-legacy
ARG MAKE_JOBS
WORKDIR /code

RUN wget -O mapDIA_v3.1.0.tar.gz https://sourceforge.net/projects/mapdia/files/mapDIA_v3.1.0.tar.gz/download
RUN tar xvf mapDIA_v3.1.0.tar.gz \
 && cd mapDIA \
 && make -j${MAKE_JOBS} \
 && install -m 0755 mapDIA /usr/local/bin/mapDIA \
 && mkdir -p /opt/mapdia/bin \
 && cp /usr/local/bin/mapDIA /opt/mapdia/bin/ \
 && ln -sf /opt/mapdia/bin/mapDIA /usr/local/bin/mapdia

# -----------------------------
# Percolator builder
# (same distro as final OpenMS image => ABI-compatible)
# -----------------------------
FROM ghcr.io/openms/openms-executables:${OPENMS_TAG} AS percolator-builder
ARG MAKE_JOBS
WORKDIR /src

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates git build-essential cmake \
        libboost-filesystem-dev libboost-system-dev libboost-thread-dev \
    && update-ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN git config --global http.sslCAinfo /etc/ssl/certs/ca-certificates.crt

RUN git clone --depth 1 https://github.com/percolator/percolator.git
RUN mkdir -p build && cd build && cmake \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/opt/percolator \
        -DXML_SUPPORT=OFF -DGOOGLE_TEST=0 \
        ../percolator \
    && make -j${MAKE_JOBS} \
    && make install    

# -----------------------------
# Optional: build OpenMS from source (dev branch/ref)
# This stage is opt-in; use the `runtime-built` target to produce a runtime image
# that contains OpenMS built from the specified git ref (see build examples).
# -----------------------------
FROM ghcr.io/openms/openms-executables:${OPENMS_TAG} AS openms-builder
ARG MAKE_JOBS
ARG OPENMS_GIT_REF
ARG CMAKE_VERSION
ENV CMAKE_VERSION=${CMAKE_VERSION}
WORKDIR /src

# Install common build deps for OpenMS (may need to be adjusted for specific OpenMS refs)
# Install a newer CMake (>=3.24) from Kitware APT repo, then install dev packages OpenMS expects.
RUN set -eux; \
  apt-get update; \
  apt-get install -y --no-install-recommends ca-certificates gnupg wget lsb-release software-properties-common curl; \
  # Install a recent CMake binary (avoid apt.kitware network issues)
  CMAKE_TARBALL="cmake-${CMAKE_VERSION}-linux-x86_64.tar.gz"; \
  CMAKE_URL="https://github.com/Kitware/CMake/releases/download/v${CMAKE_VERSION}/${CMAKE_TARBALL}"; \
  curl -fsSL -o /tmp/${CMAKE_TARBALL} "${CMAKE_URL}"; \
  tar --strip-components=1 -C /usr/local -xzf /tmp/${CMAKE_TARBALL}; \
  rm -f /tmp/${CMAKE_TARBALL}; \
  apt-get install -y --no-install-recommends \
  ca-certificates git build-essential \
  qtbase5-dev libqt5svg5-dev \
  libboost-all-dev libeigen3-dev libtbb-dev \
  # Explicit Boost dev packages (ensure shared .so variants are available)
  libboost-random-dev libboost-regex-dev libboost-iostreams-dev libboost-date-time-dev libboost-math-dev \
      libfftw3-dev liblapack-dev libblas-dev \
      libxerces-c-dev libxml2-dev zlib1g-dev libbz2-dev xz-utils pkg-config \
      libsvm-dev \
      coinor-libcbc-dev coinor-libclp-dev coinor-libcoinutils-dev coinor-libcgl-dev coinor-libosi-dev libglpk-dev \
  ; \
  rm -rf /var/lib/apt/lists/*

# Configure git SSL CA like other builder stages
RUN git config --global http.sslCAinfo /etc/ssl/certs/ca-certificates.crt

# Clone OpenMS at the requested ref and build
RUN git clone --depth 1 --branch ${OPENMS_GIT_REF} https://github.com/OpenMS/OpenMS.git /src/OpenMS
## Remove static Boost archives so the linker selects shared Boost libraries
# Some distributions ship both libboost_*.a and libboost_*.so; static .a files
# that lack -fPIC cause linking failures when building shared libraries. Remove
# the static archives in the builder stage to force use of shared .so files.
RUN find /usr/lib /usr/lib/x86_64-linux-gnu -type f -name 'libboost_*.a' -exec rm -f {} + || true

RUN mkdir -p /src/OpenMS/build && cd /src/OpenMS/build \
 && cmake -DCMAKE_BUILD_TYPE=Release \
   -DCMAKE_INSTALL_PREFIX=/opt/OpenMS \
   -DWITH_GUI=OFF -DHAS_XSERVER=OFF \
  -DBoost_USE_STATIC_LIBS=OFF \
  -DBoost_USE_STATIC_RUNTIME=OFF \
  -DBOOST_USE_STATIC=OFF \
   -DCMAKE_FIND_LIBRARY_SUFFIXES=".so;.a" \
   .. \
 && make -j${MAKE_JOBS} \
 && make install

# -----------------------------
# Optional: build Sage from source (master/dev branch)
# This stage is opt-in; the runtime stage will copy from here when USE_SAGE_SOURCE=true
# Build with: docker build --build-arg USE_SAGE_SOURCE=true --build-arg SAGE_GIT_REF=master -t openswath:dev .
# -----------------------------
FROM rust:1.75-slim AS sage-builder
ARG SAGE_GIT_REF
WORKDIR /src

# Install build dependencies for Sage (Rust project)
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates git \
  && rm -rf /var/lib/apt/lists/*

RUN git config --global http.sslCAinfo /etc/ssl/certs/ca-certificates.crt

# Clone Sage at the requested ref and build
RUN git clone --depth 1 --branch ${SAGE_GIT_REF} https://github.com/lazear/sage.git /src/sage

# Build Sage in release mode
RUN cd /src/sage \
 && cargo build --release \
 && mkdir -p /opt/sage/bin \
 && cp target/release/sage /opt/sage/bin/sage \
 && chmod +x /opt/sage/bin/sage

# -----------------------------
# Optional: build easypqp from source (master/dev branch)
# This stage is opt-in; the runtime stage will use this when USE_EASYPQP_SOURCE=true
# Build with: docker build --build-arg USE_EASYPQP_SOURCE=true --build-arg EASYPQP_GIT_REF=master -t openswath:dev .
# -----------------------------
FROM ghcr.io/openms/openms-executables:${OPENMS_TAG} AS easypqp-builder
ARG EASYPQP_GIT_REF
WORKDIR /src

# Install Python and build dependencies for easypqp
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates git \
      python3 python3-venv python3-pip python3-dev \
      build-essential \
  && rm -rf /var/lib/apt/lists/*

RUN git config --global http.sslCAinfo /etc/ssl/certs/ca-certificates.crt

# Clone easypqp at the requested ref
RUN git clone --depth 1 --branch ${EASYPQP_GIT_REF} https://github.com/grosenberger/easypqp.git /src/easypqp

# Create a virtual environment and install easypqp
RUN python3 -m venv /opt/easypqp-venv \
 && . /opt/easypqp-venv/bin/activate \
 && pip install --no-cache-dir --upgrade pip setuptools wheel \
 && pip install --no-cache-dir /src/easypqp

# -----------------------------
# Final runtime = OpenMS image
# -----------------------------
FROM ghcr.io/openms/openms-executables:${OPENMS_TAG} AS runtime
ENV DEBIAN_FRONTEND=noninteractive
ENV INSTALL_DIR=/opt/OpenMS

# re-declare any ARGs you need in THIS stage
ARG PYPROPHET_VERSION
ARG EASYPQP_VERSION
ARG ARYCAL_URL
ARG ARYCAL_SHA256
ARG SAGE_URL
ARG SAGE_SHA256
ARG USE_SAGE_SOURCE
ARG USE_EASYPQP_SOURCE

# (optional) make them visible at runtime inside the container
ENV PYPROPHET_VERSION="${PYPROPHET_VERSION}" \
    EASYPQP_VERSION="${EASYPQP_VERSION}"

# System Python + minimal build bits for Python wheels + fetch helpers
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates \
      python3 python3-venv python3-pip python3-dev \
      build-essential git \
      libxml2 libxml2-dev libxslt1-dev \
      libglib2.0-0 libgomp1 \
      curl xz-utils unzip \
  && rm -rf /var/lib/apt/lists/*

# Python env for PyProphet + msproteomicstools
RUN python3 -m venv /opt/venv
ENV VIRTUAL_ENV=/opt/venv
ENV PATH="/opt/venv/bin:${INSTALL_DIR}/bin:${PATH}"
ENV LD_LIBRARY_PATH="${INSTALL_DIR}/lib:/usr/lib/x86_64-linux-gnu:/usr/lib/x86_64-linux-gnu/qt6"

# Sci stack (pins to keep Cython/NumPy API stable)
RUN python -m pip install --no-cache-dir --upgrade pip "setuptools<75" wheel \
 && python -m pip install --no-cache-dir --prefer-binary \
      "numpy==1.26.4" "cython==0.29.36" "scipy==1.12.*" \
      duckdb seaborn psutil plotly

# pyOpenMS that matches OpenMS 3.x
RUN python -m pip install --no-cache-dir "pyopenms>=3,<3.5"

# RUN python -m pip install --no-cache-dir "cython==0.29.36"

# # ms-numpress Python bindings
# RUN git clone --depth 1 https://github.com/ms-numpress/ms-numpress.git /tmp/ms-numpress \
#  && python -m pip install --no-cache-dir /tmp/ms-numpress/src/main/python \
#  && rm -rf /tmp/ms-numpress

# # Pre-reqs for msproteomicstools
# RUN python -m pip install --no-cache-dir \
#       xlwt biopython configobj "pymzml==0.7.8"

# # msproteomicstools
# RUN git clone --depth 1 https://github.com/msproteomicstools/msproteomicstools.git /tmp/msproteomicstools \
#  && python -m pip install --no-cache-dir --no-build-isolation --no-deps /tmp/msproteomicstools \
#  && rm -rf /tmp/msproteomicstools

# PyProphet CLI
RUN python -m pip install --no-cache-dir "pyprophet==${PYPROPHET_VERSION}"

# Pre-install DuckDB sqlite_scanner
RUN python - <<'PY'
import duckdb
con = duckdb.connect()
con.execute("INSTALL 'sqlite_scanner'")
con.execute("LOAD 'sqlite_scanner'")
PY

# EasyPQP CLI: either built from source (USE_EASYPQP_SOURCE=true) or installed from PyPI
RUN if [ "$USE_EASYPQP_SOURCE" = "true" ]; then \
      echo "Using easypqp built from source (easypqp-builder stage)"; \
    else \
      echo "Installing easypqp from PyPI"; \
      python -m pip install --no-cache-dir "easypqp==${EASYPQP_VERSION}"; \
    fi

# Copy easypqp from builder stage if USE_EASYPQP_SOURCE=true
COPY --from=easypqp-builder /opt/easypqp-venv /opt/easypqp-venv 2>/dev/null || true
RUN if [ "$USE_EASYPQP_SOURCE" = "true" ] && [ -d /opt/easypqp-venv ]; then \
      ln -sf /opt/easypqp-venv/bin/easypqp /opt/venv/bin/easypqp; \
    fi

# diapysef CLI
RUN python -m pip install --no-cache-dir diapysef

# Percolator built on the same base => ABI-compatible
COPY --from=percolator-builder /opt/percolator /opt/percolator
RUN ln -sf /opt/percolator/bin/percolator /usr/local/bin/percolator

# mapDIA binary
COPY --from=mapdia-legacy /opt/mapdia /opt/mapdia
RUN ln -sf /opt/mapdia/bin/mapDIA /usr/local/bin/mapDIA \
 && ln -sf /opt/mapdia/bin/mapDIA /usr/local/bin/mapdia

# convenience shims
RUN ln -sf /opt/venv/bin/feature_alignment.py /usr/local/bin/feature_alignment.py || true \
 && ln -sf /opt/venv/bin/pyprophet            /usr/local/bin/pyprophet            || true \
 && ln -sf /opt/venv/bin/easypqp              /usr/local/bin/easypqp              || true

# -----------------------------
# arycal (precompiled binary download)
# -----------------------------
# Helper: download + verify + unpack/put into /usr/local/bin
# Works with .tar.gz, .tar.xz, .zip, or plain binary URLs
RUN set -eux; \
  fetch_install () { \
    url="$1"; name="$2"; sha="$3"; \
    test -n "$url" || { echo "skip $name (no URL)"; return 0; }; \
    tmp=/tmp/${name}.asset; \
    curl -L --fail -o "$tmp" "$url"; \
    if [ -n "$sha" ]; then echo "${sha}  ${tmp}" | sha256sum -c -; fi; \
    mkdir -p /opt/${name}/bin; \
    case "$url" in \
      *.tar.gz|*.tgz) tar -xzf "$tmp" -C /opt/${name}/bin ;; \
      *.tar.xz)       tar -xJf "$tmp" -C /opt/${name}/bin ;; \
      *.zip)          unzip -q "$tmp" -d /opt/${name}/bin ;; \
      *)              install -m 0755 "$tmp" "/opt/${name}/bin/${name}" ;; \
    esac; \
    # find the binary (first matching file named exactly or prefix)
    bin="$(find /opt/${name}/bin -maxdepth 2 -type f -perm -u+x \( -name "${name}" -o -name "${name}*" \) | head -n1 || true)"; \
    if [ -z "$bin" ]; then \
      # fallback: mark all as executable and pick first file
      find /opt/${name}/bin -type f -exec chmod +x {} \; ; \
      bin="$(find /opt/${name}/bin -maxdepth 2 -type f -perm -u+x | head -n1 || true)"; \
    fi; \
    test -n "$bin"; \
    ln -sf "$bin" "/usr/local/bin/${name}"; \
    rm -f "$tmp"; \
  }; \
  fetch_install "$ARYCAL_URL" "arycal" "$ARYCAL_SHA256";

# -----------------------------
# sage: either built from source (USE_SAGE_SOURCE=true) or precompiled binary download
# -----------------------------
# Conditional copy from sage-builder if USE_SAGE_SOURCE=true, otherwise download prebuilt
RUN set -eux; \
  if [ "$USE_SAGE_SOURCE" = "true" ]; then \
    echo "Using Sage built from source (sage-builder stage)"; \
  else \
    echo "Downloading prebuilt Sage binary"; \
    fetch_install () { \
      url="$1"; name="$2"; sha="$3"; \
      test -n "$url" || { echo "skip $name (no URL)"; return 0; }; \
      tmp=/tmp/${name}.asset; \
      curl -L --fail -o "$tmp" "$url"; \
      if [ -n "$sha" ]; then echo "${sha}  ${tmp}" | sha256sum -c -; fi; \
      mkdir -p /opt/${name}/bin; \
      case "$url" in \
        *.tar.gz|*.tgz) tar -xzf "$tmp" -C /opt/${name}/bin ;; \
        *.tar.xz)       tar -xJf "$tmp" -C /opt/${name}/bin ;; \
        *.zip)          unzip -q "$tmp" -d /opt/${name}/bin ;; \
        *)              install -m 0755 "$tmp" "/opt/${name}/bin/${name}" ;; \
      esac; \
      bin="$(find /opt/${name}/bin -maxdepth 2 -type f -perm -u+x \( -name "${name}" -o -name "${name}*" \) | head -n1 || true)"; \
      if [ -z "$bin" ]; then \
        find /opt/${name}/bin -type f -exec chmod +x {} \; ; \
        bin="$(find /opt/${name}/bin -maxdepth 2 -type f -perm -u+x | head -n1 || true)"; \
      fi; \
      test -n "$bin"; \
      ln -sf "$bin" "/usr/local/bin/${name}"; \
      rm -f "$tmp"; \
    }; \
    fetch_install "$SAGE_URL" "sage" "$SAGE_SHA256"; \
  fi

# Copy sage from builder stage if USE_SAGE_SOURCE=true
COPY --from=sage-builder /opt/sage/bin/sage /tmp/sage-built 2>/dev/null || true
RUN if [ "$USE_SAGE_SOURCE" = "true" ] && [ -f /tmp/sage-built ]; then \
      mkdir -p /opt/sage/bin; \
      mv /tmp/sage-built /opt/sage/bin/sage; \
      chmod +x /opt/sage/bin/sage; \
      ln -sf /opt/sage/bin/sage /usr/local/bin/sage; \
    fi

# --- DIAlignR (R) ---------------------------------------------------
# Install R and build deps from the Ubuntu jammy repos (avoid external CRAN apt key issues
# during container builds). This installs r-base/r-base-dev and the development libraries
# needed to build DIAlignR.
RUN apt-get update && apt-get install -y --no-install-recommends \
    r-base r-base-dev \
    libcurl4-openssl-dev libssl-dev libxml2-dev \
    libnetcdf-dev libglpk-dev libbz2-dev zlib1g-dev \
    build-essential make g++ gfortran \
  && rm -rf /var/lib/apt/lists/*

# Install DIAlignR + friends (no devtools) using the default CRAN mirror from within R
RUN R -e "options(repos = c(CRAN = 'https://cloud.r-project.org')); if(!requireNamespace('BiocManager', quietly=TRUE)) install.packages('BiocManager')" \
 && R -e "BiocManager::install('DIAlignR', ask=FALSE)" \
 && R -e "BiocManager::install('BiocParallel', ask=FALSE)" \
 && R -e "install.packages('remotes')" \
 && R -e "remotes::install_github('omegahat/Rcompression', dependencies=FALSE)"

# Fetch DIAlignR CLI script (pin to a commit if you want reproducibility)
ARG DIALIGNR_SHA=master
RUN curl -fsSL \
      "https://raw.githubusercontent.com/shubham1637/DIAlignR/${DIALIGNR_SHA}/Rscript/alignTargetedRuns_cli.R" \
      -o /usr/local/bin/alignTargetedRuns_cli.R \
 && chmod 0755 /usr/local/bin/alignTargetedRuns_cli.R

# Handy wrapper so you can call `alignTargetedRuns`
RUN printf '%s\n' '#!/bin/sh' 'exec Rscript /usr/local/bin/alignTargetedRuns_cli.R "$@"' \
    > /usr/local/bin/alignTargetedRuns \
 && chmod +x /usr/local/bin/alignTargetedRuns
# --------------------------------------------------------------------


ENV LC_ALL=C.UTF-8 LANG=C.UTF-8
WORKDIR /data/

# -----------------------------
# runtime-built: builds on top of the normal `runtime` target but replaces
# /opt/OpenMS with the OpenMS built from source in the `openms-builder` stage.
# Build with: docker build --build-arg OPENMS_GIT_REF=develop --target runtime-built -t openswath:dev .
# -----------------------------
FROM runtime AS runtime-built
ARG OPENMS_GIT_REF
COPY --from=openms-builder /opt/OpenMS /opt/OpenMS

