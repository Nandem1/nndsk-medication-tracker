#!/bin/sh
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
case "${ANDROID_SERIAL:-}" in emulator-*) ;; *) echo 'This automatic reboot test requires ANDROID_SERIAL=emulator-.... Run the physical-device checklist manually.' >&2; exit 1;; esac
SDK=${ANDROID_HOME:-"$ROOT/.tmp/android-sdk"}
ADB="$SDK/platform-tools/adb"
cd "$ROOT"
sh scripts/android-gradle.sh :app:assembleE2e :app:assembleE2eAndroidTest -PtestBuildType=e2e
"$ADB" -s "$ANDROID_SERIAL" install -r apps/android/app/build/outputs/apk/e2e/app-e2e.apk
"$ADB" -s "$ANDROID_SERIAL" install -r apps/android/app/build/outputs/apk/androidTest/e2e/app-e2e-androidTest.apk
"$ADB" -s "$ANDROID_SERIAL" shell pm grant cl.nndsk.medication.e2e android.permission.POST_NOTIFICATIONS
"$ADB" -s "$ANDROID_SERIAL" shell cmd appops set cl.nndsk.medication.e2e SCHEDULE_EXACT_ALARM allow
mkdir -p .tmp/android-reboot
run_test() {
    "$ADB" -s "$ANDROID_SERIAL" shell am instrument -w -e class "cl.nndsk.medication.core.RebootReminderTest#$1" cl.nndsk.medication.e2e.test/androidx.test.runner.AndroidJUnitRunner > ".tmp/android-reboot/$1.log"
    rg -q 'OK \(1 test\)' ".tmp/android-reboot/$1.log" || { cat ".tmp/android-reboot/$1.log"; exit 1; }
}
run_test prepare
"$ADB" -s "$ANDROID_SERIAL" shell am start -W -n cl.nndsk.medication.e2e/cl.nndsk.medication.MainActivity >/dev/null
"$ADB" -s "$ANDROID_SERIAL" shell input keyevent KEYCODE_HOME
"$ADB" -s "$ANDROID_SERIAL" shell am kill cl.nndsk.medication.e2e
"$ADB" -s "$ANDROID_SERIAL" reboot
"$ADB" -s "$ANDROID_SERIAL" wait-for-device
count=0
until [ "$("$ADB" -s "$ANDROID_SERIAL" shell getprop sys.boot_completed | tr -d '\r')" = 1 ]; do
    count=$((count + 1)); [ "$count" -lt 120 ] || { echo 'Emulator did not complete reboot.' >&2; exit 1; }
    sleep 1
done
"$ADB" -s "$ANDROID_SERIAL" shell input keyevent KEYCODE_WAKEUP
"$ADB" -s "$ANDROID_SERIAL" shell wm dismiss-keyguard
count=0
until "$ADB" -s "$ANDROID_SERIAL" shell dumpsys notification | rg 'NotificationRecord.*cl.nndsk.medication.e2e.*synthetic-reboot-dose' > .tmp/android-reboot/delivered.log; do
    count=$((count + 1)); [ "$count" -lt 180 ] || { echo 'No notification observed after reboot.' >&2; exit 1; }
    sleep 1
done
"$ADB" -s "$ANDROID_SERIAL" shell pm clear cl.nndsk.medication.e2e >/dev/null
printf 'PASS: alarm delivered after emulator reboot.\n'
