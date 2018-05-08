# docker build -t openswath/openswath:0.1.0 .
# docker push openswath/openswath:0.1.0

FROM ubuntu:16.04

WORKDIR /code

# install base dependencies
RUN apt-get -y update
RUN apt-get install -y cmake g++ autoconf qt5-default libqt5svg5-dev patch libtool make git software-properties-common python-software-properties 

# install more dependencies
RUN apt-get install -qq libsvm-dev libglpk-dev libzip-dev zlib1g-dev libxerces-c-dev libbz2-dev libboost-all-dev libsqlite3-dev

# build contrib
WORKDIR /code
RUN git clone https://github.com/OpenMS/contrib.git
RUN mkdir contrib_build

WORKDIR /code/contrib_build

RUN cmake -DBUILD_TYPE=COINOR ../contrib
RUN cmake -DBUILD_TYPE=SEQAN ../contrib
RUN cmake -DBUILD_TYPE=WILDMAGIC ../contrib
RUN cmake -DBUILD_TYPE=EIGEN ../contrib
RUN cmake -DBUILD_TYPE=KISSFFT ../contrib

# build Percolator
WORKDIR /code
RUN git clone https://github.com/percolator/percolator.git
RUN mkdir percolator_build

WORKDIR /code/percolator_build

RUN cmake -DCMAKE_PREFIX_PATH="/usr/;/usr/local" ../percolator
RUN make -j4 && make install

# build OpenMS
WORKDIR /code
RUN git clone https://github.com/OpenMS/OpenMS.git
RUN mkdir openms_build

WORKDIR /code/openms_build

RUN cmake -DOPENMS_CONTRIB_LIBS="/code/contrib_build/" -DCMAKE_PREFIX_PATH="/usr/;/usr/local" -DBOOST_USE_STATIC=OFF ../OpenMS
RUN make -j4
ENV PATH=$PATH:/code/openms_build/bin/

# build PyProphet
WORKDIR /code
RUN apt-get install -y python-pip python-numpy python-scipy cython
RUN pip install git+https://github.com/PyProphet/pyprophet.git@master

# build msproteomicstools
RUN apt-get install libxml2 libxml2-dev libxslt1-dev 

WORKDIR /code
RUN git clone https://github.com/carljv/Will_it_Python.git
WORKDIR Will_it_Python/MLFH/CH2/lowess\ work/
RUN python setup.py build
RUN python setup.py install

WORKDIR /code
RUN git clone https://github.com/msproteomicstools/msproteomicstools.git
WORKDIR msproteomicstools
RUN python setup.py install --with_cython

WORKDIR /
