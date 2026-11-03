package application

import "testing"

func TestAdherenceRatesKeepUnknownAndOmittedDistinct(t *testing.T) {
	c := AdherenceCounts{Evaluable: 8, Taken: 2, TakenLate: 1, Skipped: 2, Unconfirmed: 3, Punctual: 1}
	c.rates()
	if c.Confirmed != 5 || *c.AdherenceRate != 3.0/8 || *c.ConfirmationRate != 5.0/8 || *c.PunctualityRate != 1.0/3 || *c.UnconfirmedRate != 3.0/8 {
		t.Fatal(c)
	}
	empty := AdherenceCounts{}
	empty.rates()
	if empty.AdherenceRate != nil || empty.ConfirmationRate != nil || empty.PunctualityRate != nil || empty.UnconfirmedRate != nil {
		t.Fatal(empty)
	}
	skipped := AdherenceCounts{Evaluable: 1, Skipped: 1}
	skipped.rates()
	if *skipped.ConfirmationRate != 1 || *skipped.AdherenceRate != 0 || skipped.PunctualityRate != nil {
		t.Fatal(skipped)
	}
}
func TestReportRangeCalendarMonthsAndLimits(t *testing.T) {
	for _, c := range []struct {
		from, to string
		valid    bool
	}{{"2026-10-01", "2026-11-01", true}, {"2024-01-01", "2025-01-01", true}, {"2024-01-01", "2025-01-02", false}, {"2026-02-30", "2026-03-02", false}, {"2026-11-02", "2026-11-02", false}} {
		_, _, err := reportRange(c.from, c.to)
		if (err == nil) != c.valid {
			t.Fatal(c, err)
		}
	}
}
