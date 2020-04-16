# syntax=docker/dockerfile:1
FROM centos:8 AS base
#FROM registry.access.redhat.com/ubi8:8.1
LABEL maintainer "thomasmckay@redhat.com"

ENV OS=linux \
    ARCH=amd64 \
    PYTHON_VERSION=3.6 \
    PATH=$HOME/.local/bin/:$PATH \
    PYTHONUNBUFFERED=1 \
    PYTHONIOENCODING=UTF-8 \
    LC_ALL=C.UTF-8 \
    LANG=C.UTF-8 \
    PIP_NO_CACHE_DIR=off
# This is the magic that lets us just copy out all of our installed python
# packages later.
ENV PYTHONUSERBASE=/opt/quay
ENV QUAYDIR /quay-registry
ENV QUAYCONF /quay-registry/conf
ENV QUAYPATH "."
WORKDIR $QUAYDIR

# Don't run yum update, pull the base image to update.
RUN yum -y --setopt=tsflags=nodocs --setopt=skip_missing_names_on_install=False install\
        python3\
        nginx\
        openldap\
        python3-gpg\
        dnsmasq\
        memcached\
        openssl\
        skopeo\
	 && \
    yum -y clean all
RUN alternatives --set python /usr/bin/python3

FROM base AS build
# Trade a bit of startup time for space.
ENV PYTHONDONTWRITEBYTECODE 1

RUN curl --silent --location https://rpm.nodesource.com/setup_12.x | bash -
RUN curl --silent --location https://dl.yarnpkg.com/rpm/yarn.repo > /etc/yum.repos.d/yarn.repo &&\
    rpm --import https://dl.yarnpkg.com/rpm/pubkey.gpg
RUN dnf install -y\
	gcc-c++\
	git\
	nodejs\
	openldap-devel\
	python3-devel\
	yarn\
	;
RUN python3 -m pip install --user --upgrade setuptools pip

# The basic strategy here is to break the steps into the smallest complete
# units, then put the bits that change the least frequently earlier.
FROM build AS build-static
WORKDIR /build
RUN mkdir -p static/{webfonts,fonts,ldn}
COPY external_libraries.py _init.py .
RUN PYTHONPATH=$QUAYPATH python3 -m external_libraries

FROM build AS build-deps
WORKDIR /build
COPY requirements.txt .
RUN python3 -m pip install --user -r requirements.txt --no-cache --no-warn-script-location

COPY *.json *.js yarn.lock .
RUN yarn install --ignore-engines
COPY static static
RUN yarn build
COPY config_app config_app
RUN yarn build-config-app

FROM build AS build-jwtproxy
ARG JWTPROXY_VERSION=0.0.3
RUN curl -fsSL -o jwtproxy "https://github.com/coreos/jwtproxy/releases/download/v${JWTPROXY_VERSION}/jwtproxy-${OS}-${ARCH}" &&\
	install -d /usr/local/bin && install jwtproxy /usr/local/bin

FROM build AS build-pushgateway
ARG PUSHGATEWAY_VERSION=1.0.0
RUN curl -fsSL "https://github.com/prometheus/pushgateway/releases/download/v${PUSHGATEWAY_VERSION}/pushgateway-${PUSHGATEWAY_VERSION}.${OS}-${ARCH}.tar.gz" |\
    tar xzO "pushgateway-${PUSHGATEWAY_VERSION}.${OS}-${ARCH}/pushgateway" >pushgateway &&\
	install -d /usr/local/bin && install pushgateway /usr/local/bin

FROM base AS final
COPY --from=build-static /build/static/webfonts $QUAYDIR/static/webfonts
COPY --from=build-static /build/static/fonts $QUAYDIR/static/fonts
COPY --from=build-static /build/static/ldn $QUAYDIR/static/ldn
COPY --from=build-static /build/static/webfonts $QUAYDIR/config_app/static/webfonts
COPY --from=build-static /build/static/fonts $QUAYDIR/config_app/static/fonts
COPY --from=build-static /build/static/ldn $QUAYDIR/config_app/static/ldn
COPY --from=build-jwtproxy /usr/local/bin/jwtproxy /usr/local/bin/jwtproxy
COPY --from=build-pushgateway /usr/local/bin/pushgateway /usr/local/bin/pushgateway
COPY --from=build-deps $PYTHONUSERBASE $PYTHONUSERBASE
COPY --from=build-deps /build $QUAYDIR

RUN chgrp -R 0 $QUAYDIR && \
    chmod -R g=u $QUAYDIR
RUN mkdir /datastorage && chgrp 0 /datastorage && chmod g=u /datastorage && \
    chgrp 0 /var/log/nginx && chmod g=u /var/log/nginx && \
    mkdir -p /conf/stack && chgrp 0 /conf/stack && chmod g=u /conf/stack && \
    mkdir -p /tmp && chgrp 0 /tmp && chmod g=u /tmp && \
    mkdir /certificates && chgrp 0 /certificates && chmod g=u /certificates && \
    chmod g=u /etc/passwd
RUN ln -s $QUAYCONF /conf && \
    ln -sf /dev/stdout /var/log/nginx/access.log && \
    ln -sf /dev/stdout /var/log/nginx/error.log && \
    chmod -R a+rwx /var/log/nginx

COPY . .
# Update local copy of AWS IP Ranges.
ADD https://ip-ranges.amazonaws.com/ip-ranges.json util/ipresolver/aws-ip-ranges.json

ENV PATH=$PYTHONUSERBASE/bin:$PATH
EXPOSE 8080 8443 7443 9091
VOLUME ["/var/log", "/datastorage", "/tmp", "/conf/stack"]
ENTRYPOINT ["/quay-registry/quay-entrypoint.sh"]
CMD ["registry"]

# root required to create and install certs
# https://jira.coreos.com/browse/QUAY-1468
# USER 1001
