package application

import "time"

type Invitation struct {
	ID        string    `json:"invitation_id"`
	Token     string    `json:"token"`
	ExpiresAt time.Time `json:"expires_at"`
}
