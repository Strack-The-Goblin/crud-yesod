FROM debian:bookworm-slim AS build

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential ca-certificates curl git \
        libgmp-dev libncurses-dev libpq-dev libtinfo5 zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

RUN curl --fail --location --retry 3 \
        https://github.com/commercialhaskell/stack/releases/download/v3.11.1/stack-3.11.1-linux-x86_64.tar.gz \
        --output /tmp/stack.tar.gz \
    && echo '1fda71e657cd8d355625cc66b61b352699279dfee2664c014a392163bd19a952  /tmp/stack.tar.gz' | sha256sum --check - \
    && tar -xzf /tmp/stack.tar.gz -C /tmp \
    && install -m 0755 /tmp/stack-3.11.1-linux-x86_64/stack /usr/local/bin/stack \
    && rm -rf /tmp/stack.tar.gz /tmp/stack-3.11.1-linux-x86_64 \
    && stack --version

ENV LANG=C.UTF-8
WORKDIR /build

COPY stack.yaml stack.yaml.lock package.yaml ./
COPY app ./app
COPY test ./test
COPY src ./src
COPY config ./config
COPY templates ./templates
COPY static ./static

RUN stack --jobs 2 build \
        --flag meu-crud:-dev --flag meu-crud:-library-only \
        --copy-bins --local-bin-path /out

FROM debian:bookworm-slim AS runtime

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates libgmp10 libpq5 libtinfo5 libtinfo6 zlib1g \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --uid 10001 app

ENV LANG=C.UTF-8 \
    YESOD_HOST=0.0.0.0 \
    YESOD_PORT=3000
WORKDIR /app

COPY --from=build /out/meu-crud /usr/local/bin/meu-crud
COPY --chown=app:app config/settings.yml ./config/settings.yml
COPY --chown=app:app static ./static

RUN mkdir -p static/tmp static/combined \
    && chown -R app:app /app

USER app
EXPOSE 3000

ENTRYPOINT ["/bin/sh", "-c", "set -eu; export YESOD_PORT=\"${PORT:-${YESOD_PORT}}\"; if [ ! -s /etc/secrets/client_session_key.aes ]; then echo 'Missing session key: mount /etc/secrets/client_session_key.aes' >&2; exit 1; fi; cp /etc/secrets/client_session_key.aes config/client_session_key.aes; exec /usr/local/bin/meu-crud \"$@\"", "--"]
CMD ["config/settings.yml"]
