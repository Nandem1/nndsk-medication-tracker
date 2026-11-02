package domain

import (
	"crypto/rand"
	"errors"
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"time"
)

var ErrInvalid = errors.New("invalid domain input")

type Quantity int64

const MaxQuantity Quantity = 999999999999

var decimalPattern = regexp.MustCompile(`^-?[0-9]+(?:\.[0-9]{1,3})?$`)
var idPattern = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)

func ValidID(s string) bool { return idPattern.MatchString(s) }
func NewID() string {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	b[6] = (b[6] & 15) | 64
	b[8] = (b[8] & 63) | 128
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[:4], b[4:6], b[6:8], b[8:10], b[10:])
}
func ParseQuantity(s string) (Quantity, error) {
	if !decimalPattern.MatchString(s) {
		return 0, ErrInvalid
	}
	negative := strings.HasPrefix(s, "-")
	s = strings.TrimPrefix(s, "-")
	p := strings.Split(s, ".")
	fraction := "000"
	if len(p) == 2 {
		fraction = (p[1] + "000")[:3]
	}
	n, err := strconv.ParseInt(p[0]+fraction, 10, 64)
	if err != nil || n > int64(MaxQuantity) {
		return 0, ErrInvalid
	}
	if negative {
		n = -n
	}
	return Quantity(n), nil
}
func (q Quantity) String() string {
	sign := ""
	n := int64(q)
	if n < 0 {
		sign = "-"
		n = -n
	}
	return fmt.Sprintf("%s%d.%03d", sign, n/1000, n%1000)
}
func (q Quantity) Valid() bool { return q >= -MaxQuantity && q <= MaxQuantity }

type DoseState string

const (
	Pending   DoseState = "pending"
	Taken     DoseState = "taken"
	TakenLate DoseState = "taken_late"
	Skipped   DoseState = "skipped"
)

func (s DoseState) Declaration() bool { return s == Taken || s == TakenLate || s == Skipped }
func (s DoseState) Consumes() bool    { return s == Taken || s == TakenLate }
func (s DoseState) Display(at, now time.Time) string {
	if s == Pending && at.Before(now) {
		return "unconfirmed"
	}
	return string(s)
}
