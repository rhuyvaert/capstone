# syntax=docker/dockerfile:1
#
# ONE image for Series D: the same OpenMPI / OpenBLAS (DYNAMIC_ARCH) / HPL / OSU as /apps on the bare-metal nodes,
# built from the same source tarballs, at the same paths (/apps/openmpi, /apps/openblas), so the MPI flags are identical.
# No -march=native anywhere: one image has to run on every node, from the i5-2430M to the Ryzen.
# Build it with dockerimg.sh (it stages the sources and passes the build arguments); do not run "docker build" by hand.

ARG BASE=ubuntu:26.04

# -------------------------------- build stage --------------------------------
FROM ${BASE} AS build
ARG DEBIAN_FRONTEND=noninteractive
ARG OMPI_CONFIGURE="--with-pmix --with-libevent"
ARG OPENBLAS_THREADS=64
RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential gfortran perl libevent-dev libpmix-dev ca-certificates \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY src/ /src/

# OpenMPI: same configure options as /apps/openmpi on the host (dockerimg.sh reads them from ompi_info)
RUN set -eux; mkdir ompi; tar -xf openmpi.src -C ompi --strip-components=1; cd ompi; \
    ./configure --prefix=/apps/openmpi ${OMPI_CONFIGURE} > /tmp/ompi-configure.log 2>&1; \
    make -j"$(nproc)" > /tmp/ompi-make.log 2>&1; make install > /tmp/ompi-install.log 2>&1

# OpenBLAS: DYNAMIC_ARCH picks the right kernel on every CPU at run time
RUN set -eux; mkdir ob; tar -xf openblas.src -C ob --strip-components=1; cd ob; \
    make -j"$(nproc)" DYNAMIC_ARCH=1 NUM_THREADS=${OPENBLAS_THREADS} > /tmp/ob-make.log 2>&1; \
    make PREFIX=/apps/openblas install > /tmp/ob-install.log 2>&1

# HPL, linked with -L and an rpath so it finds OpenBLAS without LD_LIBRARY_PATH
COPY Make.docker /src/Make.docker
RUN set -eux; mkdir hpl; tar -xf hpl.src -C hpl --strip-components=1; cd hpl; \
    cp /src/Make.docker Make.docker; sed -i "s#^TOPdir *=.*#TOPdir = $PWD#" Make.docker; \
    make arch=docker > /tmp/hpl-make.log 2>&1; install -D bin/docker/xhpl /opt/hpl/xhpl

# OSU micro-benchmarks (optional: only if the tarball was staged); needed by D4
RUN set -eux; if [ -f osu.src ]; then mkdir osu; tar -xf osu.src -C osu --strip-components=1; cd osu; \
    ./configure CC=/apps/openmpi/bin/mpicc CXX=/apps/openmpi/bin/mpicxx --prefix=/apps/osu > /tmp/osu-configure.log 2>&1; \
    make -j"$(nproc)" > /tmp/osu-make.log 2>&1; make install > /tmp/osu-install.log 2>&1; fi

# build record, kept inside the image so it travels with it
RUN { echo "built $(date -Iseconds)"; /apps/openmpi/bin/ompi_info | grep -E 'Open MPI:|Configure command' || true; \
      grep -E 'OPENBLAS_VERSION|MAX_CPU_NUMBER' /apps/openblas/include/openblas_config.h || true; \
      sha256sum *.src; } > /apps/hplbox-build.txt

# ------------------------------------ runtime stage --------------------------
FROM ${BASE}
ARG DEBIAN_FRONTEND=noninteractive
ARG CLUSTER_UID=2001
RUN apt-get update \
 && apt-get install -y --no-install-recommends libevent-dev libpmix-dev libgfortran5 openssh-server openssh-client \
        iperf3 sysbench iproute2 procps \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd -g ${CLUSTER_UID} clusteruser \
 && useradd -m -u ${CLUSTER_UID} -g ${CLUSTER_UID} -s /bin/bash clusteruser
COPY --from=build /apps /apps
COPY --from=build /opt/hpl /opt/hpl
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh \
 && printf '/apps/openmpi/lib\n/apps/openblas/lib\n' > /etc/ld.so.conf.d/hplbox.conf && ldconfig
ENV PATH=/apps/openmpi/bin:/apps/osu/libexec/osu-micro-benchmarks/mpi/pt2pt:/apps/osu/libexec/osu-micro-benchmarks/mpi/collective:/opt/hpl:$PATH \
    LD_LIBRARY_PATH=/apps/openmpi/lib:/apps/openblas/lib
USER clusteruser
WORKDIR /home/clusteruser
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["bash"]
