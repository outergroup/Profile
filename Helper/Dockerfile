FROM alpine:3.22 AS build
RUN apk add --no-cache build-base linux-headers
COPY Backend /src
RUN cc -std=gnu17 -O2 -static /src/main.c -lpthread -lm -o /outer-profile-helper
FROM scratch
COPY --from=build /outer-profile-helper /outer-profile-helper
