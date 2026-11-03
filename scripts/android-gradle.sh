#!/bin/sh
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
if [ -z "${JAVA_HOME:-}" ] && [ -d "$ROOT/.tmp/android-tools/jdk-21.0.13+9/Contents/Home" ]; then
    JAVA_HOME="$ROOT/.tmp/android-tools/jdk-21.0.13+9/Contents/Home"
    export JAVA_HOME
fi
if ! java -version >/dev/null 2>&1 && [ -z "${JAVA_HOME:-}" ]; then
    echo 'Install JDK 21 and set JAVA_HOME before building Android.' >&2
    exit 1
fi
if [ -z "${ANDROID_HOME:-}" ] && [ -d "$ROOT/.tmp/android-sdk/platforms" ]; then
    ANDROID_HOME="$ROOT/.tmp/android-sdk"
    export ANDROID_HOME
fi
if [ -z "${ANDROID_HOME:-}" ] && [ ! -f "$ROOT/apps/android/local.properties" ]; then
    echo 'Install Android SDK 37 and set ANDROID_HOME or apps/android/local.properties.' >&2
    exit 1
fi
GRADLE_USER_HOME=${GRADLE_USER_HOME:-"$ROOT/.tmp/gradle-home"}
export GRADLE_USER_HOME
cd "$ROOT/apps/android"
exec ./gradlew --console=plain "$@"
