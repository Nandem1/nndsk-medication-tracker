package domain

import (
	"fmt"
	"sort"
	"time"
	_ "time/tzdata"
)

const HorizonDays = 30

type DSTPolicy string

const (
	RejectDST         DSTPolicy = "reject"
	NextValidEarliest DSTPolicy = "next_valid_earliest"
)

type Slot struct {
	Time     string
	Quantity Quantity
}
type Schedule struct {
	Timezone string
	Policy   DSTPolicy
	Weekdays []time.Weekday
	Slots    []Slot
}
type Occurrence struct {
	At        time.Time
	Date      string
	LocalTime string
	Quantity  Quantity
	Adjusted  bool
}

func ParseDate(s string) (time.Time, error) {
	d, e := time.Parse("2006-01-02", s)
	if e != nil || d.Year() < 1 || d.Format("2006-01-02") != s {
		return time.Time{}, ErrInvalid
	}
	return d, nil
}
func (s Schedule) Validate() error {
	if s.Timezone == "" || s.Timezone == "Local" {
		return ErrInvalid
	}
	if _, e := time.LoadLocation(s.Timezone); e != nil {
		return ErrInvalid
	}
	if s.Policy != RejectDST && s.Policy != NextValidEarliest {
		return ErrInvalid
	}
	if len(s.Slots) == 0 || len(s.Slots) > 24 || len(s.Weekdays) == 0 || len(s.Weekdays) > 7 {
		return ErrInvalid
	}
	days := map[time.Weekday]bool{}
	for _, d := range s.Weekdays {
		if d < 0 || d > 6 || days[d] {
			return ErrInvalid
		}
		days[d] = true
	}
	slots := map[string]bool{}
	for _, slot := range s.Slots {
		t, e := time.Parse("15:04", slot.Time)
		if e != nil || t.Format("15:04") != slot.Time || slots[slot.Time] || slot.Quantity <= 0 || !slot.Quantity.Valid() {
			return ErrInvalid
		}
		slots[slot.Time] = true
	}
	return nil
}

type ScheduleWindow struct {
	StartsOn string
	EndsOn   string
	From     time.Time
	Until    *time.Time
}

func (w ScheduleWindow) contains(at time.Time) bool {
	return !at.Before(w.From) && (w.Until == nil || at.Before(*w.Until))
}
func (s Schedule) Occurrences(from string, days int) ([]Occurrence, error) {
	return s.OccurrencesInWindow(from, days, ScheduleWindow{})
}
func (s Schedule) OccurrencesInWindow(from string, days int, w ScheduleWindow) ([]Occurrence, error) {
	if e := s.Validate(); e != nil {
		return nil, e
	}
	date, e := ParseDate(from)
	if e != nil || days < 1 || days > HorizonDays {
		return nil, ErrInvalid
	}
	loc, _ := time.LoadLocation(s.Timezone)
	selected := map[time.Weekday]bool{}
	for _, d := range s.Weekdays {
		selected[d] = true
	}
	result := []Occurrence{}
	seen := map[int64]bool{}
	for i := 0; i < days; i++ {
		d := date.AddDate(0, 0, i)
		localDate := d.Format("2006-01-02")
		if localDate < w.From.In(loc).Format("2006-01-02") || (w.Until != nil && localDate > w.Until.In(loc).Format("2006-01-02")) {
			continue
		}
		if !selected[d.Weekday()] || (w.StartsOn != "" && d.Format("2006-01-02") < w.StartsOn) || (w.EndsOn != "" && d.Format("2006-01-02") > w.EndsOn) {
			continue
		}
		for _, slot := range s.Slots {
			at, latest, adjusted, e := resolve(d, slot.Time, loc)
			if e != nil {
				return nil, e
			}
			if !w.contains(at) && !w.contains(latest) {
				continue
			}
			if adjusted && s.Policy == RejectDST {
				return nil, fmt.Errorf("%w: ambiguous or nonexistent local time", ErrInvalid)
			}
			if !w.contains(at) {
				continue
			}
			if seen[at.Unix()] {
				return nil, fmt.Errorf("%w: DST resolution collides with another slot", ErrInvalid)
			}
			seen[at.Unix()] = true
			result = append(result, Occurrence{At: at, Date: d.Format("2006-01-02"), LocalTime: slot.Time, Quantity: slot.Quantity, Adjusted: adjusted})
		}
	}
	sort.Slice(result, func(i, j int) bool { return result[i].At.Before(result[j].At) })
	return result, nil
}
func resolve(date time.Time, clock string, loc *time.Location) (time.Time, time.Time, bool, error) {
	parsed, _ := time.Parse("15:04", clock)
	wall := time.Date(date.Year(), date.Month(), date.Day(), parsed.Hour(), parsed.Minute(), 0, 0, time.UTC)
	offsets := map[int]bool{}
	for h := -48; h <= 48; h += 6 {
		_, off := wall.Add(time.Duration(h) * time.Hour).In(loc).Zone()
		offsets[off] = true
	}
	matches := []time.Time{}
	for off := range offsets {
		candidate := wall.Add(-time.Duration(off) * time.Second)
		local := candidate.In(loc)
		if local.Format("2006-01-02 15:04") == wall.Format("2006-01-02 15:04") {
			matches = append(matches, candidate)
		}
	}
	sort.Slice(matches, func(i, j int) bool { return matches[i].Before(matches[j]) })
	if len(matches) == 1 {
		return matches[0], matches[0], false, nil
	}
	if len(matches) > 1 {
		return matches[0], matches[len(matches)-1], true, nil
	}
	// Search UTC instants so a missing wall time cannot normalize into the previous day.
	start := wall.Add(-26 * time.Hour)
	var best time.Time
	bestClock := ""
	for i := 0; i <= 52*60; i++ {
		candidate := start.Add(time.Duration(i) * time.Minute)
		local := candidate.In(loc)
		if local.Format("2006-01-02") != date.Format("2006-01-02") {
			continue
		}
		c := local.Format("15:04")
		if c >= clock && (best.IsZero() || c < bestClock) {
			best = candidate
			bestClock = c
		}
	}
	if best.IsZero() {
		return time.Time{}, time.Time{}, false, ErrInvalid
	}
	return best, best, true, nil
}

func StartOfDay(date string, loc *time.Location) (time.Time, error) {
	d, err := ParseDate(date)
	if err != nil {
		return time.Time{}, err
	}
	at, _, _, err := resolve(d, "00:00", loc)
	return at, err
}
