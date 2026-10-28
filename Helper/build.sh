#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
os=${1:?usage: build.sh linux ARCH OUTPUT}
arch=${2:?usage: build.sh linux ARCH OUTPUT}
output=${3:?usage: build.sh linux ARCH OUTPUT}
case "$arch" in aarch64) arch=arm64;; x86_64) arch=amd64;; esac
case "$os/$arch" in linux/arm64|linux/amd64) ;; *) echo "Unsupported helper target: $os/$arch" >&2; exit 1;; esac
case "$output" in /*) ;; *) output="$PWD/$output";; esac
mkdir -p "$(dirname "$output")"
if [ -n "${CC:-}" ]; then
    "$CC" -std=gnu17 -O2 -static "$root/Backend/main.c" -lpthread -lm -o "$output"
else
    temporary=$(mktemp -d)
    trap 'rm -rf "$temporary"' EXIT HUP INT TERM
    runtime=${OUTER_BUILD_CONTAINER_RUNTIME:-auto}
    if [ "$runtime" = auto ]; then
        if command -v container >/dev/null 2>&1 && container system status >/dev/null 2>&1; then
            runtime=container
        else
            runtime=docker
        fi
    fi
    case "$runtime" in container|docker) ;; *) echo "Expected OUTER_BUILD_CONTAINER_RUNTIME=container or docker" >&2; exit 1;; esac
    "$runtime" build --platform "linux/$arch" -f "$root/Helper/Dockerfile" --output "type=local,dest=$temporary" "$root"
    helper="$temporary/outer-profile-helper"
    if [ ! -f "$helper" ] && [ "$runtime" = container ]; then
        helper="$temporary/out.tar/linux_$arch/outer-profile-helper"
    fi
    install -m 755 "$helper" "$output"
fi
