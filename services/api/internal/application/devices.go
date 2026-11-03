package application

import (
	"context"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"medication-tracker/services/api/internal/domain"
)

type DeviceInput struct {
	ID         string `json:"device_id"`
	Platform   string `json:"platform"`
	Token      string `json:"token"`
	Permission string `json:"permission"`
}
type Device struct {
	ID         string    `json:"device_id"`
	Platform   string    `json:"platform"`
	Permission string    `json:"permission"`
	ExpiresAt  time.Time `json:"expires_at"`
}

func (s *Service) RegisterDevice(ctx context.Context, actor string, in DeviceInput) (Device, error) {
	var out Device
	if !domain.ValidID(actor) || !domain.ValidID(in.ID) || (in.Platform != "apns" && in.Platform != "fcm") || len(in.Token) > 4096 || strings.ContainsAny(in.Token, " \r\n\t") {
		return out, ErrInvalid
	}
	switch in.Permission {
	case "granted":
		if in.Token == "" {
			return out, ErrInvalid
		}
	case "denied", "unknown":
		in.Token = ""
	default:
		return out, ErrInvalid
	}
	if in.Platform == "apns" && in.Token != "" {
		if len(in.Token) < 32 || len(in.Token) > 512 || len(in.Token)%2 != 0 {
			return out, ErrInvalid
		}
		for _, r := range in.Token {
			if !strings.ContainsRune("0123456789abcdefABCDEF", r) {
				return out, ErrInvalid
			}
		}
		in.Token = strings.ToLower(in.Token)
	}
	now := s.now().UTC()
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return out, err
	}
	defer tx.Rollback(ctx)
	if in.Token != "" {
		_, err = tx.Exec(ctx, `UPDATE device_registrations SET revoked_at=$3,permission='denied',token='',revision=revision+1 WHERE platform=$1 AND token=$2 AND revoked_at IS NULL AND expires_at<=$3`, in.Platform, in.Token, now)
		if err != nil {
			return out, err
		}
	}
	err = tx.QueryRow(ctx, `INSERT INTO device_registrations(id,user_id,platform,token,permission,expires_at,updated_at) VALUES($1,$2,$3,$4,$5,$6,$7)
 ON CONFLICT(id) DO UPDATE SET platform=excluded.platform,token=excluded.token,permission=excluded.permission,expires_at=excluded.expires_at,updated_at=excluded.updated_at,revoked_at=NULL,
 revision=device_registrations.revision+CASE WHEN (device_registrations.platform,device_registrations.token,device_registrations.permission,device_registrations.revoked_at IS NULL) IS DISTINCT FROM (excluded.platform,excluded.token,excluded.permission,true) THEN 1 ELSE 0 END
 WHERE device_registrations.user_id=excluded.user_id RETURNING id::text,platform,permission,expires_at`, in.ID, actor, in.Platform, in.Token, in.Permission, now.Add(30*24*time.Hour), now).Scan(&out.ID, &out.Platform, &out.Permission, &out.ExpiresAt)
	if err != nil {
		return out, translate(err)
	}
	return out, tx.Commit(ctx)
}
func (s *Service) DeleteDevice(ctx context.Context, actor, id string) error {
	if !domain.ValidID(actor) || !domain.ValidID(id) {
		return ErrInvalid
	}
	tag, err := s.pool.Exec(ctx, `UPDATE device_registrations SET revoked_at=COALESCE(revoked_at,$3),token='',permission='denied',revision=revision+CASE WHEN revoked_at IS NULL THEN 1 ELSE 0 END WHERE id=$1 AND user_id=$2`, id, actor, s.now().UTC())
	if err == nil && tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return err
}

type AlertPreferences struct {
	UnconfirmedDelayMinutes *int   `json:"unconfirmed_delay_minutes"`
	StockEnabled            bool   `json:"stock_enabled"`
	MinIntervalMinutes      int    `json:"min_interval_minutes"`
	Timezone                string `json:"timezone"`
	QuietStartMinute        *int   `json:"quiet_start_minute"`
	QuietEndMinute          *int   `json:"quiet_end_minute"`
}

