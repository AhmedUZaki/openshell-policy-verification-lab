FROM ubuntu:24.04

COPY caddy-root.crt /usr/local/share/ca-certificates/openshell-policy-lab-caddy.crt

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
       bash ca-certificates coreutils curl iproute2 python3 \
    && update-ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 1500 tester \
    && useradd --uid 1500 --gid 1500 --create-home --shell /bin/bash tester \
    && mkdir -p /work \
    && chown -R tester:tester /work

USER tester:tester
WORKDIR /work
CMD ["sleep", "infinity"]
