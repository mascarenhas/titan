#!/bin/sh

if [ "$FAKE_LIBUV_MISSING" = "1" ]; then
    exit 1
fi

case "$1" in
    --exists)
        exit 0
        ;;
    --atleast-version=*)
        exit 0
        ;;
    --modversion)
        echo 1.52.1
        ;;
    --cflags)
        echo "-I/opt/libuv/include -DUV_FAKE_PKG=1"
        ;;
    --libs)
        echo "-L/opt/libuv/lib -luv -pthread -ldl -lrt"
        ;;
    *)
        echo "unexpected fake pkg-config arguments: $*" >&2
        exit 2
        ;;
esac
