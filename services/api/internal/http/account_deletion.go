package httpapi

import (
	"context"
	"net/http"
	"time"

	"medication-tracker/services/api/internal/application"
	"medication-tracker/services/api/internal/auth"
)

type DeleteAccountRequest struct {
	OperationID string `json:"client_operation_id"`
	Confirm     string `json:"confirm"`
}
type AccountDeletionResponse struct {
	IdentityRemoved bool `json:"identity_removed"`
}

func (a *API) deleteAccount(w http.ResponseWriter, r *http.Request) {
	var req DeleteAccountRequest
	if !decode(w, r, &req) {
		return
	}
	if err := a.service.DeleteAccount(r.Context(), application.DeleteAccountCommand{Mutation: mutation(r, req.OperationID), Confirm: req.Confirm}); err != nil {
		resultError(w, r, err)
		return
	}
	writeJSON(w, 200, AccountDeletionResponse{a.removeIdentity(r)})
}

// removeIdentity runs after the commit, so a client that hangs up cannot cancel it. A failure is
// reported and can be retried: the login still works and finds an empty account.
func (a *API) removeIdentity(r *http.Request) bool {
	remover, ok := a.verifier.(auth.IdentityRemover)
	uid, _ := r.Context().Value(identityKey).(string)
	if !ok || uid == "" {
		return false
	}
	ctx, cancel := context.WithTimeout(context.WithoutCancel(r.Context()), 5*time.Second)
	defer cancel()
	if remover.DeleteUser(ctx, uid) != nil {
		return false
	}
	_ = a.service.ForgetIdentity(ctx, uid)
	return true
}
