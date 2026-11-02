package domain

import (
	"testing"
	"time"
)

func TestQuantityExact(t *testing.T) {
	for _, s := range []string{"0.001", "0.500", "999999999.999", "-0.001"} {
		q, err := ParseQuantity(s)
		if err != nil || q.String() != s {
			t.Fatalf("%s: %v %v", s, q, err)
		}
	}
	for _, s := range []string{"NaN", "1e3", "0.0001", "1000000000", "", "1.", "+1"} {
		if _, err := ParseQuantity(s); err == nil {
			t.Fatalf("accepted %q", s)
		}
	}
	a, _ := ParseQuantity("0.100")
	b, _ := ParseQuantity("0.200")
	if (a + b).String() != "0.300" {
		t.Fatal("inexact sum")
	}
}
func TestScheduleDSTAndCalendar(t *testing.T) {
	cases := []struct{ date, clock, zone, want string }{
		{"2026-09-06", "00:30", "America/Santiago", "2026-09-06T04:00:00Z"},
		{"2026-04-04", "23:30", "America/Santiago", "2026-04-05T02:30:00Z"},
		{"2026-03-08", "02:30", "America/New_York", "2026-03-08T07:00:00Z"},
		{"2026-11-01", "01:30", "America/New_York", "2026-11-01T05:30:00Z"},
	}
	for _, c := range cases {
		t.Run(c.date+c.zone, func(t *testing.T) {
			s := Schedule{Timezone: c.zone, Policy: NextValidEarliest, Slots: []Slot{{Time: c.clock, Quantity: 500}}, Weekdays: []time.Weekday{0, 1, 2, 3, 4, 5, 6}}
			got, err := s.Occurrences(c.date, 1)
			if err != nil || len(got) != 1 || got[0].At.Format(time.RFC3339) != c.want {
				t.Fatalf("%v %v want %s", got, err, c.want)
			}
			s.Policy = RejectDST
			if _, err = s.Occurrences(c.date, 1); err == nil {
				t.Fatal("DST policy did not reject")
			}
		})
	}
	s := Schedule{Timezone: "UTC", Policy: RejectDST, Slots: []Slot{{Time: "08:00", Quantity: 500}}, Weekdays: []time.Weekday{0, 1, 2, 3, 4, 5, 6}}
	got, err := s.Occurrences("2028-02-28", 3)
	if err != nil || len(got) != 3 || got[2].Date != "2028-03-01" {
		t.Fatalf("calendar %v %v", got, err)
	}
	s.Weekdays = []time.Weekday{time.Monday}
	got, err = s.Occurrences("2026-11-01", 7)
	if err != nil || len(got) != 1 || got[0].Date != "2026-11-02" {
		t.Fatal(got, err)
	}
}
func TestScheduleValidationAndCollision(t *testing.T) {
	s := Schedule{Timezone: "America/Santiago", Policy: NextValidEarliest, Weekdays: []time.Weekday{0}, Slots: []Slot{{Time: "00:15", Quantity: 500}, {Time: "00:30", Quantity: 500}}}
	if _, err := s.Occurrences("2026-09-06", 1); err == nil {
		t.Fatal("colliding resolved doses accepted")
	}
	s.Slots = []Slot{{Time: "08:00", Quantity: 500}}
	s.Policy = ""
	if err := s.Validate(); err == nil {
		t.Fatal("implicit DST policy")
	}
}

func TestUnconfirmedIsDerivedAndNotSkipped(t *testing.T) {
	past := time.Date(2026, 11, 1, 0, 0, 0, 0, time.UTC)
	now := past.Add(time.Hour)
	if Pending.Display(past, now) != "unconfirmed" || Pending.Display(now, past) != "pending" || Skipped.Display(past, now) != "skipped" {
		t.Fatal("declarations mixed with lack of response")
	}
}
func TestInactiveRevisionDoesNotRejectDST(t *testing.T) {
	s := Schedule{Timezone: "America/Santiago", Policy: RejectDST, Weekdays: []time.Weekday{0, 1, 2, 3, 4, 5, 6}, Slots: []Slot{{Time: "00:30", Quantity: 500}}}
	until := time.Date(2026, 9, 5, 0, 0, 0, 0, time.UTC)
	got, err := s.OccurrencesInWindow("2026-09-01", 30, ScheduleWindow{Until: &until})
	if err != nil || len(got) != 4 {
		t.Fatal(got, err)
	}
	got, err = s.OccurrencesInWindow("2026-09-01", 30, ScheduleWindow{StartsOn: "2026-09-07"})
	if err != nil || len(got) != 24 {
		t.Fatal(got, err)
	}
	if _, err = ParseDate("0000-01-01"); err == nil {
		t.Fatal("PostgreSQL-incompatible date accepted")
	}
}
