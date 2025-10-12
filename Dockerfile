# docker build --no-cache \
#   --build-arg OPENMS_TAG=3.4.1 \
#   --build-arg MAKE_JOBS=8 \
#   --build-arg ARYCAL_URL=https://github.com/singjc/arycal/releases/download/v0.1.10/arycal-.v0.1.10.-arycal-x86_64-unknown-linux-musl.tar.gz \
#   --build-arg SAGE_URL=https://github.com/lazear/sage/releases/download/v0.14.7/sage-v0.14.7-x86_64-unknown-linux-musl.tar.gz \
#   -t openswath/openswath:0.3.0 .

ARG OPENMS_TAG=3.4.1
ARG MAKE_JOBS=8
ARG PYPROPHET_VERSION=3.0.2
ARG EASYPQP_VERSION=0.1.53
# --- Added: URLs and optional SHA256 checksums for arycal & sage ---
ARG ARYCAL_URL="https://github.com/singjc/arycal/releases/download/v0.1.10/arycal-.v0.1.10.-arycal-x86_64-unknown-linux-musl.tar.gz"
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
# Final runtime = OpenMS image
# -----------------------------
FROM ghcr.io/openms/openms-executables:${OPENMS_TAG} AS runtime
ENV DEBIAN_FRONTEND=noninteractive
ENV INSTALL_DIR=/opt/OpenMS

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

# ms-numpress Python bindings
RUN git clone --depth 1 https://github.com/ms-numpress/ms-numpress.git /tmp/ms-numpress \
 && python -m pip install --no-cache-dir /tmp/ms-numpress/src/main/python \
 && rm -rf /tmp/ms-numpress

# Pre-reqs for msproteomicstools
RUN python -m pip install --no-cache-dir \
      xlwt biopython configobj "pymzml==0.7.8"

# msproteomicstools
RUN git clone --depth 1 https://github.com/msproteomicstools/msproteomicstools.git /tmp/msproteomicstools \
 && python -m pip install --no-cache-dir --no-build-isolation --no-deps /tmp/msproteomicstools \
 && rm -rf /tmp/msproteomicstools

# PyProphet CLI
RUN python -m pip install --no-cache-dir "pyprophet==${PYPROPHET_VERSION}"

# Pre-install DuckDB sqlite_scanner
RUN python - <<'PY'
import duckdb
con = duckdb.connect()
con.execute("INSTALL 'sqlite_scanner'")
con.execute("LOAD 'sqlite_scanner'")
PY

# EasyPQP CLI
RUN python -m pip install --no-cache-dir "easypqp==${EASYPQP_VERSION}"

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
# arycal & sage (precompiled)
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
    bin="$(find /opt/${name}/bin -maxdepth 2 -type f -perm -u+x \( -name ${name} -o -name '${name}*' \) | head -n1 || true)"; \
    if [ -z "$bin" ]; then \
      # fallback: mark all as executable and pick first file
      find /opt/${name}/bin -type f -exec chmod +x {} \; ; \
      bin="$(find /opt/${name}/bin -maxdepth 2 -type f -perm -u+x | head -n1 || true)"; \
    fi; \
    test -n "$bin"; \
    ln -sf "$bin" "/usr/local/bin/${name}"; \
    rm -f "$tmp"; \
  }; \
  fetch_install "$ARYCAL_URL" "arycal" "$ARYCAL_SHA256"; \
  fetch_install "$SAGE_URL"   "sage"   "$SAGE_SHA256";

# --- DIAlignR (R) ---------------------------------------------------
# Add CRAN repo matching the base Ubuntu codename (jammy in your image)
RUN set -eux; \
  apt-get update; \
  apt-get install -y --no-install-recommends software-properties-common dirmngr gnupg ca-certificates curl; \
  install -m 0755 -d /etc/apt/keyrings; \
  curl -fsSL https://cloud.r-project.org/bin/linux/ubuntu/marutter_pubkey.asc \
    | gpg --dearmor -o /etc/apt/keyrings/cran-archive-keyring.gpg; \
  . /etc/os-release; CODENAME="${VERSION_CODENAME:-jammy}"; \
  echo "deb [signed-by=/etc/apt/keyrings/cran-archive-keyring.gpg] https://cloud.r-project.org/bin/linux/ubuntu ${CODENAME}-cran40/" \
    > /etc/apt/sources.list.d/cran-r.list; \
  apt-get update; \
  apt-get install -y --no-install-recommends \
    r-base r-base-dev \
    libcurl4-openssl-dev libssl-dev libxml2-dev \
    libnetcdf-dev libglpk-dev libbz2-dev zlib1g-dev \
    build-essential \
    make g++ gfortran; \
  rm -rf /var/lib/apt/lists/*

# Install DIAlignR + friends (no devtools)
RUN R -e "if(!requireNamespace('BiocManager', quietly=TRUE)) install.packages('BiocManager', repos='https://cloud.r-project.org')" \
 && R -e "BiocManager::install('DIAlignR', ask=FALSE)" \
 && R -e "BiocManager::install('BiocParallel', ask=FALSE)" \
 && R -e "install.packages('remotes', repos='https://cloud.r-project.org')" \
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
