package application

import (
	"context"
	"strings"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"
)

type Profile struct {
	DisplayName     *string `json:"display_name"`
	ProfileVersion  int64   `json:"profile_version"`
	ProfileComplete bool    `json:"profile_complete"`
}

type UpdateProfileCommand struct {
	Mutation
	PatientID       string
	ExpectedVersion int64
	DisplayName     string
}

func profileName(name string) (string, error) {
	name = strings.TrimSpace(name)
	if !utf8.ValidString(name) || utf8.RuneCountInString(name) < 1 || utf8.RuneCountInString(name) > 60 || strings.ContainsAny(name, "\x00\r\n\u0085\u2028\u2029") {
		return "", ErrInvalid
	}
	return name, nil
}

func (s *Service) Profile(ctx context.Context, actor string) (Profile, error) {
	var out Profile
	err := s.pool.QueryRow(ctx, `SELECT CASE WHEN profile_completed_at IS NOT NULL THEN display_name END,profile_version,profile_completed_at IS NOT NULL FROM users WHERE id=$1`, actor).Scan(&out.DisplayName, &out.ProfileVersion, &out.ProfileComplete)
	return out, translate(err)
}

func (s *Service) UpdateProfile(ctx context.Context, cmd UpdateProfileCommand) (Profile, error) {
	name, err := profileName(cmd.DisplayName)
	if err != nil || cmd.ExpectedVersion < 1 {
		return Profile{}, ErrInvalid
	}
	cmd.DisplayName = name
	return transact(ctx, s, cmd.Mutation, accessTarget{"profile", cmd.PatientID}, ScopeTreatments, "update_profile", cmd, func(tx pgx.Tx) (Profile, error) {
		return s.changeProfile(ctx, tx, cmd.Mutation, cmd.PatientID, name, cmd.ExpectedVersion, false)
	})
}

func (s *Service) changeProfile(ctx context.Context, tx pgx.Tx, m Mutation, patient, name string, expected int64, onlyIncomplete bool) (Profile, error) {
	var out Profile
	err := tx.QueryRow(ctx, `SELECT CASE WHEN profile_completed_at IS NOT NULL THEN display_name END,profile_version,profile_completed_at IS NOT NULL FROM users WHERE id=$1 FOR UPDATE`, patient).Scan(&out.DisplayName, &out.ProfileVersion, &out.ProfileComplete)
	if err != nil {
		return out, err
	}
	if onlyIncomplete && out.ProfileComplete {
		return out, nil
	}
	if !onlyIncomplete && out.ProfileVersion != expected {
		return out, ErrConflict
	}
	if _, err = tx.Exec(ctx, `INSERT INTO user_profile_changes(user_id,actor_user_id,client_operation_id,previous_name,new_name,created_at) VALUES($1,$2,$3,$4,$5,$6)`, patient, m.ActorID, m.OperationID, out.DisplayName, name, s.now().UTC()); err != nil {
		return out, err
	}
	err = tx.QueryRow(ctx, `UPDATE users SET display_name=$2,profile_completed_at=COALESCE(profile_completed_at,$3),profile_version=profile_version+1 WHERE id=$1 RETURNING display_name,profile_version,profile_completed_at IS NOT NULL`, patient, name, s.now().UTC()).Scan(&out.DisplayName, &out.ProfileVersion, &out.ProfileComplete)
	return out, err
}
