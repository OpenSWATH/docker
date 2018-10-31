# docker build --no-cache -t openswath/develop:latest .
# docker push openswath/develop

FROM ubuntu:16.04

WORKDIR /code

# install base dependencies
RUN apt-get -y update
RUN apt-get install -y apt-transport-https
RUN printf "deb https://cloud.r-project.org/bin/linux/ubuntu xenial/" > /etc/apt/sources.list.d/backports.list
RUN apt-get -y update
RUN apt-get install -y --allow-unauthenticated cmake g++ autoconf qt5-default libqt5svg5-dev patch libtool make git software-properties-common python3 wget default-jdk unzip bzip2 perl gnuplot xsltproc libgd-dev libpng12-dev zlib1g-dev libsvm-dev libglpk-dev libzip-dev zlib1g-dev libxerces-c-dev libbz2-dev libboost-all-dev libsqlite3-dev libexpat1-dev libgsl-dev apt-transport-https r-base r-base-dev libcurl4-openssl-dev libssl-dev libxml2 libxml2-dev libxslt1-dev python3-pip subversion

#########################################
# Computational proteomics dependencies #
#########################################

# install Crux
WORKDIR /code
RUN wget https://noble.gs.washington.edu/crux-downloads/crux-3.2/crux-3.2.Linux.x86_64.zip && unzip crux-3.2.Linux.x86_64.zip -d crux && rm crux-3.2.Linux.x86_64.zip
ENV PATH=$PATH:/code/crux/crux-3.2.Linux.x86_64/bin
WORKDIR /

# install DIA-Umpire
WORKDIR /code
RUN wget https://github.com/guoci/DIA-Umpire/releases/download/v2.1.3/v2.1.3.zip && unzip v2.1.3.zip -d DIAU && rm v2.1.3.zip
RUN chmod -R 755 /code/DIAU/v2.1.3/DIA_Umpire_SE.jar /code/DIAU/v2.1.3/DIA_Umpire_Quant.jar
ENV PATH=$PATH:/code/DIAU/v2.1.3
WORKDIR /

# install ProteoWizard
WORKDIR /code
RUN wget -O pwiz.tar.bz2 http://teamcity.labkey.org/guestAuth/app/rest/builds/id:641807/artifacts/content/pwiz-bin-linux-x86_64-gcc48-release-3_0_18282_8016b68.tar.bz2 && mkdir pwiz && tar xvjf pwiz.tar.bz2 -C pwiz && rm pwiz.tar.bz2
ENV PATH=$PATH:/code/pwiz/
WORKDIR /

#############
# OpenSWATH #
#############

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

# build OpenMS
WORKDIR /code
RUN git clone https://github.com/OpenMS/OpenMS.git --branch develop
RUN mkdir openms_build

WORKDIR /code/openms_build

RUN cmake -DOPENMS_CONTRIB_LIBS="/code/contrib_build/" -DCMAKE_PREFIX_PATH="/usr/;/usr/local" -DBOOST_USE_STATIC=OFF ../OpenMS
RUN make -j4
ENV PATH=$PATH:/code/openms_build/bin/

#####
# R #
#####

# install R packages
RUN R -e "install.packages(c('RSQLite','plyr','devtools','spData','classInt'), repos = 'http://cran.us.r-project.org'); library(devtools); install_github('IFIproteomics/LFQbench')"

##########
# Python #
##########

# install PyProphet and dependencies
WORKDIR /code
RUN pip3 install pip --upgrade
RUN pip3 install numpy scipy cython jsonschema snakemake pyopenms --upgrade
RUN pip3 install git+https://github.com/grosenberger/pyprophet.git@feature/classifiers

# build msproteomicstools dependencies
WORKDIR /code
RUN git clone https://github.com/carljv/Will_it_Python.git
WORKDIR Will_it_Python/MLFH/CH2/lowess\ work/
RUN python3 setup.py build && python3 setup.py install

# build msproteomicstools
WORKDIR /code
RUN git clone https://github.com/msproteomicstools/msproteomicstools.git
WORKDIR msproteomicstools
RUN python3 setup.py build --with_cython && python3 setup.py install

# patch Python
ENV LC_ALL=C.UTF-8
ENV LANG=C.UTF-8

RUN apt-get install -y uuid-runtime

#################################
# DO NOT CHANGE BELOW THIS LINE #
#################################
WORKDIR /data/
