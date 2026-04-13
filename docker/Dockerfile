FROM debian:12-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        iputils-ping \
        iproute2 \
        iptables \
        procps \
        wireguard-tools \
    && rm -rf /var/lib/apt/lists/*

COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh

RUN chmod +x /usr/local/bin/entrypoint.sh \
    && mkdir -p /etc/wireguard /var/lib/wireguard

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