func (p AlertPreferences) validate() error {
	if p.UnconfirmedDelayMinutes != nil && (*p.UnconfirmedDelayMinutes < 1 || *p.UnconfirmedDelayMinutes > 1440) {
		return ErrInvalid
	}
	if p.MinIntervalMinutes < 15 || p.MinIntervalMinutes > 1440 || p.Timezone == "" || len(p.Timezone) > 100 {
		return ErrInvalid
	}
	if _, err := time.LoadLocation(p.Timezone); err != nil {
		return ErrInvalid
	}
	if (p.QuietStartMinute == nil) != (p.QuietEndMinute == nil) {
		return ErrInvalid
	}
	if p.QuietStartMinute != nil && (*p.QuietStartMinute < 0 || *p.QuietStartMinute > 1439 || *p.QuietEndMinute < 0 || *p.QuietEndMinute > 1439 || *p.QuietStartMinute == *p.QuietEndMinute) {
		return ErrInvalid
	}
	return nil
}
func alertLink(ctx context.Context, tx pgx.Tx, actor, link string) (string, error) {
	if !domain.ValidID(actor) || !domain.ValidID(link) {
		return "", ErrInvalid
	}
	var consent string
	err := tx.QueryRow(ctx, `SELECT accepted_invitation_id::text FROM caregiver_links WHERE id=$1 AND caregiver_user_id=$2 AND status='active' AND 'read'=ANY(scopes) AND accepted_invitation_id IS NOT NULL FOR SHARE`, link, actor).Scan(&consent)
	return consent, translate(err)
}
func (s *Service) GetAlertPreferences(ctx context.Context, actor, link string) (AlertPreferences, error) {
	p := AlertPreferences{MinIntervalMinutes: 60, Timezone: "UTC"}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return p, err
	}
	defer tx.Rollback(ctx)
	consent, err := alertLink(ctx, tx, actor, link)
	if err != nil {
		return p, err
	}
	err = tx.QueryRow(ctx, `SELECT unconfirmed_delay_minutes,stock_enabled,min_interval_minutes,timezone,quiet_start_minute,quiet_end_minute FROM caregiver_alert_preferences WHERE link_id=$1 AND consent_id=$2`, link, consent).Scan(&p.UnconfirmedDelayMinutes, &p.StockEnabled, &p.MinIntervalMinutes, &p.Timezone, &p.QuietStartMinute, &p.QuietEndMinute)
	if err != nil && err != pgx.ErrNoRows {
		return p, err
	}
	return p, tx.Commit(ctx)
}
func (s *Service) SetAlertPreferences(ctx context.Context, actor, link string, p AlertPreferences) (AlertPreferences, error) {
	if err := p.validate(); err != nil {
		return p, err
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return p, err
	}
	defer tx.Rollback(ctx)
	consent, err := alertLink(ctx, tx, actor, link)
	if err != nil {
		return p, err
	}
	_, err = tx.Exec(ctx, `INSERT INTO caregiver_alert_preferences(link_id,consent_id,unconfirmed_delay_minutes,stock_enabled,min_interval_minutes,timezone,quiet_start_minute,quiet_end_minute) VALUES($1,$2,$3,$4,$5,$6,$7,$8)
 ON CONFLICT(link_id) DO UPDATE SET consent_id=excluded.consent_id,unconfirmed_delay_minutes=excluded.unconfirmed_delay_minutes,stock_enabled=excluded.stock_enabled,min_interval_minutes=excluded.min_interval_minutes,timezone=excluded.timezone,quiet_start_minute=excluded.quiet_start_minute,quiet_end_minute=excluded.quiet_end_minute`, link, consent, p.UnconfirmedDelayMinutes, p.StockEnabled, p.MinIntervalMinutes, p.Timezone, p.QuietStartMinute, p.QuietEndMinute)
	if err != nil {
		return p, err
	}
	return p, tx.Commit(ctx)
}
func (p AlertPreferences) quiet(now time.Time) bool {
	if p.QuietStartMinute == nil {
		return false
	}
	loc, err := time.LoadLocation(p.Timezone)
	if err != nil {
		return true
	}
	local := now.In(loc)
	m := local.Hour()*60 + local.Minute()
	start, end := *p.QuietStartMinute, *p.QuietEndMinute
	if start < end {
		return m >= start && m < end
	}
	return m >= start || m < end
}
