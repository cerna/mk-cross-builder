FROM zultron/docker-cross-builder:@DISTRO@
MAINTAINER John Morris <john@zultron.com>

###################################################################
# Build configuration settings

env DEBIAN_ARCH=@DEBIAN_ARCH@
env HOST_MULTIARCH=@HOST_MULTIARCH@
env DISTRO=@DISTRO@
env EXTRA_FLAGS=@EXTRA_FLAGS@

###################################################################
# Generic apt configuration

ENV TERM=dumb

# apt config:  silence warnings and set defaults
ENV DEBIAN_FRONTEND=noninteractive
ENV DEBCONF_NONINTERACTIVE_SEEN=true
ENV LC_ALL=C.UTF-8
ENV LANGUAGE=C.UTF-8
ENV LANG=C.UTF-8

# turn off recommends on container OS and proot OS
RUN echo 'APT::Install-Recommends "0";\nAPT::Install-Suggests "0";' > \
	    /etc/apt/apt.conf.d/01norecommend

# use stable Debian mirror
RUN sed -i /etc/apt/sources.list -e 's/httpredir.debian.org/ftp.debian.org/'

# Stop `dpkg-gencontrol` warnings about flock
RUN apt-get -y install \
	libfile-fcntllock-perl \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

###################################################################
# Add foreign arches and update OS

# add foreign architectures
RUN dpkg --add-architecture armhf
RUN dpkg --add-architecture i386

# update Debian OS
RUN apt-get update \
    && apt-get -y upgrade \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

###################################################################
# Install utility and dev packages

# Utilities
RUN apt-get -y install \
	locales \
	git \
	bzip2 \
	sharutils \
	net-tools \
	time \
	procps \
	help2man \
	xvfb \
	xauth \
	python-sphinx \
	wget \
	sudo \
	lftp \
	apt-transport-https \
	ca-certificates \
	multistrap \
	debian-keyring \
	debian-archive-keyring \
	python-restkit \
	python-apt \
	rubygems \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Dev tools
RUN apt-get install -y \
	build-essential \
	devscripts \
	fakeroot \
	equivs \
	lsb-release \
	less \
	python-debian \
	libtool \
	ccache \
	autoconf \
	automake \
	quilt \
	psmisc \
	pkg-config \
	binutils-multiarch \
	crossbuild-essential-armhf \
	qemu-user-static \
	linux-libc-dev:armhf \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

###########################################
# Packagecloud.io

# Add packagecloud cli and prune utility
RUN gem install package_cloud --no-rdoc --no-ri
ADD packagecloud/packagecloud-prune.py /usr/bin/packagecloud-prune
ADD packagecloud/packagecloud-upload.sh /usr/bin/packagecloud-upload
ADD packagecloud/PackagecloudIo.py /usr/lib/python2.7

###################################################################
# Build environment

ENV SYS_ROOT=/sysroot
ENV CPPFLAGS="--sysroot=$SYS_ROOT ${EXTRA_FLAGS}"
ENV LDFLAGS="--sysroot=$SYS_ROOT ${EXTRA_FLAGS}"
ENV PKG_CONFIG_PATH="$SYS_ROOT/usr/lib/$HOST_MULTIARCH/pkgconfig:$SYS_ROOT/usr/lib/pkgconfig:$SYS_ROOT/usr/share/pkgconfig"
ENV DPKG_ROOT=$SYS_ROOT

# armhf build root environment
ENV ARM_HOST_MULTIARCH=arm-linux-gnueabihf

# i386 build root environment
ENV I386_HOST_MULTIARCH=i386-linux-gnu

###########################################
# Monkey-patches and multistrap setup

# Create sysroot directory
RUN mkdir $SYS_ROOT

# Add multistrap configurations
ADD multistrap-conf/ /tmp/

# Add `{dh_shlibdeps,dpkg-shlibdeps} --sysroot` argument
ADD dpkg-shlibdeps.patch /tmp/
RUN cd / && \
    patch -p0 -F 0 -N < /tmp/dpkg-shlibdeps.patch && \
    rm /tmp/dpkg-shlibdeps.patch
# Help dpkg-shlibdeps find i386 libraries
RUN mkdir -p ${SYS_ROOT}/usr/lib/ && \
    ln -s ${I386_HOST_MULTIARCH} ${SYS_ROOT}/usr/lib/i586-linux-gnu
RUN mkdir -p ${SYS_ROOT}/etc && \
    cp /etc/ld.so.conf ${SYS_ROOT}/etc/ld.so.conf
# Symlink i586 binutils to i386 so ./configure can find them
RUN for i in /usr/bin/i586-linux-gnu-*; do \
	ln -s $(basename $i) $(echo $i | sed 's/i586/i386/'); \
    done


###################################################################
# Machinekit:  Configure apt

# add Machinekit package archive
RUN apt-key adv --keyserver hkp://keyserver.ubuntu.com:80 --recv 43DDF224
# FIXME temporary for stretch
RUN if test $DISTRO = stretch; then \
        echo "deb http://deb.mgware.co.uk $DISTRO main" > \
            /etc/apt/sources.list.d/machinekit.list; \
    else \
	echo "deb http://deb.machinekit.io/debian $DISTRO main" > \
            /etc/apt/sources.list.d/machinekit.list; \
    fi

