package auth

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"strings"

	firebase "firebase.google.com/go/v4"
	firebaseauth "firebase.google.com/go/v4/auth"
	"google.golang.org/api/option"
)

type Verifier interface {
	Verify(context.Context, string) (string, error)
}

// IdentityRemover removes a login after its account data is gone. An unknown uid is success.
type IdentityRemover interface {
	DeleteUser(context.Context, string) error
}
type Firebase struct{ client *firebaseauth.Client }

// NewFirebase uses FIREBASE_SERVICE_ACCOUNT_JSON when the platform only offers environment
// variables, and Application Default Credentials otherwise.
func NewFirebase(ctx context.Context, project string) (*Firebase, error) {
	options, err := credentialOptions(os.Getenv("FIREBASE_SERVICE_ACCOUNT_JSON"))
	if err != nil {
		return nil, err
	}
	return newFirebase(ctx, project, options...)
}

func credentialOptions(raw string) ([]option.ClientOption, error) {
	if strings.TrimSpace(raw) == "" {
		return nil, nil
	}
	if !json.Valid([]byte(raw)) {
		return nil, errors.New("FIREBASE_SERVICE_ACCOUNT_JSON is not valid JSON")
	}
	return []option.ClientOption{option.WithCredentialsJSON([]byte(raw))}, nil
}

func newFirebase(ctx context.Context, project string, options ...option.ClientOption) (*Firebase, error) {
	if strings.TrimSpace(project) == "" || project == "replace-me" {
		return nil, errors.New("FIREBASE_PROJECT_ID is required")
	}
	if os.Getenv("FIREBASE_AUTH_EMULATOR_HOST") != "" {
		return nil, errors.New("Firebase emulator environment is forbidden in the API executable")
	}
	app, err := firebase.NewApp(ctx, &firebase.Config{ProjectID: project}, options...)
	if err != nil {
		return nil, errors.New("cannot initialize identity provider")
	}
	client, err := app.Auth(ctx)
	if err != nil {
		return nil, errors.New("cannot initialize identity verifier")
	}
	return &Firebase{client: client}, nil
}
func (f *Firebase) DeleteUser(ctx context.Context, uid string) error {
	if err := f.client.DeleteUser(ctx, uid); err != nil && !firebaseauth.IsUserNotFound(err) {
		return errors.New("cannot remove identity")
	}
	return nil
}
func (f *Firebase) Verify(ctx context.Context, raw string) (string, error) {
	token, err := f.client.VerifyIDTokenAndCheckRevoked(ctx, raw)
	if err != nil {
		return "", errors.New("invalid identity token")
	}
	return token.UID, nil
}
