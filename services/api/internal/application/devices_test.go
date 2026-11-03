package application

import (
	"testing"
	"time"
)

func TestQuietHoursAcrossMidnightAndSantiagoDST(t *testing.T) {
	start, end := 22*60, 7*60
	p := AlertPreferences{MinIntervalMinutes: 15, Timezone: "America/Santiago", QuietStartMinute: &start, QuietEndMinute: &end}
	if err := p.validate(); err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		instant string
		quiet   bool
	}{{"2026-09-06T03:30:00Z", true}, {"2026-09-06T04:30:00Z", true}, {"2026-09-06T10:00:00Z", false}, {"2026-04-05T03:30:00Z", true}, {"2026-04-05T04:30:00Z", true}} {
		at, err := time.Parse(time.RFC3339, tc.instant)
		if err != nil {
			t.Fatal(err)
		}
		if p.quiet(at) != tc.quiet {
			t.Fatal(tc)
		}
	}
}
