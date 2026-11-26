# apt-cacher-ng from Ubuntu's archive, for the test hosts' apt over http.
FROM ubuntu:24.04
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends apt-cacher-ng ca-certificates \
 && rm -rf /var/lib/apt/lists/*
COPY acng.conf /etc/apt-cacher-ng/zz-noixdev.conf
EXPOSE 3142
CMD ["sh", "-c", "mkdir -p /run/apt-cacher-ng /var/log/apt-cacher-ng && chown apt-cacher-ng /run/apt-cacher-ng /var/log/apt-cacher-ng /var/cache/apt-cacher-ng && exec /usr/sbin/apt-cacher-ng -c /etc/apt-cacher-ng ForeGround=1"]
