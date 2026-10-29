package googleworkspace

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/pem"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"

	"github.com/fleetdm/fleet/v4/pkg/fleethttp"
	"github.com/fleetdm/fleet/v4/server/fleet"
	"github.com/stretchr/testify/require"
)

func testIntegration(t *testing.T, tokenURI string) *fleet.GoogleWorkspaceIntegration {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	require.NoError(t, err)
	der, err := x509.MarshalPKCS8PrivateKey(key)
	require.NoError(t, err)
	values := map[string]string{
		fleet.GoogleCalendarEmail:      "sa@b.com",
		fleet.GoogleCalendarPrivateKey: string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})),
	}
	if tokenURI != "" {
		values[tokenURIKey] = tokenURI
	}
	return &fleet.GoogleWorkspaceIntegration{
		Domain:                "b.com",
		ImpersonatedUserEmail: "admin@b.com",
		ApiKey:                fleet.GoogleCalendarApiKey{Values: values},
	}
}

// Outside the QA seam, the token exchange always goes to Google: a service-account
// JSON that points token_uri somewhere else is refused instead of honored.
func TestTokenURIIgnoredWithoutEndpointOverride(t *testing.T) {
	var hits atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		hits.Add(1)
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()
	t.Setenv(endpointOverrideEnv, "")

	_, err := NewDirectory(t.Context(), testIntegration(t, srv.URL+"/internal/token"), slog.New(slog.DiscardHandler), Limits{})
	require.ErrorContains(t, err, "token_uri")
	require.Zero(t, hits.Load(), "a non-Google token_uri must never be contacted")
}

// The token exchange must go through Fleet's outbound client so the private
// network guard applies to it like every other integration request.
func TestTokenExchangeUsesOutboundNetworkGuard(t *testing.T) {
	var hits atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		hits.Add(1)
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	// The override seam is the only way token_uri is honored, which is also the
	// path an operator would need for this to matter.
	t.Setenv(endpointOverrideEnv, srv.URL)
	fleethttp.SetNetworkBlockingMode(fleethttp.BlockingFull)
	t.Cleanup(func() { fleethttp.SetNetworkBlockingMode(fleethttp.BlockingDisabled) })

	dir, err := NewDirectory(t.Context(), testIntegration(t, srv.URL+"/token"), slog.New(slog.DiscardHandler), Limits{})
	require.NoError(t, err)

	_, err = dir.ListUsers(t.Context())
	// oauth2 flattens the transport error into its own message, so match on text.
	require.ErrorContains(t, err, fleethttp.ErrPrivateNetworkBlocked.Error())
	require.Zero(t, hits.Load(), "loopback token endpoint must be blocked before any request is sent")
}
