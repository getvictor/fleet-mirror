package tables

import (
	"testing"

	"github.com/stretchr/testify/require"
)

func TestUp_20260430200000(t *testing.T) {
	db := applyUpToPrev(t)

	// Apply the migration
	applyNext(t, db)

	// Verify the push_token column exists
	var colExists int
	err := db.QueryRow(`
		SELECT COUNT(*) FROM information_schema.columns
		WHERE table_schema = DATABASE()
		AND table_name = 'host_orbit_info'
		AND column_name = 'push_token'
	`).Scan(&colExists)
	require.NoError(t, err)
	require.Equal(t, 1, colExists)
}
