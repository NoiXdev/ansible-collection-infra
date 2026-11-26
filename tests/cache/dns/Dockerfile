# dnsmasq from Ubuntu's archive: the test hosts' resolver, logging every query
# for the report of what went past the caches.
FROM ubuntu:24.04
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends dnsmasq-base \
 && rm -rf /var/lib/apt/lists/*
COPY dnsmasq.conf /etc/noixdev-dnsmasq.conf
EXPOSE 53/udp 53/tcp
# Forward to the resolver Docker gives this container.
CMD ["sh", "-c", "mkdir -p /var/log/noix-dns && up=$(awk '/^nameserver/ { print $2; exit }' /etc/resolv.conf) && exec dnsmasq --keep-in-foreground --conf-file=/etc/noixdev-dnsmasq.conf --server=\"$up\""]