###################################################################
# Machinekit:  Install dependency packages

##############################
# Machinekit:  Configure multistrap

# Set up debian/control for `mk-build-deps`
#     FIXME download parts from upstream
ADD debian/ /tmp/debian/
RUN if test $DISTRO = stretch; then \
	/tmp/debian/configure -prt8.6; \
    else \
	/tmp/debian/configure -prxt8.6; \
    fi

# Directory for `mk-build-deps` apt repository
RUN mkdir /tmp/debs && \
    touch /tmp/debs/Sources

# Create deps package and local package repo
RUN if test $DISTRO = jessie; then \
        mk-build-deps --arch $DEBIAN_ARCH /tmp/debian/control; \
    else \
        mk-build-deps --build-arch $DEBIAN_ARCH --host-arch $DEBIAN_ARCH \
	    /tmp/debian/control; \
    fi \
    && mv *.deb /tmp/debs \
    && ( cd /tmp/debs && dpkg-scanpackages -m . > /tmp/debs/Packages )

# Add deps repo to apt sources for native builds
RUN if test $DEBIAN_ARCH = amd64; then \
	echo "deb file:///tmp/debs ./" > /etc/apt/sources.list.d/local.list \
	&& apt-get update; \
    fi


##############################
# Machinekit:  Host arch build environment

# Build "sysroot"
# - Select and unpack build dependency packages
RUN if test $DEBIAN_ARCH = amd64; then \
        echo "Installing native arch machinekit-build-deps package"; \
        apt-get install -y  -o Apt::Get::AllowUnauthenticated=true \
            machinekit-build-deps \
	&& apt-get clean \
	&& rm -rf /var/lib/apt/lists/*; \
    else \
        echo "Multistrapping from /tmp/multistrap-configs/$DISTRO.conf"; \
        multistrap -f /tmp/multistrap-configs/$DISTRO.conf \
	    -a $DEBIAN_ARCH -d $SYS_ROOT; \
    fi
# - Fix symlinks in "sysroot" libdir pointing to `/lib/$MULTIARCH`
RUN if ! test $DEBIAN_ARCH = amd64; then \
        for link in $(find $SYS_ROOT/usr/lib/${HOST_MULTIARCH}/ -type l); do \
            if test $(dirname $(readlink $link)) != .; then \
                ln -sf ../../../lib/${HOST_MULTIARCH}/$(basename \
                    $(readlink $link)) $link; \
            fi; \
        done; \
    fi
# - Link tcl/tk setup scripts
RUN test $DEBIAN_ARCH = amd64 || { \
        mkdir -p /usr/lib/${HOST_MULTIARCH} && \
        ln -s $SYS_ROOT/usr/lib/${HOST_MULTIARCH}/tcl8.6 \
            /usr/lib/${HOST_MULTIARCH} && \
        ln -s $SYS_ROOT/usr/lib/${HOST_MULTIARCH}/tk8.6 \
            /usr/lib/${HOST_MULTIARCH}; \
    }

# - Link directories with glib/gtk includes in the wrong place
RUN test $DEBIAN_ARCH = amd64 || { \
	ln -s $SYS_ROOT/usr/lib/${HOST_MULTIARCH}/glib-2.0 \
	    /usr/lib/${HOST_MULTIARCH}; \
	ln -s $SYS_ROOT/usr/lib/${HOST_MULTIARCH}/gtk-2.0 \
	    /usr/lib/${HOST_MULTIARCH}; \
    }

##############################
# Machinekit:  Build arch build environment

# Install Multi-Arch: foreign dependencies
RUN apt-get install -y \
        cython \
        uuid-runtime \
        protobuf-compiler \
        python-protobuf \
        python-pyftpdlib \
        python-tk \
        netcat-openbsd \
        tcl8.6 tk8.6 \
    && { test $DISTRO != jessie || apt-get install -y libxenomai-dev } \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Monkey-patch entire /usr/include, and re-add build-arch headers
RUN test $DEBIAN_ARCH = amd64 || { \
        mv /usr/include /usr/include.build && \
        ln -s $SYS_ROOT/usr/include /usr/include; \
	ln -sf /usr/include.build/x86_64-linux-gnu $SYS_ROOT/usr/include; \
    }


###########################################
# Set up environment
#
# Customize the following to match the user's environment

# Set up user ID inside container to match your ID
ENV USER=travis
ENV UID=1000
ENV GID=1000
ENV HOME=/home/${USER}
ENV SHELL=/bin/bash
ENV PATH=/usr/lib/ccache:/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/bin
RUN echo "${USER}:x:${UID}:${GID}::${HOME}:${SHELL}" >> /etc/passwd
RUN echo "${USER}:x:${GID}:" >> /etc/group

# Customize the run environment to your taste
# - bash prompt
# - 'ls' alias
RUN sed -i /etc/bash.bashrc \
    -e 's/^PS1=.*/PS1="\\h:\\W\\$ "/' \
    -e '$a alias ls="ls -aFs"'

# Configure sudo, passwordless for everyone
RUN echo "ALL	ALL=(ALL:ALL) NOPASSWD: ALL" >> /etc/sudoers
