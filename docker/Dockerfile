# One image per Postgres major: the throwaway restore server must be at least
# as new as the server the backup came from. EXTRAS=1 adds PostGIS and pgvector.
ARG PG_MAJOR=16
FROM postgres:${PG_MAJOR}-bookworm
ARG PG_MAJOR
ARG EXTRAS=

RUN apt-get update \
 && apt-get install -y --no-install-recommends ruby \
    ${EXTRAS:+postgresql-${PG_MAJOR}-postgis-3 postgresql-${PG_MAJOR}-pgvector} \
 && rm -rf /var/lib/apt/lists/*

COPY lib /opt/pgdrill/lib
COPY exe /opt/pgdrill/exe

ENV PATH=/usr/lib/postgresql/${PG_MAJOR}/bin:/opt/pgdrill/exe:$PATH
WORKDIR /work
# initdb refuses to run as root
USER postgres
ENTRYPOINT ["pgdrill"]
