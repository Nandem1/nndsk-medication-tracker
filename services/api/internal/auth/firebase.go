package auth

import (
	"context"
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
type Firebase struct{ client *firebaseauth.Client }

func NewFirebase(ctx context.Context, project string) (*Firebase, error) {
	return newFirebase(ctx, project)
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
func (f *Firebase) Verify(ctx context.Context, raw string) (string, error) {
	token, err := f.client.VerifyIDTokenAndCheckRevoked(ctx, raw)
	if err != nil {
		return "", errors.New("invalid identity token")
	}
	return token.UID, nil
}
