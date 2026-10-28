FROM debian:trixie-slim AS build
RUN apt-get update && apt-get install -y --no-install-recommends gcc libc6-dev
COPY Backend /src
RUN gcc -std=gnu17 -O2 /src/main.c -o /worker -lpthread -lm -ldl
FROM debian:trixie-slim
RUN apt-get update && apt-get install -y --no-install-recommends linux-perf ca-certificates && rm -rf /var/lib/apt/lists/*
COPY --from=build /worker /usr/local/bin/worker
COPY web /app/web
COPY bundles /app/bundles
ENV OUTER_CONTAINER_REGISTRY=/state/registry.bin
CMD ["sh", "-c", "exec /usr/local/bin/worker --port 7356 --bundles-dir /app/bundles --web-root /app/web --state-dir /state/profiles"]
